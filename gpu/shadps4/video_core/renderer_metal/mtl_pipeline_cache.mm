// SPDX-License-Identifier: GPL-2.0-or-later
// Metal::PipelineCache, the Metal half of VideoCore::PipelineCacheCore (plan P4.3a). Counterpart of
// renderer_vulkan/vk_pipeline_cache.cpp: the hooks make shader modules and pipelines, everything
// else (keys, programs, permutations, SPIR-V, the disk cache) is the core's.

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <concepts>
#include <deque>
#include <functional>
#include <thread>

#include <pthread.h>

#include "common/assert.h"
#include "common/logging/log.h"
#include "common/serdes.h"
#include "video_core/renderer_metal/mtl_device_impl.h"
#include "video_core/renderer_metal/mtl_pipeline_cache.h"
#include "video_core/renderer_metal/mtl_spirv_geometry.h"
#include "video_core/renderer_metal/mtl_spirv_rectlist.h"

namespace Vulkan {
extern std::atomic<u64> g_bb_compile_ns; // pipeline_cache_core.cpp
}

namespace Metal {
namespace {
using VideoCore::ShaderModuleHandle;

constexpr u32 SpirvVersion1_6 = 0x00010600U;
/// Xored into the guest hash of a vertex module's RectList variant (the log label and the name of
/// its MSL cache file; the file name also holds the hash of the rewritten SPIR-V).
constexpr u64 RectListHashSalt = 0x5265637400000000ULL; // "Rect"

/// The viewport limit of every Metal GPU the backend supports (Apple family 7+, Mac2).
constexpr u32 MaxViewportDimension = 16384;

ShaderModuleHandle ToHandle(ShaderModule* module) {
    return ShaderModuleHandle{reinterpret_cast<u64>(module)};
}

ShaderModule* ToModule(ShaderModuleHandle handle) {
    return reinterpret_cast<ShaderModule*>(handle.value);
}

/// The vertex attributes of a pipeline (in the fetch shader's order), as
/// PipelineBase::GetVertexInputs derives them: location and step rate only, which need no V#, so
/// a compile thread can do it (GetVertexInputs reads the V#s from the user data the GPU thread
/// rewrites every draw).
std::vector<VertexAttribute> VertexAttributesOf(
    const std::optional<const Shader::Gcn::FetchShaderData>& fetch_shader, u32 step_rate_0,
    u32 step_rate_1) {
    using InstanceIdType = Shader::Gcn::VertexAttribute::InstanceIdType;
    std::vector<VertexAttribute> attributes;
    if (!fetch_shader) {
        return attributes;
    }
    for (const auto& attrib : fetch_shader->attributes) {
        const InstanceIdType step_rate = attrib.GetStepRate();
        VertexAttribute attribute;
        attribute.location = attrib.semantic;
        attribute.per_instance = step_rate != InstanceIdType::None;
        if (attribute.per_instance) {
            attribute.divisor = step_rate == InstanceIdType::OverStepRate0   ? step_rate_0
                                : step_rate == InstanceIdType::OverStepRate1 ? step_rate_1
                                                                             : 1;
        }
        attributes.push_back(attribute);
    }
    return attributes;
}
} // namespace

/// Threads for shader modules and preloaded pipelines (plan P12). Jobs start in submission order,
/// and a job waits only for jobs submitted before it (a preloaded pipeline for its modules), which
/// have started by then, or compiles them itself (FinishModule): no job waits for one that cannot
/// run. Metal's compiles are thread-safe and run in the compiler service; these threads mostly
/// wait for it.
class CompilePool {
public:
    explicit CompilePool(u32 threads) {
        for (u32 i = 0; i < threads; ++i) {
            workers.emplace_back([this] { Run(); });
        }
    }
    /// Jobs not started are dropped (a module's job holds only a reference to it).
    ~CompilePool() {
        {
            std::scoped_lock lock{mutex};
            stop = true;
            jobs.clear();
        }
        cv.notify_all();
        for (std::thread& worker : workers) {
            worker.join();
        }
    }
    void Submit(std::function<void()> job) {
        {
            std::scoped_lock lock{mutex};
            jobs.push_back(std::move(job));
            ++unfinished;
        }
        cv.notify_one();
    }
    /// Until every job submitted so far has finished.
    void WaitIdle() {
        std::unique_lock lock{mutex};
        idle_cv.wait(lock, [&] { return unfinished == 0; });
    }
    u32 Threads() const {
        return static_cast<u32>(workers.size());
    }

private:
    void Run() {
        pthread_setname_np("bb-mtl-compile");
        for (;;) {
            std::function<void()> job;
            {
                std::unique_lock lock{mutex};
                cv.wait(lock, [&] { return stop || !jobs.empty(); });
                if (stop) {
                    return;
                }
                job = std::move(jobs.front());
                jobs.pop_front();
            }
            @autoreleasepool {
                job();
            }
            job = nullptr; // releases what the job holds before it counts as finished
            std::scoped_lock lock{mutex};
            if (--unfinished == 0) {
                idle_cv.notify_all();
            }
        }
    }

    std::mutex mutex;
    std::condition_variable cv;
    std::condition_variable idle_cv;
    std::deque<std::function<void()>> jobs;
    u64 unfinished{};
    std::vector<std::thread> workers;
    bool stop{};
};

namespace {
/// BB_MTL_ASYNC_COMPILE=0: no compile threads (modules and pipelines compile on the calling
/// thread, as before P12). BB_MTL_COMPILE_THREADS: their number (default: the cores less two, 2
/// to 8).
u32 CompileThreads() {
    const char* async = std::getenv("BB_MTL_ASYNC_COMPILE");
    if (async && async[0] == '0') {
        return 0;
    }
    const char* env = std::getenv("BB_MTL_COMPILE_THREADS");
    if (env && *env) {
        return static_cast<u32>(std::strtoul(env, nullptr, 10));
    }
    const u32 cores = std::thread::hardware_concurrency();
    return std::clamp(cores > 2 ? cores - 2 : 2u, 2u, 8u);
}

/// BB_MTL_DEFER_PSO=0: new pipelines (not the preloaded ones) build on the thread that asks for
/// them, as before P12.
bool DeferPsoEnabled() {
    const char* env = std::getenv("BB_MTL_DEFER_PSO");
    return !(env && env[0] == '0');
}
} // namespace

Shader::Profile MakeShaderProfile(Device& device, const VideoCore::BackendLimits& limits) {
    id<MTLDevice> mtl = device.GetImpl().device;
    // Every field has the value the Vulkan backend's MakeProfile computed on MoltenVK (read from
    // the profile.bin of a MoltenVK session's pipeline cache), so the recompiler emits the SPIR-V
    // the Metal shader tests (P3.1) compiled. Where that value came from a Vulkan feature query,
    // the column says what the Metal path supports instead.
    return Shader::Profile{
        // Metal viewport limit (16384, as MoltenVK's maxViewportDimensions).
        .max_viewport_width = limits.max_viewport_width ? limits.max_viewport_width
                                                         : MaxViewportDimension,
        .max_viewport_height = limits.max_viewport_height ? limits.max_viewport_height
                                                          : MaxViewportDimension,
        // maxThreadgroupMemoryLength (32 KiB on Apple GPUs; MoltenVK reported the same).
        .max_shared_memory_size = static_cast<u32>(mtl.maxThreadgroupMemoryLength),
        .supported_spirv = SpirvVersion1_6, // the constant the Vulkan backend passes
        // Apple GPUs' SIMD width (threadExecutionWidth, 32), MoltenVK's subgroupSize.
        .subgroup_size = 32,
        // MSL has char, short, long and half; no double.
        .support_int8 = true,
        .support_int16 = true,
        .support_int64 = true,
        .support_float16 = true,
        .support_float64 = false,
        // MSL has no per-shader float controls (MoltenVK: shaderDenorm*/shaderRounding* all 0,
        // independence none).
        .supports_denorm_behavior_independence = false,
        .supports_rounding_mode_independence = false,
        .support_fp16_denorm_preserve = false,
        .support_fp16_denorm_flush = false,
        .support_fp16_round_to_zero = false,
        .support_fp32_denorm_preserve = false,
        .support_fp32_denorm_flush = false,
        .support_fp32_round_to_zero = false,
        .support_fp64_denorm_preserve = false,
        .support_fp64_denorm_flush = false,
        .support_fp64_round_to_zero = false,
        // MoltenVK: fp16/fp32 true, fp64 false (as above, no double).
        .support_fp16_signed_zero_inf_nan_preserve = true,
        .support_fp32_signed_zero_inf_nan_preserve = true,
        .support_fp64_signed_zero_inf_nan_preserve = false,
        // MoltenVK: true (textures read/write with a level in MSL).
        .supports_image_load_store_lod = true,
        // VK_AMD_gcn_shader and the atomics/layout extensions MoltenVK lacks: false.
        .supports_native_cube_calc = false,
        // MoltenVK: true (the P3.1 shader tests compiled the SPIR-V emitted with it).
        .supports_trinary_minmax = true,
        .supports_buffer_fp32_atomic_min_max = false,
        .supports_image_fp32_atomic_min_max = false,
        .supports_buffer_int64_atomics = false,
        .supports_shared_int64_atomics = false,
        .supports_workgroup_explicit_memory_layout = false,
        .supports_amd_shader_explicit_vertex_parameter = false,
        // MoltenVK: true. The recompiler emits PerVertexKHR inputs, which the backend rewrites
        // to ordinary inputs and barycentric arithmetic (mtl_spirv_pervertex, P3.1b).
        .supports_fragment_shader_barycentric = true,
        .supports_shader_subgroup_clock = false,
        // Vulkan derives these from the driver id (NVIDIA, KosmicKrisp) and env overrides: all
        // false on MoltenVK. needs_buffer_offsets is storageMinAlignment > 4 (Metal::Runtime:
        // 16), true as on MoltenVK.
        .needs_manual_interpolation = false,
        .needs_integer_interpolation_fix = false,
        .needs_lds_barriers = false,
        .needs_buffer_offsets = limits.storage_min_alignment > 4,
        .needs_unorm_fixup = false,
        .needs_clip_distance_emulation = false,
        // MoltenVK: true (MSL [[stencil]] output).
        .supports_shader_stencil_export = true,
        // P9.1: V1 and V2 emit game fragment/compute shaders without NoContraction; part of the
        // profile, so the disk cache of those rules never meets a strict one.
        .relaxed_fragment_compute_float = ReadFloatRules() != FloatRules::Strict,
    };
}

VideoCore::PipelineCapabilities MakePipelineCapabilities() {
    return {
        // Metal's clip space z is [0, w] only: the recompiler emulates [-w, w] in the vertex
        // shader (depth_clip_enable itself is MTLDepthClipMode, set per draw).
        .depth_clip_control = false,
        // The vertex descriptor is part of the render pipeline state: pipelines depend on the
        // vertex formats (the key holds them).
        .vertex_input_dynamic_state = false,
        // CreateGraphicsPipeline derives the vertex attributes without the V#s (the formats are
        // in the key): new pipelines of passes drawn every frame compile on the core's compile
        // threads while their draws wait a frame or two (BB_ASYNC_PIPELINES, P12).
        .async_graphics_pipelines = true,
        // Geometry draws: the export shader and the geometry shader run as compute kernels, the
        // strips they write are drawn by a pass-through vertex function (mtl_geometry.h, P7.1).
        .geometry_stage = true,
        // Tessellated pipelines: the vertex and control shaders run as compute kernels, the
        // evaluation shader is the post-tessellation vertex function (mtl_tessellation.h, P4.4).
        .tessellation = true,
        // One sample count for all attachments of a Metal render pass.
        .mixed_any_samples = false,
        .mixed_depth_samples = false,
    };
}

GraphicsPipeline::GraphicsPipeline(const VideoCore::GraphicsPipelineKey& key_,
                                   std::span<const Shader::Info*, VideoCore::MaxShaderStages> infos,
                                   std::optional<const Shader::Gcn::FetchShaderData> fetch_shader_)
    : PipelineBase{key_, std::move(fetch_shader_)} {
    std::ranges::copy(infos, stages.begin());
}

ComputeShaderPipeline::ComputeShaderPipeline(const Shader::Info& info,
                                             const ComputePipeline* compute_)
    : PipelineBase{true}, compute{compute_} {
    stages[u32(Shader::SwStage::Compute)] = &info;
}

void GraphicsSerialization::Serialize(Serialization::Archive& ar) const {
    Serialization::Writer writer{ar};
    writer.Write(static_cast<u32>(vertex_attributes.size()));
    for (const VertexAttribute& attribute : vertex_attributes) {
        writer.Write(attribute.location);
        writer.Write(static_cast<u32>(attribute.per_instance));
        writer.Write(attribute.divisor);
    }
}

bool GraphicsSerialization::Deserialize(Serialization::Archive& ar) {
    Serialization::Reader reader{ar};
    u32 count{};
    reader.Read(count);
    if (count > VideoCore::MaxVertexBufferCount) {
        throw Serialization::CorruptData{"too many vertex attributes in the pipeline cache"};
    }
    vertex_attributes.resize(count);
    for (VertexAttribute& attribute : vertex_attributes) {
        u32 per_instance{};
        reader.Read(attribute.location);
        reader.Read(per_instance);
        reader.Read(attribute.divisor);
        attribute.per_instance = per_instance != 0;
    }
    return true;
}

PipelineCache::PipelineCache(Device& device_, const VideoCore::BackendLimits& limits,
                             AmdGpu::Liverpool* liverpool_, u32 sparse_page_shift,
                             std::filesystem::path msl_cache_dir)
    : PipelineCacheCore{liverpool_, MakeShaderProfile(device_, limits), MakePipelineCapabilities(),
                        sparse_page_shift,
                        // V1 and V2 share their SPIR-V; V0 keeps the cache it always had.
                        ReadFloatRules() == FloatRules::Strict ? "metal" : "metal-relaxed"},
      device{device_}, compiler{device_, msl_cache_dir, ReadFloatRules()},
      pso_cache{device_, msl_cache_dir, ReadFloatRules() == FloatRules::RelaxedMath},
      pass_through{device_} {
    std::printf("GPU: Metal float rules %s\n", FloatRulesName(ReadFloatRules()));
    if (const u32 threads = CompileThreads()) {
        pool = std::make_unique<CompilePool>(threads);
        defer_builds = DeferPsoEnabled();
    }
    const auto start = std::chrono::steady_clock::now();
    preloading_async = pool != nullptr;
    WarmUp();
    preloading_async = false;
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() -
                                                                 start)
                          .count();
    std::printf("GPU: pipeline cache warm-up took %.0f ms (%llu modules, %llu pipelines), %u "
                "compile threads (BB_MTL_ASYNC_COMPILE=0: none), new pipeline states %s\n",
                ms, (unsigned long long)counters.modules.load(),
                (unsigned long long)counters.pipelines.load(), pool ? pool->Threads() : 0u,
                defer_builds ? "built there while the GPU thread goes on (BB_MTL_DEFER_PSO=0: "
                               "on the GPU thread)"
                             : "built on the GPU thread");
}

PipelineCache::~PipelineCache() {
    // The pool first: its jobs write into pipelines the core owns (jobs not started are dropped;
    // a pipeline left pending is never recorded any more). Then the core: its compile threads
    // build without the pool and may compile a module whose job was dropped.
    pool.reset();
    DestroyPipelines();
}

bool PipelineCache::DeferBuild(bool preloading) const {
    // The core's compile threads (BB_ASYNC_PIPELINES) build at once: their draws go without the
    // pipeline until the job is done, which must then mean built.
    return pool && (preloading ? preloading_async : defer_builds && !OnCompileThread());
}

bool PipelineCache::AwaitBuild(const VideoCore::PipelineBase& pipeline) {
    const BuildLatch& latch = pipeline.IsCompute()
                                  ? static_cast<const ComputeShaderPipeline&>(pipeline).Latch()
                                  : static_cast<const GraphicsPipeline&>(pipeline).Latch();
    if (latch.Done()) {
        return !latch.Failed();
    }
    const auto start = std::chrono::steady_clock::now();
    const bool built = latch.Wait();
    const u64 ns = static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                        std::chrono::steady_clock::now() - start)
                                        .count());
    ++counters.build_waits;
    counters.build_wait_us += ns / 1000;
    // The frame stats count it as compile time: the recording waited for the compiler.
    Vulkan::g_bb_compile_ns += ns;
    if (ns >= 16'000'000) {
        LOG_WARNING(Render, "Slow compile: recording waited {:.1f} ms for {} pipeline {:#x}",
                    double(ns) / 1e6, pipeline.IsCompute() ? "compute" : "graphics",
                    pipeline.IsCompute()
                        ? u64(0)
                        : u64(std::hash<VideoCore::GraphicsPipelineKey>{}(
                              pipeline.GetGraphicsKey())));
    }
    return built;
}

void PipelineCache::AwaitPreloadedPipelines() {
    if (pool) {
        pool->WaitIdle();
    }
}

bool PipelineCache::PreloadFailed(const VideoCore::PipelineBase& pipeline) const {
    if (pipeline.IsCompute()) {
        return !static_cast<const ComputeShaderPipeline&>(pipeline).compute;
    }
    return !static_cast<const GraphicsPipeline&>(pipeline).render;
}

ShaderModuleHandle PipelineCache::CreateShaderModule(std::span<const u32> spirv,
                                                     std::string_view name, bool from_cache) {
    // The core's names carry the guest hash ("<stage>_0x<hash>_<perm>"): the MSL cache file and
    // the logs use it. Modules from the disk cache come without a name.
    u64 hash = 0;
    if (const size_t pos = name.find("0x"); pos != std::string_view::npos) {
        hash = std::strtoull(std::string{name.substr(pos)}.c_str(), nullptr, 16);
    }
    auto module = std::make_shared<ShaderModule>();
    const ShaderStage stage = ReadShaderStage(spirv);
    const bool tessellation_stage = stage == ShaderStage::TessellationControl ||
                                    stage == ShaderStage::TessellationEval ||
                                    stage == ShaderStage::Geometry;
    module->stage = stage;
    module->hash = hash;
    module->name = name.empty() ? std::string{"cached"} : std::string{name};
    if (stage == ShaderStage::Vertex || tessellation_stage) { // (incl. geometry)
        module->spirv.assign(spirv.begin(), spirv.end());
    }
    ++counters.modules;
    if (tessellation_stage) {
        // Only compiled as a variant of a tessellated or geometry pipeline.
        module->status = CompileStatus::Ok;
    } else {
        module->pending_spirv.assign(spirv.begin(), spirv.end());
        module->compile_state = ShaderModule::CompileState::Queued;
    }
    ShaderModule* raw = module.get();
    if (module->compile_state == ShaderModule::CompileState::Queued) {
        if (pool) {
            pool->Submit([this, module] { FinishModule(*module); });
        } else {
            FinishModule(*module);
        }
    }
    std::scoped_lock lock{modules_mutex};
    modules_.emplace(raw, std::move(module));
    return ToHandle(raw);
}

void PipelineCache::FinishModule(ShaderModule& module) {
    std::unique_lock lock{module.compile_mutex};
    switch (module.compile_state) {
    case ShaderModule::CompileState::Done:
        return;
    case ShaderModule::CompileState::Running:
        module.compile_cv.wait(lock, [&] {
            return module.compile_state == ShaderModule::CompileState::Done;
        });
        return;
    case ShaderModule::CompileState::Queued:
        module.compile_state = ShaderModule::CompileState::Running;
        lock.unlock();
        CompileModule(module);
        lock.lock();
        module.compile_state = ShaderModule::CompileState::Done;
        module.compile_cv.notify_all();
        return;
    }
}

void PipelineCache::CompileModule(ShaderModule& module) {
    CompileResult result = compiler.Compile(module.pending_spirv, module.hash, module.name);
    module.status = result.status;
    module.shader = std::move(result.shader);
    module.pending_spirv = {};
    if (!module.shader) {
        // A cached shader that does not compile is no damaged entry, and a null handle from the
        // disk cache would make WarmUp drop the whole cache: the module stays, unusable.
        ++counters.unusable_modules;
    }
}

const CompiledShader* PipelineCache::UsableShader(ShaderModuleHandle handle, ShaderStage stage) {
    ShaderModule* module = handle ? ToModule(handle) : nullptr;
    if (!module) {
        return nullptr;
    }
    FinishModule(*module);
    return module->shader && module->shader->stage == stage ? module->shader.get() : nullptr;
}

void PipelineCache::DestroyShaderModule(ShaderModuleHandle handle) {
    std::scoped_lock lock{modules_mutex};
    const auto it = modules_.find(ToModule(handle));
    if (it == modules_.end()) {
        return;
    }
    {
        // A module no thread has started is not compiled any more; a running compile finishes.
        ShaderModule& module = *it->second;
        std::unique_lock compile_lock{module.compile_mutex};
        if (module.compile_state == ShaderModule::CompileState::Queued) {
            module.compile_state = ShaderModule::CompileState::Done;
        }
        module.compile_cv.wait(compile_lock, [&] {
            return module.compile_state == ShaderModule::CompileState::Done;
        });
    }
    if (it->second->shader) {
        retired_shaders.push_back(std::move(it->second->shader));
    }
    {
        std::scoped_lock rect_lock{it->second->rect_mutex};
        if (it->second->rect_shader) {
            retired_shaders.push_back(std::move(it->second->rect_shader));
        }
    }
    {
        std::scoped_lock variant_lock{it->second->variant_mutex};
        for (ShaderModule::Variant& variant : it->second->variants) {
            if (variant.shader) {
                retired_shaders.push_back(std::move(variant.shader));
            }
        }
    }
    modules_.erase(it);
}

const CompiledShader* PipelineCache::RectListShader(ShaderModuleHandle handle, std::string& error) {
    ShaderModule* module = handle ? ToModule(handle) : nullptr;
    if (!module || module->stage != ShaderStage::Vertex || module->spirv.empty()) {
        error = "no vertex module";
        return nullptr;
    }
    std::scoped_lock lock{module->rect_mutex};
    if (!module->rect_tried) {
        module->rect_tried = true;
        const RectListRewrite rewrite = RewriteRectListVertex(module->spirv);
        if (!rewrite.ok) {
            module->rect_error = rewrite.error;
        } else {
            CompileResult result = compiler.Compile(rewrite.spirv, module->hash ^ RectListHashSalt,
                                                    module->name + "_rect");
            if (result.shader) {
                module->rect_shader = std::move(result.shader);
            } else {
                module->rect_error = "the rewritten shader did not compile: " + result.error;
            }
        }
    }
    error = module->rect_error;
    return module->rect_shader.get();
}

const CompiledShader* PipelineCache::VariantShader(ShaderModule& module,
                                                   const CompileVariant& variant,
                                                   std::string& error) {
    std::scoped_lock lock{module.variant_mutex};
    for (const ShaderModule::Variant& known : module.variants) {
        if (known.variant == variant) {
            error = known.error;
            return known.shader.get();
        }
    }
    ShaderModule::Variant& made = module.variants.emplace_back();
    made.variant = variant;
    if (module.spirv.empty()) {
        made.error = "no SPIR-V kept for the module";
    } else {
        const char* suffix = variant.kind == CompileVariant::Kind::TessVertex    ? "_tessvs"
                             : variant.kind == CompileVariant::Kind::TessControl ? "_tesstcs"
                             : variant.kind == CompileVariant::Kind::GeometryKernel ? "_gskernel"
                                                                                 : "_tesstes";
        CompileResult result =
            compiler.Compile(module.spirv, module.hash, module.name + suffix, variant);
        if (result.shader) {
            made.shader = std::move(result.shader);
        } else {
            made.error = result.error;
        }
    }
    error = made.error;
    return made.shader.get();
}

bool PipelineCache::TessellationShaders(
    std::span<const ShaderModuleHandle, VideoCore::MaxShaderStages> modules,
    TessellationInput& input, std::string& error, bool& unsupported) {
    using Shader::SwStage;
    unsupported = false;
    ShaderModule* vs = modules[u32(SwStage::Vertex)] ? ToModule(modules[u32(SwStage::Vertex)]) : nullptr;
    ShaderModule* tcs = modules[u32(SwStage::TessellationControl)]
                            ? ToModule(modules[u32(SwStage::TessellationControl)])
                            : nullptr;
    ShaderModule* tes = modules[u32(SwStage::TessellationEval)]
                            ? ToModule(modules[u32(SwStage::TessellationEval)])
                            : nullptr;
    if (!vs || vs->stage != ShaderStage::Vertex || !tcs ||
        tcs->stage != ShaderStage::TessellationControl || !tes ||
        tes->stage != ShaderStage::TessellationEval) {
        error = "a stage's module is missing or of another stage";
        return false;
    }
    const TessellationInfo tes_info = ReadTessellationInfo(tes->spirv);
    const TessellationInfo tcs_info = ReadTessellationInfo(tcs->spirv);
    if (tes_info.domain != TessDomain::Triangles && tes_info.domain != TessDomain::Quads) {
        error = "Metal tessellates triangles and quads only (the evaluation shader's domain)";
        unsupported = true;
        return false;
    }
    if (tes_info.point_mode) {
        error = "Metal's tessellator has no point mode";
        unsupported = true;
        return false;
    }
    if (tcs_info.output_vertices == 0) {
        error = "the control shader declares no OutputVertices";
        return false;
    }
    for (u32 index_type = 0; index_type < 3; ++index_type) {
        input.vertex[index_type] = VariantShader(
            *vs, {.kind = CompileVariant::Kind::TessVertex, .index_type = index_type}, error);
        if (!input.vertex[index_type]) {
            error = "vertex kernel: " + error;
            return false;
        }
    }
    input.control = VariantShader(
        *tcs, {.kind = CompileVariant::Kind::TessControl, .domain = tes_info.domain}, error);
    if (!input.control) {
        error = "control kernel: " + error;
        return false;
    }
    input.eval = VariantShader(
        *tes,
        {.kind = CompileVariant::Kind::TessEval, .output_vertices = tcs_info.output_vertices},
        error);
    if (!input.eval) {
        error = "evaluation function: " + error;
        return false;
    }
    return true;
}

bool PipelineCache::GeometryShaders(
    const VideoCore::GraphicsPipelineKey& key,
    std::span<const ShaderModuleHandle, VideoCore::MaxShaderStages> modules,
    const CompiledShader* fs, GeometryPipelineInput& input, std::string& error,
    bool& unsupported) {
    using Shader::SwStage;
    unsupported = false;
    ShaderModule* es = modules[u32(SwStage::Vertex)] ? ToModule(modules[u32(SwStage::Vertex)]) : nullptr;
    ShaderModule* gs = modules[u32(SwStage::Geometry)] ? ToModule(modules[u32(SwStage::Geometry)])
                                                       : nullptr;
    if (!es || es->stage != ShaderStage::Vertex || !gs || gs->stage != ShaderStage::Geometry) {
        error = "a stage's module is missing or of another stage";
        return false;
    }
    // The shape first: the shaders the first version cannot handle are counted, not failures.
    const GeometryRewrite analysis = AnalyzeGeometryShader(gs->spirv);
    if (!analysis.ok) {
        error = analysis.error;
        unsupported = true;
        return false;
    }
    const AmdGpu::PrimitiveType prim = key.prim_type;
    const bool matches = (analysis.info.input == GsInputPrimitive::Points &&
                          prim == AmdGpu::PrimitiveType::PointList) ||
                         (analysis.info.input == GsInputPrimitive::Lines &&
                          prim == AmdGpu::PrimitiveType::LineList) ||
                         (analysis.info.input == GsInputPrimitive::Triangles &&
                          prim == AmdGpu::PrimitiveType::TriangleList);
    if (!matches) {
        error = "the draw's primitive type is not a list of the geometry shader's input primitive";
        unsupported = true;
        return false;
    }
    for (u32 index_type = 0; index_type < 3; ++index_type) {
        input.es[index_type] = VariantShader(
            *es, {.kind = CompileVariant::Kind::TessVertex, .index_type = index_type}, error);
        if (!input.es[index_type]) {
            error = "export kernel: " + error;
            return false;
        }
    }
    CompileVariant variant{.kind = CompileVariant::Kind::GeometryKernel};
    variant.es.stride = input.es[0]->tess_layout.output;
    variant.es.members = input.es[0]->tess_layout.members;
    input.gs = VariantShader(*gs, variant, error);
    if (!input.gs) {
        error = "geometry kernel: " + error;
        return false;
    }
    const bool clip_minus_w_to_w = key.clip_space == AmdGpu::ClipSpace::MinusWToW;
    std::span<const StageInput> fs_inputs;
    if (fs) {
        fs_inputs = fs->stage_inputs;
    }
    input.pass_through = pass_through.Get(input.gs->geometry, fs_inputs, clip_minus_w_to_w, error);
    if (!input.pass_through) {
        error = "pass-through function: " + error;
        return false;
    }
    return true;
}

std::unique_ptr<VideoCore::PipelineSerialization> PipelineCache::NewGraphicsSerialization() {
    return std::make_unique<GraphicsSerialization>();
}

std::unique_ptr<VideoCore::PipelineSerialization> PipelineCache::NewComputeSerialization() {
    return std::make_unique<ComputeSerialization>();
}

void PipelineCache::NoteSkipped(const VideoCore::GraphicsPipelineKey& key,
                                std::atomic<u64>& counter, const char* reason) {
    ++counter;
    const size_t hash = std::hash<VideoCore::GraphicsPipelineKey>{}(key);
    bool first;
    {
        std::scoped_lock lock{skipped_mutex};
        first = skipped_keys.insert(hash).second;
    }
    if (first) {
        LOG_WARNING(Render, "Metal: graphics pipeline {:#x} (vs {:#x} fs {:#x}) not created: {}; "
                            "its draws are dropped",
                    hash, key.stage_hashes[u32(Shader::SwStage::Vertex)],
                    key.stage_hashes[u32(Shader::SwStage::Fragment)], reason);
    }
}

std::unique_ptr<VideoCore::PipelineBase> PipelineCache::CreateGraphicsPipeline(
    const VideoCore::GraphicsPipelineKey& key,
    std::span<const Shader::Info*, VideoCore::MaxShaderStages> infos,
    std::span<const Shader::RuntimeInfo, VideoCore::MaxShaderStages> runtime_infos,
    std::optional<const Shader::Gcn::FetchShaderData> fetch_shader,
    std::span<const ShaderModuleHandle, VideoCore::MaxShaderStages> modules,
    VideoCore::PipelineSerialization& sdata, bool preloading) {
    // Also called on the core's compile threads (BB_ASYNC_PIPELINES): reads only the key, the
    // modules, the fetch shader and the runtime infos (copies), never `infos`' contents.
    using Shader::SwStage;
    constexpr u32 VS = u32(SwStage::Vertex);
    const bool has_tcs = key.stage_hashes[u32(SwStage::TessellationControl)] != 0;
    const bool has_tes = key.stage_hashes[u32(SwStage::TessellationEval)] != 0;
    const bool has_gs = key.stage_hashes[u32(SwStage::Geometry)] != 0;
    if (has_gs && (has_tcs || has_tes)) {
        NoteSkipped(key, counters.unsupported_stage, "a geometry stage with tessellation");
        return nullptr;
    }
    if (has_tcs != has_tes) {
        NoteSkipped(key, counters.unsupported_stage,
                    "a tessellation control or evaluation stage without the other");
        return nullptr;
    }
    const bool has_fs = infos[u32(SwStage::Fragment)] != nullptr;

    auto pipeline = std::make_unique<GraphicsPipeline>(key, infos, fetch_shader);
    auto& serialized = static_cast<GraphicsSerialization&>(sdata);
    if (preloading) {
        pipeline->vertex_attributes = serialized.vertex_attributes;
    } else {
        // The step rates come from this pipeline's runtime info, as in the Vulkan pipeline's
        // static vertex input state.
        const auto& vs_info = runtime_infos[VS].sw.vs;
        pipeline->vertex_attributes =
            VertexAttributesOf(fetch_shader, vs_info.step_rate_0, vs_info.step_rate_1);
        serialized.vertex_attributes = pipeline->vertex_attributes;
    }
    if (preloading && (has_tcs || has_gs) && serialized.vertex_attributes.empty() &&
        key.vertex_buffer_formats[0] != vk::Format::eUndefined) {
        // An entry of a build before the tessellation (geometry) path: the pipeline was dropped
        // then and its attributes never recorded. The core rebuilds the cache.
        throw Serialization::CorruptData{
            has_tcs ? "a tessellated pipeline recorded without its vertex attributes (cache of a "
                      "Metal build before tessellation support)"
                    : "a geometry pipeline recorded without its vertex attributes"};
    }

    if (DeferBuild(preloading)) {
        // On the pool. WarmUp waits for its pipelines (AwaitPreloadedPipelines) and drops the
        // ones that failed (PreloadFailed); a new pipeline goes to the draw at once, the
        // recording hooks wait for its states (AwaitBuild).
        std::array<ShaderModuleHandle, VideoCore::MaxShaderStages> stage_modules;
        std::ranges::copy(modules, stage_modules.begin());
        pipeline->latch.Begin();
        if (!preloading) {
            ++counters.deferred_builds;
        }
        pool->Submit([this, raw = pipeline.get(), key, stage_modules, has_fs] {
            raw->latch.Finish(BuildGraphicsPipeline(*raw, key, stage_modules, has_fs));
        });
        return pipeline;
    }
    if (!BuildGraphicsPipeline(*pipeline, key, modules, has_fs)) {
        return nullptr;
    }
    return pipeline;
}

bool PipelineCache::BuildGraphicsPipeline(
    GraphicsPipeline& pipeline, const VideoCore::GraphicsPipelineKey& key,
    std::span<const ShaderModuleHandle, VideoCore::MaxShaderStages> modules, bool has_fs) {
    using Shader::SwStage;
    constexpr u32 VS = u32(SwStage::Vertex), FS = u32(SwStage::Fragment);
    // Tessellated draws: the vertex, control and evaluation shaders compile as variants (no plain
    // vertex shader is needed), the draw runs the three stages (mtl_tessellation.h).
    const bool tessellation = key.stage_hashes[u32(SwStage::TessellationControl)] != 0;
    const bool has_gs = key.stage_hashes[u32(SwStage::Geometry)] != 0;
    // (A geometry draw's export shader compiles as kernels too, its plain form is not needed.)
    const bool variants_only = tessellation || has_gs;
    const CompiledShader* vs =
        modules[VS] && !variants_only ? UsableShader(modules[VS], ShaderStage::Vertex) : nullptr;
    const CompiledShader* fs = has_fs ? UsableShader(modules[FS], ShaderStage::Fragment) : nullptr;
    if ((!vs && !variants_only) || (has_fs && !fs)) {
        NoteSkipped(key, counters.unusable_shader, "a shader did not translate to Metal");
        return false;
    }

    // RectList: a vertex shader that evaluates the three vertices and emits two triangles; the
    // pipeline is then an ordinary triangle list (RenderPipelineInput::rect_list_triangles).
    const bool rect_list = key.prim_type == AmdGpu::PrimitiveType::RectList;
    if (rect_list && !variants_only) {
        std::string error;
        vs = RectListShader(modules[VS], error);
        if (!vs) {
            const std::string reason = "rect list vertex shader not rewritable: " + error;
            NoteSkipped(key, counters.rect_list_unrewritable, reason.c_str());
            return false;
        }
    }

    if (tessellation) {
        TessellationInput tess_input;
        tess_input.vertex_attributes = pipeline.vertex_attributes;
        std::string error;
        bool unsupported = false;
        if (!TessellationShaders(modules, tess_input, error, unsupported)) {
            const std::string reason = "tessellation: " + error;
            NoteSkipped(key, unsupported ? counters.tessellation_unsupported
                                         : counters.unusable_shader,
                        reason.c_str());
            return false;
        }
        const TessellationPipeline* tess = pso_cache.GetTessellationPipeline(key, tess_input, fs);
        if (!tess) {
            // PsoCache logged the Metal error (once per key).
            ++counters.pso_failures;
            return false;
        }
        pipeline.tessellation = tess;
        pipeline.render = tess->render;
        ++counters.pipelines;
        return true;
    }

    if (has_gs) {
        GeometryPipelineInput geometry_input;
        geometry_input.vertex_attributes = pipeline.vertex_attributes;
        std::string error;
        bool unsupported = false;
        if (!GeometryShaders(key, modules, fs, geometry_input, error, unsupported)) {
            const std::string reason = "geometry: " + error;
            NoteSkipped(key, unsupported ? counters.geometry_unsupported
                                         : counters.unusable_shader,
                        reason.c_str());
            return false;
        }
        const GeometryPipeline* geometry = pso_cache.GetGeometryPipeline(key, geometry_input, fs);
        if (!geometry) {
            // PsoCache logged the Metal error (once per key).
            ++counters.pso_failures;
            return false;
        }
        pipeline.geometry = geometry;
        pipeline.render = geometry->render;
        ++counters.pipelines;
        return true;
    }

    const RenderPipelineInput input{.vertex_attributes = pipeline.vertex_attributes,
                                    .rect_list_triangles = rect_list};
    pipeline.render = pso_cache.GetRenderPipeline(key, vs, fs, input);
    if (!pipeline.render) {
        // PsoCache logged the Metal error (once per key).
        ++counters.pso_failures;
        return false;
    }
    ++counters.pipelines;
    return true;
}

std::unique_ptr<VideoCore::PipelineBase> PipelineCache::CreateComputePipeline(
    VideoCore::ComputePipelineKey key, const Shader::Info& info, ShaderModuleHandle module,
    VideoCore::PipelineSerialization& sdata, bool preloading) {
    const auto build = [this, key, module]() -> const ComputePipeline* {
        const CompiledShader* cs = UsableShader(module, ShaderStage::Compute);
        if (!cs) {
            ++counters.unusable_shader;
            LOG_WARNING(Render, "Metal: compute pipeline {:#x} not created: the shader did not "
                                "translate to Metal; its dispatches are dropped",
                        key.value);
            return nullptr;
        }
        const ComputePipeline* compute = pso_cache.GetComputePipeline(key, cs);
        if (!compute) {
            ++counters.pso_failures;
            return nullptr;
        }
        ++counters.pipelines;
        return compute;
    };
    if (DeferBuild(preloading)) {
        // As CreateGraphicsPipeline.
        auto pipeline = std::make_unique<ComputeShaderPipeline>(info, nullptr);
        pipeline->latch.Begin();
        if (!preloading) {
            ++counters.deferred_builds;
        }
        pool->Submit([raw = pipeline.get(), build] {
            raw->compute = build();
            raw->latch.Finish(raw->compute != nullptr);
        });
        return pipeline;
    }
    const ComputePipeline* compute = build();
    if (!compute) {
        return nullptr;
    }
    return std::make_unique<ComputeShaderPipeline>(info, compute);
}

} // namespace Metal
