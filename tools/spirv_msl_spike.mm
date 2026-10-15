// SPDX-License-Identifier: GPL-2.0-or-later
// Build: clang++ -arch x86_64 -std=c++20 -fobjc-arc -O2 -mmacosx-version-min=14.0 -Imacos/deps/x86_64/include -Imacos/deps/x86_64/include/spirv_cross tools/spirv_msl_spike.mm -Lmacos/deps/x86_64/lib -lspirv-cross-msl -lspirv-cross-glsl -lspirv-cross-core -lspirv-cross-util -framework Metal -framework Foundation -o <scratch>/spirv_msl_spike
// Run:   arch -x86_64 <scratch>/spirv_msl_spike <dir with .spv copies> <out dir> [--msl 3.1|3.2] [--no-retry] [--cold]
//                                                [--opt <MSL option>[=0|1]]... [--limit N]
//
// Metal backend spike (plan P0.5, decisions D5/D7): converts every SPIR-V shader of the Vulkan
// shader cache to MSL with SPIRV-Cross, builds an MTLLibrary from the source and creates the
// MTLFunction (plus a compute PSO for compute shaders). Output: <out>/spike.csv, a summary on
// stdout, the largest MSL per stage (<out>/largest_<stage>.metal) and every failing MSL source
// (<out>/fail/<file>.metal) for inspection.
//
// Binding model experiment ("direct slots", argument_buffers = false):
//   * every (set, binding) of a stage gets one slot per Metal resource class, in reflection order
//     (UBO, SSBO, storage image, sampled image, separate image, sampler classes), buffers from 1,
//     textures from 0, samplers from 0. The recompiler emits several SSBO variables with the same
//     (set, binding) but different struct types (aliasing views of one buffer); they share the slot.
//   * the push constant block is buffer 0 (fixed slot, the same in every stage).
//   * SPIRV-Cross' own buffers (buffer size for OpArrayLength) are moved from 25 to 29 so they do
//     not collide; slot 30 stays free for vertex buffers; the swizzle buffer stays at 30 and is unused.
//   * the retry with argument_buffers = true (Tier 2) puts one descriptor set into one argument buffer
//     (buffer 0 for set 0), ids are unique within the set and assigned in the same order.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "spirv_msl.hpp"

namespace fs = std::filesystem;
using namespace spirv_cross;
using Clock = std::chrono::steady_clock;

static double ms_since(Clock::time_point t) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

// Metal limits per stage (Apple silicon, argument buffers not used).
static constexpr uint32_t kMaxBuffers = 31, kMaxTextures = 128, kMaxSamplers = 16;
static constexpr uint32_t kBufferSizeBufferIndex = 29;

static const char* StageName(ExecutionModel m) {
    switch (m) {
    case ExecutionModelVertex: return "vertex";
    case ExecutionModelFragment: return "fragment";
    case ExecutionModelGLCompute: return "compute";
    case ExecutionModelGeometry: return "geometry";
    case ExecutionModelTessellationControl: return "tess_control";
    case ExecutionModelTessellationEvaluation: return "tess_eval";
    default: return "other";
    }
}

struct Config {
    uint32_t msl_major = 3, msl_minor = 1;
    bool retry_argbuf = true;
    std::vector<std::pair<std::string, int>> opts; // MSL option name, value
    int limit = 0;
    bool cold = false; // unique comment line in the MSL: defeats Metal's compile cache, honest compile times
    std::string nonce;
};

struct Info {
    std::string stage = "?";
    ExecutionModel model = ExecutionModelMax;
    uint32_t buffers = 0, textures = 0, samplers = 0;
    bool uses_bda = false;      // OpCapability PhysicalStorageBufferAddresses
    bool uses_pagetable = false; // the recompiler's "bda_pagetable" SSBO
    bool uses_push = false;
    bool needs_buffer_size = false;
    bool vertex_inputs = false;
    std::string entry;
};

// Name -> setter for the CompilerMSL::Options booleans used in experiments.
static bool SetOption(CompilerMSL::Options& o, const std::string& name, int v) {
#define B(n) if (name == #n) { o.n = v != 0; return true; }
    B(enable_decoration_binding) B(force_native_arrays) B(texture_buffer_native) B(pad_fragment_output_components)
    B(use_framebuffer_fetch_subpasses) B(emulate_subgroups) B(ios_use_simdgroup_functions) B(enable_base_index_zero)
    B(invariant_float_math) B(force_active_argument_buffer_resources) B(pad_argument_buffer_resources)
    B(texture_1D_as_2D) B(emulate_cube_array) B(replace_recursive_inputs) B(check_discarded_frag_stores)
    B(manual_helper_invocation_updates) B(readwrite_texture_fences) B(enable_point_size_builtin)
    B(enable_point_size_default) B(enable_frag_depth_builtin) B(enable_frag_stencil_ref_builtin)
    B(force_sample_rate_shading) B(multiview) B(ios_support_base_vertex_instance) B(dispatch_base)
    B(argument_buffers) B(auto_disable_rasterization) B(force_fragment_with_side_effects_execution)
    B(sample_dref_lod_array_as_grad) B(use_fast_math_pragmas) B(arrayed_subpass_input)
#undef B
    if (name == "fixed_subgroup_size") { o.fixed_subgroup_size = v; return true; }
    if (name == "enable_frag_output_mask") { o.enable_frag_output_mask = v; return true; }
    if (name == "r32ui_linear_texture_alignment") { o.r32ui_linear_texture_alignment = v; return true; }
    return false;
}

// SPIR-V -> MSL. Throws CompilerError.
static std::string Convert(const std::vector<uint32_t>& spirv, bool argbuf, const Config& cfg, Info& info) {
    CompilerMSL comp(spirv);

    auto eps = comp.get_entry_points_and_stages();
    if (eps.empty()) {
        throw CompilerError("no entry point");
    }
    info.model = eps[0].execution_model;
    info.stage = StageName(info.model);
    info.entry = comp.get_cleansed_entry_point_name(eps[0].name, info.model);
    for (auto cap : comp.get_declared_capabilities()) {
        if (cap == CapabilityPhysicalStorageBufferAddresses) {
            info.uses_bda = true;
        }
    }

    ShaderResources res = comp.get_shader_resources();
    info.uses_push = !res.push_constant_buffers.empty();
    info.vertex_inputs = !res.stage_inputs.empty() && info.model == ExecutionModelVertex;

    CompilerMSL::Options o;
    o.platform = CompilerMSL::Options::macOS;
    o.set_msl_version(cfg.msl_major, cfg.msl_minor);
    o.argument_buffers = argbuf;
    o.argument_buffers_tier = CompilerMSL::Options::ArgumentBuffersTier::Tier2;
    o.buffer_size_buffer_index = kBufferSizeBufferIndex;
    for (auto& [name, v] : cfg.opts) {
        if (!SetOption(o, name, v)) {
            fprintf(stderr, "unknown MSL option %s\n", name.c_str());
            exit(2);
        }
    }
    comp.set_msl_options(o);

    // Slot assignment.
    std::set<std::pair<uint32_t, uint32_t>> seen; // (set, binding) already assigned, per class below
    std::map<std::pair<uint32_t, uint32_t>, MSLResourceBinding> bindings;
    uint32_t next_buffer = 0, next_texture = 0, next_sampler = 0, next_id = 0;
    if (info.uses_push) {
        next_buffer = 1; // push constants own buffer 0
    }

    auto array_count = [&](const Resource& r) -> uint32_t {
        const SPIRType& t = comp.get_type(r.type_id);
        if (t.array.empty()) {
            return 1;
        }
        return t.array_size_literal[0] && t.array[0] ? t.array[0] : 1;
    };
    auto assign = [&](const SmallVector<Resource>& list, SPIRType::BaseType base, bool is_buffer, bool is_texture,
                      bool is_sampler) {
        for (const Resource& r : list) {
            uint32_t set = comp.get_decoration(r.id, DecorationDescriptorSet);
            uint32_t binding = comp.get_decoration(r.id, DecorationBinding);
            const auto key = std::make_pair(set, binding);
            if (bindings.count(key)) {
                // Aliasing variable on a (set, binding) already assigned (several struct views of one buffer).
                if (comp.get_name(r.id) == "bda_pagetable") {
                    info.uses_pagetable = true;
                }
                continue;
            }
            if (comp.get_name(r.id) == "bda_pagetable") {
                info.uses_pagetable = true;
            }
            const uint32_t n = array_count(r);
            MSLResourceBinding b;
            b.stage = info.model;
            b.basetype = base;
            b.desc_set = set;
            b.binding = binding;
            b.count = n;
            if (argbuf) {
                // One id space per set: unique ids; combined image samplers need a texture and a sampler id.
                if (is_buffer) {
                    b.msl_buffer = next_id;
                    next_id += n;
                    info.buffers += n;
                }
                if (is_texture) {
                    b.msl_texture = next_id;
                    next_id += n;
                    info.textures += n;
                }
                if (is_sampler) {
                    b.msl_sampler = next_id;
                    next_id += n;
                    info.samplers += n;
                }
            } else {
                if (is_buffer) {
                    b.msl_buffer = next_buffer;
                    next_buffer += n;
                    info.buffers += n;
                }
                if (is_texture) {
                    b.msl_texture = next_texture;
                    next_texture += n;
                    info.textures += n;
                }
                if (is_sampler) {
                    b.msl_sampler = next_sampler;
                    next_sampler += n;
                    info.samplers += n;
                }
            }
            bindings[key] = b;
        }
    };
    assign(res.uniform_buffers, SPIRType::Struct, true, false, false);
    assign(res.storage_buffers, SPIRType::Struct, true, false, false);
    assign(res.storage_images, SPIRType::Image, false, true, false);
    assign(res.sampled_images, SPIRType::SampledImage, false, true, true);
    assign(res.separate_images, SPIRType::Image, false, true, false);
    assign(res.separate_samplers, SPIRType::Sampler, false, false, true);
    assign(res.subpass_inputs, SPIRType::Image, false, true, false);
    for (auto& [key, b] : bindings) {
        comp.add_msl_resource_binding(b);
    }
    if (info.uses_push) {
        MSLResourceBinding b;
        b.stage = info.model;
        b.basetype = SPIRType::Struct;
        b.desc_set = kPushConstDescSet;
        b.binding = kPushConstBinding;
        b.msl_buffer = 0; // a plain buffer; the argument buffers (retry) start at buffer 1
        comp.add_msl_resource_binding(b);
        info.buffers += 1;
    }
    if (argbuf) {
        std::set<uint32_t> sets;
        for (auto& [key, b] : bindings) {
            sets.insert(key.first);
        }
        // Argument buffer buffer indices: one per set, after the push constant slot.
        uint32_t slot = info.uses_push ? 1 : 0;
        for (uint32_t s : sets) {
            MSLResourceBinding b;
            b.stage = info.model;
            b.desc_set = s;
            b.binding = kArgumentBufferBinding;
            b.msl_buffer = slot++;
            comp.add_msl_resource_binding(b);
        }
        info.buffers += (uint32_t)sets.size();
    }

    std::string msl = comp.compile();
    // The compiler renames "main" (MSL forbids it) to "main0"; ask it after compile().
    info.entry = comp.get_cleansed_entry_point_name(eps[0].name, info.model);
    info.needs_buffer_size = comp.needs_buffer_size_buffer();
    if (info.needs_buffer_size) {
        info.buffers += 1;
    }
    return msl;
}

struct Outcome {
    std::string file, status, first_error;
    size_t spirv_bytes = 0, msl_bytes = 0;
    double convert_ms = 0, compile_ms = 0, pso_ms = 0;
    Info info;
    bool retried = false, rescued = false;
    std::string msl;
};

static std::string FirstLine(const std::string& s) {
    auto p = s.find('\n');
    return p == std::string::npos ? s : s.substr(0, p);
}

// Metal: newLibraryWithSource + function (+ compute PSO). Returns "" on success, else the first error line.
static std::string CompileMetal(id<MTLDevice> dev, const std::string& msl, const Info& info, const Config& cfg, double& compile_ms,
                                double& pso_ms) {
    @autoreleasepool {
        MTLCompileOptions* co = [MTLCompileOptions new];
        MTLLanguageVersion lv = MTLLanguageVersion3_1;
        if (cfg.msl_major == 3 && cfg.msl_minor >= 2) {
            if (@available(macOS 15.0, *)) {
                lv = MTLLanguageVersion3_2;
            }
        }
        co.languageVersion = lv;
        if (@available(macOS 15.0, *)) {
            co.mathMode = MTLMathModeSafe;
        } else {
            co.fastMathEnabled = NO;
        }
        NSError* err = nil;
        const std::string src = cfg.cold ? "// " + cfg.nonce + "\n" + msl : msl;
        auto t0 = Clock::now();
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:src.c_str()] options:co error:&err];
        compile_ms = ms_since(t0);
        if (!lib) {
            std::string text = err ? [[err localizedDescription] UTF8String] : "unknown error";
            // First "error:" line, without the "program_source:L:C:" prefix.
            size_t pos = 0;
            while (pos < text.size()) {
                size_t e = text.find('\n', pos);
                std::string line = text.substr(pos, e == std::string::npos ? std::string::npos : e - pos);
                auto k = line.find("error:");
                if (k != std::string::npos) {
                    return line.substr(k);
                }
                if (e == std::string::npos) {
                    break;
                }
                pos = e + 1;
            }
            return FirstLine(text);
        }
        auto t1 = Clock::now();
        id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:info.entry.c_str()]];
        if (!fn) {
            return "error: function '" + info.entry + "' not found in library";
        }
        if (info.model == ExecutionModelGLCompute) {
            id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&err];
            pso_ms = ms_since(t1);
            if (!pso) {
                return std::string("error: compute PSO: ") + (err ? FirstLine([[err localizedDescription] UTF8String]) : "?");
            }
        }
        return "";
    }
}

static Outcome Run(id<MTLDevice> dev, const fs::path& path, const Config& cfg) {
    Outcome out;
    out.file = path.filename().string();
    std::ifstream f(path, std::ios::binary);
    std::vector<char> raw((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    out.spirv_bytes = raw.size();
    std::vector<uint32_t> spirv(raw.size() / 4);
    memcpy(spirv.data(), raw.data(), spirv.size() * 4);

    for (int attempt = 0; attempt < 2; ++attempt) {
        const bool argbuf = attempt == 1;
        Info info;
        std::string status, msl;
        double convert_ms = 0, compile_ms = 0, pso_ms = 0;
        auto t0 = Clock::now();
        try {
            msl = Convert(spirv, argbuf, cfg, info);
            convert_ms = ms_since(t0);
            std::string err = CompileMetal(dev, msl, info, cfg, compile_ms, pso_ms);
            status = err.empty() ? "ok" : "compile_fail:" + err;
        } catch (const std::exception& e) {
            convert_ms = ms_since(t0);
            status = std::string("convert_fail:") + FirstLine(e.what());
            msl.clear();
        }
        if (attempt == 0) {
            out.status = status;
            out.info = info;
            out.msl = msl;
            out.msl_bytes = msl.size();
            out.convert_ms = convert_ms;
            out.compile_ms = compile_ms;
            out.pso_ms = pso_ms;
            if (status == "ok" || !cfg.retry_argbuf) {
                break;
            }
        } else {
            out.retried = true;
            out.rescued = status == "ok";
            out.first_error = status; // result of the argument buffer attempt
        }
    }
    return out;
}

static double Percentile(std::vector<double> v, double p) {
    if (v.empty()) {
        return 0;
    }
    std::sort(v.begin(), v.end());
    return v[std::min(v.size() - 1, (size_t)(p * v.size()))];
}
static void Stats(const char* name, const std::vector<double>& v) {
    double sum = 0, mx = 0;
    for (double d : v) {
        sum += d;
        mx = std::max(mx, d);
    }
    printf("  %-8s mean %8.2f  p50 %8.2f  p95 %8.2f  max %8.2f  total %9.1f ms (n=%zu)\n", name, v.empty() ? 0 : sum / v.size(),
           Percentile(v, 0.5), Percentile(v, 0.95), mx, sum, v.size());
}

// Groups messages: digits and quoted identifiers are folded.
static std::string Normalize(std::string s) {
    std::string r;
    bool in_quote = false, prev_digit = false;
    for (size_t i = 0; i < s.size(); ++i) {
        char c = s[i];
        if (c == '\'') {
            if (!in_quote) {
                r += "'<id>'";
            }
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) {
            continue;
        }
        if (isdigit((unsigned char)c)) {
            if (!prev_digit) {
                r += 'N';
            }
            prev_digit = true;
            continue;
        }
        prev_digit = false;
        r += c;
    }
    return r;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <spv dir> <out dir> [--msl 3.2] [--no-retry] [--opt name[=v]] [--limit N]\n", argv[0]);
        return 2;
    }
    Config cfg;
    for (int i = 3; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--msl" && i + 1 < argc) {
            sscanf(argv[++i], "%u.%u", &cfg.msl_major, &cfg.msl_minor);
        } else if (a == "--cold") {
            cfg.cold = true;
            cfg.nonce = std::to_string(Clock::now().time_since_epoch().count());
        } else if (a == "--no-retry") {
            cfg.retry_argbuf = false;
        } else if (a == "--limit" && i + 1 < argc) {
            cfg.limit = atoi(argv[++i]);
        } else if (a == "--opt" && i + 1 < argc) {
            std::string o = argv[++i];
            int v = 1;
            auto eq = o.find('=');
            if (eq != std::string::npos) {
                v = (int)strtol(o.c_str() + eq + 1, nullptr, 0);
                o.resize(eq);
            }
            cfg.opts.emplace_back(o, v);
        } else {
            fprintf(stderr, "bad argument %s\n", argv[i]);
            return 2;
        }
    }
    const fs::path in = argv[1], outdir = argv[2];
    fs::create_directories(outdir / "fail");

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) {
        fprintf(stderr, "no Metal device\n");
        return 1;
    }
    printf("device: %s, MSL %u.%u, SPIRV-Cross options:", [[dev name] UTF8String], cfg.msl_major, cfg.msl_minor);
    for (auto& [n, v] : cfg.opts) {
        printf(" %s=%d", n.c_str(), v);
    }
    printf("\n");

    std::vector<fs::path> files;
    for (auto& e : fs::directory_iterator(in)) {
        if (e.path().extension() == ".spv") {
            files.push_back(e.path());
        }
    }
    std::sort(files.begin(), files.end());
    if (cfg.limit > 0 && (size_t)cfg.limit < files.size()) {
        files.resize(cfg.limit);
    }

    std::ofstream csv(outdir / "spike.csv");
    csv << "file,stage,spirv_bytes,msl_bytes,convert_ms,compile_ms,buffers,textures,samplers,uses_bda,uses_push,status,"
           "pso_ms,uses_pagetable,needs_buffer_size,vertex_inputs,argbuf_retry\n";

    std::vector<Outcome> all;
    all.reserve(files.size());
    for (auto& p : files) {
        @autoreleasepool {
            all.push_back(Run(dev, p, cfg));
        }
        Outcome& o = all.back();
        std::string st = o.status;
        std::replace(st.begin(), st.end(), ',', ';');
        std::replace(st.begin(), st.end(), '\n', ' ');
        char buf[1024];
        snprintf(buf, sizeof buf, "%s,%s,%zu,%zu,%.2f,%.2f,%u,%u,%u,%d,%d,", o.file.c_str(), o.info.stage.c_str(), o.spirv_bytes,
                 o.msl_bytes, o.convert_ms, o.compile_ms, o.info.buffers, o.info.textures, o.info.samplers, o.info.uses_bda,
                 o.info.uses_push);
        csv << buf << '"' << st << '"';
        snprintf(buf, sizeof buf, ",%.2f,%d,%d,%d,%s\n", o.pso_ms, o.info.uses_pagetable, o.info.needs_buffer_size,
                 o.info.vertex_inputs, !o.retried ? "-" : (o.rescued ? "rescued" : "failed"));
        csv << buf;
        if (o.status != "ok" && !o.msl.empty()) {
            std::ofstream(outdir / "fail" / (o.file + ".metal")) << o.msl;
        }
    }

    // Summary.
    std::map<std::string, int> by_status_kind, by_stage, fail_msgs, fail_msgs_argbuf;
    std::map<std::string, std::vector<double>> conv, comp, pso;
    std::vector<double> conv_all, comp_all;
    std::map<std::string, const Outcome*> largest;
    int over = 0, over_reserved = 0, bda = 0, push = 0, pagetable = 0, bufsize = 0, vtx_in = 0, retried = 0, rescued = 0;
    int max_b = 0, max_t = 0, max_s = 0;
    std::map<std::string, int> ok_by_stage;
    for (const Outcome& o : all) {
        std::string kind = o.status == "ok" ? "ok" : o.status.substr(0, o.status.find(':'));
        by_status_kind[kind]++;
        by_stage[o.info.stage]++;
        if (o.status == "ok") {
            ok_by_stage[o.info.stage]++;
        } else {
            fail_msgs[Normalize(o.status)]++;
        }
        if (o.retried) {
            ++retried;
            rescued += o.rescued;
            if (!o.rescued) {
                fail_msgs_argbuf[Normalize(o.first_error)]++;
            }
        }
        if (o.status.rfind("convert_fail", 0) != 0) {
            conv_all.push_back(o.convert_ms);
            conv[o.info.stage].push_back(o.convert_ms);
            if (o.compile_ms > 0) {
                comp_all.push_back(o.compile_ms);
                comp[o.info.stage].push_back(o.compile_ms);
            }
            if (o.pso_ms > 0) {
                pso["compute"].push_back(o.pso_ms);
            }
        }
        if (o.info.buffers > kMaxBuffers || o.info.textures > kMaxTextures || o.info.samplers > kMaxSamplers) {
            ++over;
        }
        if (o.info.buffers > kMaxBuffers - 1) {
            ++over_reserved;
        }
        max_b = std::max<int>(max_b, o.info.buffers);
        max_t = std::max<int>(max_t, o.info.textures);
        max_s = std::max<int>(max_s, o.info.samplers);
        bda += o.info.uses_bda;
        push += o.info.uses_push;
        pagetable += o.info.uses_pagetable;
        bufsize += o.info.needs_buffer_size;
        vtx_in += o.info.vertex_inputs;
        auto& l = largest[o.info.stage];
        if (o.status == "ok" && (!l || o.msl_bytes > l->msl_bytes)) {
            l = &o;
        }
    }
    printf("\n== shaders: %zu\n", all.size());
    for (auto& [k, n] : by_status_kind) {
        printf("  status %-14s %d\n", k.c_str(), n);
    }
    for (auto& [k, n] : by_stage) {
        printf("  stage  %-14s %d (ok %d)\n", k.c_str(), n, ok_by_stage[k]);
    }
    printf("\n== times (ms)\n");
    Stats("convert", conv_all);
    for (auto& [k, v] : conv) {
        Stats(("  " + k).c_str(), v);
    }
    Stats("compile", comp_all);
    for (auto& [k, v] : comp) {
        Stats(("  " + k).c_str(), v);
    }
    Stats("cs pso", pso["compute"]);
    printf("\n== resources\n");
    printf("  over a Metal per-stage limit (31 buffers, 128 textures, 16 samplers): %d\n", over);
    printf("  buffers > 30 (slot 30 reserved): %d\n", over_reserved);
    printf("  max buffers %d, textures %d, samplers %d\n", max_b, max_t, max_s);
    printf("  uses PhysicalStorageBufferAddresses: %d, bda_pagetable SSBO: %d, push constants: %d, needs buffer-size buffer: %d, "
           "vertex stage_inputs: %d\n",
           bda, pagetable, push, bufsize, vtx_in);
    printf("\n== argument buffer retry (tier 2): %d tried, %d rescued\n", retried, rescued);
    printf("\n== distinct failures (first attempt, direct slots)\n");
    {
        std::vector<std::pair<int, std::string>> v;
        for (auto& [m, n] : fail_msgs) {
            v.emplace_back(n, m);
        }
        std::sort(v.rbegin(), v.rend());
        for (auto& [n, m] : v) {
            printf("  %4d  %s\n", n, m.c_str());
        }
    }
    if (!fail_msgs_argbuf.empty()) {
        printf("\n== still failing after argument buffer retry\n");
        std::vector<std::pair<int, std::string>> v;
        for (auto& [m, n] : fail_msgs_argbuf) {
            v.emplace_back(n, m);
        }
        std::sort(v.rbegin(), v.rend());
        for (auto& [n, m] : v) {
            printf("  %4d  %s\n", n, m.c_str());
        }
    }
    for (auto& [stage, o] : largest) {
        if (!o) {
            continue;
        }
        fs::path p = outdir / ("largest_" + stage + ".metal");
        std::ofstream(p) << o->msl;
        printf("\nlargest ok %s: %s (%zu MSL bytes) -> %s", stage.c_str(), o->file.c_str(), o->msl_bytes, p.c_str());
    }
    printf("\n");
    return 0;
}
