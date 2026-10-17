// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "common/types.h"
#include "video_core/cache_backend.h"
#include "video_core/pipeline_cache_core.h"
#include "video_core/renderer_metal/mtl_geometry.h"
#include "video_core/renderer_metal/mtl_pso_cache.h"
#include "video_core/renderer_metal/mtl_shader.h"

namespace Metal {

class Device;

/// The shader profile of the Metal backend (see mtl_pipeline_cache.mm for each field's source).
/// `limits` are the cache backend's (Metal::Runtime); the core adds the sparse page shift, paged
/// buffers and the game's copy shader.
Shader::Profile MakeShaderProfile(Device& device, const VideoCore::BackendLimits& limits);

/// What the pipeline cache core's key building asks of the device, for Metal.
VideoCore::PipelineCapabilities MakePipelineCapabilities();

/// A shader module of this backend: the handle the core carries (ShaderModuleHandle::value is a
/// pointer to this). A module whose SPIR-V Metal cannot use (geometry stage, SPIRV-Cross or Metal
/// compiler error) still exists with `shader` null, so a cached shader that is no good does not
/// read as a damaged cache entry (WarmUp would rebuild the cache on every start); the pipelines
/// that need it are not created. Tessellation control and evaluation modules have no plain
/// shader (`shader` null, not counted as unusable): they only exist as the variants of a
/// tessellated pipeline (VariantShader); a geometry module likewise (the geometry kernel).
///
/// The plain shader compiles on the compile threads (CompilePool) from the moment the module is
/// created; `shader` and `status` are read only after PipelineCache::FinishModule, which compiles
/// the module on the calling thread when no compile thread has started it yet.
struct ShaderModule {
    std::unique_ptr<CompiledShader> shader; ///< null: not usable (after FinishModule)
    CompileStatus status{CompileStatus::Failed};
    ShaderStage stage{ShaderStage::Unknown}; ///< from the SPIR-V's entry point, at creation

    enum class CompileState : u8 { Queued, Running, Done };
    std::mutex compile_mutex;
    std::condition_variable compile_cv;
    CompileState compile_state{CompileState::Done};
    std::vector<u32> pending_spirv; ///< the plain shader's input until it is compiled

    // Vertex, tessellation control and evaluation modules: what the pipelines that compile the
    // module another way need. The RectList rewrite (PipelineCache::RectListShader) and the
    // tessellation variants (VariantShader) are compiled once, on the first pipeline that uses
    // the module.
    std::vector<u32> spirv;
    u64 hash{};
    std::string name;
    std::mutex variant_mutex;
    struct Variant {
        CompileVariant variant;
        std::unique_ptr<CompiledShader> shader; ///< null: did not compile (`error` says why)
        std::string error;
    };
    std::vector<Variant> variants;
    std::mutex rect_mutex;
    bool rect_tried{};
    std::unique_ptr<CompiledShader> rect_shader; ///< null: not rewritable (rect_error says why)
    std::string rect_error;
};

/// The backend's serialized part of a graphics pipeline entry: the vertex attributes with the
/// step rates, which the key does not hold (Vulkan keeps them in its vertex input state) and which
/// the cached pipelines of a later start need (WarmUp builds them without a draw).
struct GraphicsSerialization final : VideoCore::PipelineSerialization {
    std::vector<VertexAttribute> vertex_attributes;

    void Serialize(Serialization::Archive& ar) const override;
    bool Deserialize(Serialization::Archive& ar) override;
};

/// Compute pipelines have nothing beyond the core's data.
struct ComputeSerialization final : VideoCore::PipelineSerialization {
    void Serialize(Serialization::Archive& ar) const override {}
    bool Deserialize(Serialization::Archive& ar) override {
        return true;
    }
};

/// The build of a pipeline's Metal states on the compile threads (plan P12): the pipeline object
/// exists from the draw that asked for it, its states only once the build is done. The draw path
/// hands the pipeline on; the recording hooks wait (PipelineCache::AwaitBuild) before they read
/// a state, so the GPU thread can go on to later draws and their compiles meanwhile.
class BuildLatch {
public:
    enum class State : u8 { Pending, Built, Failed };
    explicit BuildLatch(State initial = State::Built) : state{initial} {}
    /// Until the build is done; false: it failed (the states are null).
    bool Wait() const {
        State current;
        while ((current = state.load(std::memory_order_acquire)) == State::Pending) {
            state.wait(State::Pending, std::memory_order_acquire);
        }
        return current == State::Built;
    }
    bool Done() const {
        return state.load(std::memory_order_acquire) != State::Pending;
    }
    bool Failed() const {
        return state.load(std::memory_order_acquire) == State::Failed;
    }
    /// Before the pipeline is handed to the build job.
    void Begin() {
        state.store(State::Pending, std::memory_order_relaxed);
    }
    void Finish(bool built) {
        state.store(built ? State::Built : State::Failed, std::memory_order_release);
        state.notify_all();
    }

private:
    std::atomic<State> state;
};

/// What the rasterizer binds for a draw: the MTLRenderPipelineState (with the encoder state of
/// the key and the shaders' binding maps, RenderPipeline) and the vertex attributes it was built
/// with (they name the vertex buffer slots, in the fetch shader's attribute order). A tessellated
/// pipeline (Tessellation() non-null) also has the compute pipelines that run before its render
/// pipeline (mtl_tessellation.h).
class GraphicsPipeline final : public VideoCore::PipelineBase {
public:
    GraphicsPipeline(const VideoCore::GraphicsPipelineKey& key,
                     std::span<const Shader::Info*, VideoCore::MaxShaderStages> infos,
                     std::optional<const Shader::Gcn::FetchShaderData> fetch_shader);

    /// Never null for a pipeline the cache returns, once Latch().Wait() returned true.
    [[nodiscard]] const RenderPipeline& Render() const noexcept {
        return *render;
    }
    [[nodiscard]] const BuildLatch& Latch() const noexcept {
        return latch;
    }
    [[nodiscard]] std::span<const VertexAttribute> VertexAttributes() const noexcept {
        return vertex_attributes;
    }
    /// The tessellation stages (Render() is their render pipeline), or null.
    [[nodiscard]] const TessellationPipeline* Tessellation() const noexcept {
        return tessellation;
    }
    /// The geometry stages (Render() is their render pipeline), or null.
    [[nodiscard]] const GeometryPipeline* Geometry() const noexcept {
        return geometry;
    }

private:
    friend class PipelineCache;
    const RenderPipeline* render{};
    const TessellationPipeline* tessellation{};
    const GeometryPipeline* geometry{};
    std::vector<VertexAttribute> vertex_attributes;
    BuildLatch latch;
};

class ComputeShaderPipeline final : public VideoCore::PipelineBase {
public:
    ComputeShaderPipeline(const Shader::Info& info, const ComputePipeline* compute);

    /// Never null for a pipeline the cache returns, once Latch().Wait() returned true.
    [[nodiscard]] const ComputePipeline& Compute() const noexcept {
        return *compute;
    }
    [[nodiscard]] const BuildLatch& Latch() const noexcept {
        return latch;
    }

private:
    friend class PipelineCache;
    const ComputePipeline* compute; ///< set by a compile thread for a deferred build
    BuildLatch latch;
};

class CompilePool;

/// The Metal half of the pipeline cache (plan P4.3a): shader modules (SPIRV-Cross -> MSL ->
/// MTLFunction through ShaderCompiler) and pipelines (MTLRenderPipelineState / compute state
/// through PsoCache). Key building, program selection and the disk cache are in the core; the
/// disk cache of this backend has its own folder (core cache tag "metal"), as the serialized
/// pipeline part differs from Vulkan's.
class PipelineCache final : public VideoCore::PipelineCacheCore {
public:
    /// `msl_cache_dir` is the folder of ShaderCompiler / PsoCache (default: <cache>/<title>/metal).
    PipelineCache(Device& device, const VideoCore::BackendLimits& limits,
                  AmdGpu::Liverpool* liverpool, u32 sparse_page_shift,
                  std::filesystem::path msl_cache_dir = {});
    ~PipelineCache() override;

    /// Null: the draw is dropped (no pipeline can be made for it; see Counters). A pipeline
    /// whose states may still be building: the recording hooks call AwaitBuild first.
    const GraphicsPipeline* GetGraphicsPipeline(const VideoCore::DrawIndirectParams params = {},
                                                const Vulkan::PreparedDraw* prepared = nullptr,
                                                bool indirect = false) {
        return Usable(static_cast<const GraphicsPipeline*>(
            PipelineCacheCore::GetGraphicsPipeline(params, prepared, indirect)));
    }

    const GraphicsPipeline* TryPreparedPipeline(const Vulkan::PreparedDraw& prepared) {
        return Usable(static_cast<const GraphicsPipeline*>(
            PipelineCacheCore::TryPreparedPipeline(prepared)));
    }

    const ComputeShaderPipeline* GetComputePipeline() {
        return Usable(
            static_cast<const ComputeShaderPipeline*>(PipelineCacheCore::GetComputePipeline()));
    }

    /// Before a recording hook reads the pipeline's Metal states: waits for a deferred build
    /// (counted, and as compile time in the frame stats). False: the build failed, the draw or
    /// dispatch is dropped.
    bool AwaitBuild(const VideoCore::PipelineBase& pipeline);

    PsoCache& GetPsoCache() {
        return pso_cache;
    }
    ShaderCompiler& GetShaderCompiler() {
        return compiler;
    }

    struct Counters {
        std::atomic<u64> modules{};             ///< shader modules created
        std::atomic<u64> unusable_modules{};    ///< modules without a shader (compile failure, stage)
        std::atomic<u64> pipelines{};           ///< pipelines created (graphics + compute)
        /// Pipelines that could not be created (the draw or dispatch is dropped every time):
        std::atomic<u64> unsupported_stage{};   ///< one tessellation stage alone, geometry with tessellation
        std::atomic<u64> geometry_unsupported{}; ///< a geometry shader the kernel rewrite refuses
        std::atomic<u64> tessellation_unsupported{}; ///< isolines, point mode (Metal has neither)
        std::atomic<u64> unusable_shader{};     ///< a stage's shader did not compile
        std::atomic<u64> rect_list_unrewritable{}; ///< RectList with a vertex shader the rewrite refuses
        std::atomic<u64> pso_failures{};        ///< the Metal pipeline state failed
        /// Deferred builds (P12): pipelines whose states were built on the compile threads after
        /// the draw that asked for them went on; recording hooks that had to wait for one.
        std::atomic<u64> deferred_builds{};
        std::atomic<u64> build_waits{};
        std::atomic<u64> build_wait_us{};
    };
    const Counters& GetCounters() const {
        return counters;
    }

private:
    VideoCore::ShaderModuleHandle CreateShaderModule(std::span<const u32> spirv,
                                                     std::string_view name,
                                                     bool from_cache) override;
    void DestroyShaderModule(VideoCore::ShaderModuleHandle module) override;
    std::unique_ptr<VideoCore::PipelineSerialization> NewGraphicsSerialization() override;
    std::unique_ptr<VideoCore::PipelineSerialization> NewComputeSerialization() override;
    std::unique_ptr<VideoCore::PipelineBase> CreateGraphicsPipeline(
        const VideoCore::GraphicsPipelineKey& key,
        std::span<const Shader::Info*, VideoCore::MaxShaderStages> infos,
        std::span<const Shader::RuntimeInfo, VideoCore::MaxShaderStages> runtime_infos,
        std::optional<const Shader::Gcn::FetchShaderData> fetch_shader,
        std::span<const VideoCore::ShaderModuleHandle, VideoCore::MaxShaderStages> modules,
        VideoCore::PipelineSerialization& sdata, bool preloading) override;
    std::unique_ptr<VideoCore::PipelineBase> CreateComputePipeline(
        VideoCore::ComputePipelineKey key, const Shader::Info& info,
        VideoCore::ShaderModuleHandle module, VideoCore::PipelineSerialization& sdata,
        bool preloading) override;

    /// The vertex shader of `module` rewritten for RectList draws (mtl_spirv_rectlist) and
    /// compiled, or null with the cause in `error`. Owned by the module (retired with it).
    const CompiledShader* RectListShader(VideoCore::ShaderModuleHandle module, std::string& error);

    /// The tessellation variants of a pipeline's stages (compiled once per module and variant):
    /// the vertex shader as a kernel for each index type, the control shader for the evaluation
    /// shader's domain, the evaluation shader for the control shader's patch size. False with
    /// `error`; `unsupported` says the cause is a feature Metal lacks, not a compile failure.
    bool TessellationShaders(std::span<const VideoCore::ShaderModuleHandle,
                                       VideoCore::MaxShaderStages> modules,
                             TessellationInput& input, std::string& error, bool& unsupported);

    /// The stages of a geometry pipeline: the export shader's kernels (vertex stage, by index
    /// type), the geometry kernel and the pass-through function. False with `error`;
    /// `unsupported` says the shader's shape is one the first version does not handle.
    bool GeometryShaders(const VideoCore::GraphicsPipelineKey& key,
                         std::span<const VideoCore::ShaderModuleHandle,
                                   VideoCore::MaxShaderStages> modules,
                         const CompiledShader* fs, GeometryPipelineInput& input,
                         std::string& error, bool& unsupported);

    /// The module's SPIR-V compiled as `variant`, or null with `error`. Owned by the module.
    const CompiledShader* VariantShader(ShaderModule& module, const CompileVariant& variant,
                                        std::string& error);

    void AwaitPreloadedPipelines() override;
    bool PreloadFailed(const VideoCore::PipelineBase& pipeline) const override;

    /// Compiles the module's plain shader (on a compile thread, or on the caller's when none
    /// has taken it yet) or waits for the compile thread that has; afterwards `shader` and
    /// `status` are final.
    void FinishModule(ShaderModule& module);
    void CompileModule(ShaderModule& module);
    /// The module of a stage when its shader is usable and of the stage's kind (FinishModule
    /// first), else null.
    const CompiledShader* UsableShader(VideoCore::ShaderModuleHandle handle, ShaderStage stage);

    /// The part of a graphics pipeline that needs the compiled shaders: the stage variants and
    /// the Metal pipeline states. False: the pipeline cannot be made (counted and logged).
    bool BuildGraphicsPipeline(GraphicsPipeline& pipeline, const VideoCore::GraphicsPipelineKey& key,
                               std::span<const VideoCore::ShaderModuleHandle,
                                         VideoCore::MaxShaderStages> modules,
                               bool has_fs);

    /// Counts and logs (once per key) a graphics pipeline that cannot be made.
    void NoteSkipped(const VideoCore::GraphicsPipelineKey& key, std::atomic<u64>& counter,
                     const char* reason);

    Device& device;
    ShaderCompiler compiler;
    PsoCache pso_cache;
    Geometry::PassThroughCache pass_through;
    Counters counters;

    std::mutex modules_mutex;
    /// Shared with the compile job of a module not compiled yet.
    std::unordered_map<ShaderModule*, std::shared_ptr<ShaderModule>> modules_;
    /// Shaders of destroyed modules. Pipeline states and the PSO cache's entries keep raw
    /// pointers to the CompiledShader (binding maps), so they live as long as the cache; modules
    /// are destroyed only when a damaged disk cache is dropped and for ReplaceShader.
    std::vector<std::unique_ptr<CompiledShader>> retired_shaders;

    std::mutex skipped_mutex;
    std::unordered_set<size_t> skipped_keys; ///< hashes of the keys already logged

    /// Shader modules and the cached pipelines of WarmUp compile here (null:
    /// BB_MTL_ASYNC_COMPILE=0, everything on the calling thread). Destroyed first (joined).
    std::unique_ptr<CompilePool> pool;
    bool preloading_async{}; ///< inside WarmUp with a pool: cached pipelines build on the pool
    bool defer_builds{};     ///< BB_MTL_DEFER_PSO (default on with a pool): new ones as well

    /// Whether this pipeline's states build on the pool (CreateGraphicsPipeline,
    /// CreateComputePipeline).
    bool DeferBuild(bool preloading) const;

    /// A pipeline whose deferred build already failed is null (its draws are dropped early).
    template <typename P>
    static const P* Usable(const P* pipeline) {
        return pipeline && pipeline->Latch().Failed() ? nullptr : pipeline;
    }
};

} // namespace Metal
