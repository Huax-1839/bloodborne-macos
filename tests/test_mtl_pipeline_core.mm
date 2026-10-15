// SPDX-License-Identifier: GPL-2.0-or-later
// Unit test of the pieces of renderer_metal/mtl_pipeline_cache (Metal::PipelineCache, plan P4.3a)
// that need no Liverpool: the shader profile, the pipeline capabilities and the serialized part
// of a graphics pipeline. The hooks themselves run with the rasterizer (P4.3b). Needs a Metal
// device, no window or game.
//
//   mtl-pipeline-core-test [profile.bin]
//
// `profile.bin` is the profile of a MoltenVK session's Vulkan pipeline cache
// (<user>/cache/<title id>/profile.bin: 16 bytes of versions, then Shader::Profile). When given
// (or found at macos/user/cache/CUSA03173/ under the repository), the Metal profile must equal it
// in every field the backend decides (the core adds the sparse page shift, paged buffers and the
// game's copy shader). Exit 0 when every check passed.
#import <Metal/Metal.h>

#include <setjmp.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "common/serdes.h"
#include "shader_recompiler/info.h"
#include "shader_recompiler/ir/ir_emitter.h"
#include "shader_recompiler/ir/passes/ir_passes.h"
#include "shader_recompiler/ir/program.h"
#include "shader_recompiler/recompiler.h"
#include "shader_recompiler/specialization.h"
#include "video_core/renderer_metal/mtl_device.h"
#include "video_core/renderer_metal/mtl_pipeline_cache.h"

// The runtime services libbbgpu takes from bb-probe; this test has no guest process.
extern "C" {
__thread sigjmp_buf* runtime_fault_recover = nullptr;
uint32_t runtime_disabled_optimizations = 0;
uint64_t runtime_experiment_bits = 0;
}

static int failures = 0;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                          \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

static void TestProfile(Metal::Device& device, const char* reference_path) {
    std::printf("profile\n");
    VideoCore::BackendLimits limits{};
    limits.storage_min_alignment = 16; // Metal::Runtime's
    const Shader::Profile profile = Metal::MakeShaderProfile(device, limits);
    CHECK(profile.subgroup_size == 32);
    CHECK(profile.supported_spirv == 0x00010600);
    CHECK(profile.max_viewport_width == 16384 && profile.max_viewport_height == 16384);
    CHECK(profile.max_shared_memory_size == 32768);
    CHECK(profile.support_int8 && profile.support_int16 && profile.support_int64);
    CHECK(profile.support_float16 && !profile.support_float64);
    CHECK(profile.supports_fragment_shader_barycentric);
    CHECK(profile.needs_buffer_offsets);
    CHECK(profile.supports_shader_stencil_export);
    CHECK(!profile.needs_manual_interpolation && !profile.needs_integer_interpolation_fix);
    limits.storage_min_alignment = 4;
    CHECK(!Metal::MakeShaderProfile(device, limits).needs_buffer_offsets);
    limits.storage_min_alignment = 16;

    const auto caps = Metal::MakePipelineCapabilities();
    CHECK(!caps.depth_clip_control && !caps.vertex_input_dynamic_state);
    CHECK(caps.geometry_stage && caps.tessellation); // tessellation: P4.4, geometry: P7.1
    CHECK(!caps.mixed_any_samples && !caps.mixed_depth_samples);

    std::ifstream in(reference_path, std::ios::binary);
    if (!in) {
        std::printf("  (no MoltenVK profile at %s: not compared)\n", reference_path);
        return;
    }
    std::vector<char> data((std::istreambuf_iterator<char>(in)), {});
    constexpr size_t header = 16;
    if (data.size() != header + sizeof(Shader::Profile)) {
        std::printf("  (%s has the size of another profile version: not compared)\n",
                    reference_path);
        return;
    }
    Shader::Profile reference{};
    std::memcpy(&reference, data.data() + header, sizeof(reference));
    // What the core adds.
    Shader::Profile mine = profile;
    mine.sparse_page_shift = reference.sparse_page_shift;
    mine.paged_buffers = reference.paged_buffers;
    mine.buffer_copy_shader_hash = reference.buffer_copy_shader_hash;
    CHECK(mine == reference);
    std::printf("  compared with %s: %s\n", reference_path, mine == reference ? "equal" : "DIFFERS");
}

static void TestSerialization() {
    std::printf("serialization\n");
    Metal::GraphicsSerialization written;
    written.vertex_attributes = {
        {.location = 0, .per_instance = false, .divisor = 1},
        {.location = 3, .per_instance = true, .divisor = 4},
        {.location = 7, .per_instance = true, .divisor = 0},
    };
    Serialization::Archive archive;
    written.Serialize(archive);
    // A written archive's offset is at its end: read from its taken-off container, as the core
    // reads entries from disk.
    Serialization::Archive in{archive.TakeOff()};
    Metal::GraphicsSerialization read;
    CHECK(read.Deserialize(in));
    CHECK(read.vertex_attributes == written.vertex_attributes);

    // More attributes than a draw can have: a damaged entry.
    Serialization::Archive damaged;
    Serialization::Writer writer{damaged};
    writer.Write(static_cast<uint32_t>(VideoCore::MaxVertexBufferCount + 1));
    Serialization::Archive damaged_in{damaged.TakeOff()};
    Metal::GraphicsSerialization rejected;
    bool thrown = false;
    try {
        rejected.Deserialize(damaged_in);
    } catch (const Serialization::CorruptData&) {
        thrown = true;
    }
    CHECK(thrown);

    // Cut short.
    Serialization::Archive cut;
    Serialization::Writer cut_writer{cut};
    cut_writer.Write(static_cast<uint32_t>(2));
    cut_writer.Write(static_cast<uint32_t>(1));
    Serialization::Archive cut_in{cut.TakeOff()};
    thrown = false;
    try {
        Metal::GraphicsSerialization incomplete;
        incomplete.Deserialize(cut_in);
    } catch (const Serialization::CorruptData&) {
        thrown = true;
    }
    CHECK(thrown);

    // Compute: nothing written, nothing read.
    Metal::ComputeSerialization compute;
    Serialization::Archive empty;
    compute.Serialize(empty);
    CHECK(empty.SizeBytes() == 0);
    CHECK(compute.Deserialize(empty));
}


// Review finding #6: a vertex shader with no resources of its own (the RectList / full-screen
// vertex shaders) is reused across start bindings (StageSpecialization::operator==), but the
// ClipPlanes buffer LowerUserClipPlanes lists in every vertex shader was declared in the shader,
// numbered for the pipeline the permutation was first made for, so the draws of another pipeline
// had no resource at that binding (Metal: "missing binding"). It is now declared only when the
// shader reads it, and a permutation that reads it is told apart by its start binding.
static void TestClipPlanes() {
    std::printf("clip planes\n");
    std::array<u32, Shader::ShaderParams::NumShaderUserData> user_data{};
    const Shader::ShaderParams params{user_data, {}, 0x1234};
    Shader::Profile profile{};

    // The pass: a vertex shader exporting a position, with and without enabled planes.
    const auto run_pass = [&](u32 mask, Shader::Info& info) {
        Shader::Pools pools;
        Shader::IR::Program program{info};
        Shader::IR::Block* block = pools.block_pool.Create(pools.inst_pool);
        program.blocks.push_back(block);
        Shader::IR::IREmitter ir{*block};
        for (u32 comp = 0; comp < 4; ++comp) {
            ir.SetAttribute(Shader::IR::Attribute::Position0, ir.Imm32(float(comp)), comp);
        }
        Shader::RuntimeInfo runtime_info{};
        runtime_info.hw_stage = Shader::HwStage::Vertex;
        runtime_info.hw.vs.user_clip_plane_mask = mask;
        Shader::Optimization::LowerUserClipPlanes(program, runtime_info);
        return block->size();
    };
    Shader::Info off(Shader::HwStage::Vertex, Shader::SwStage::Vertex, params);
    const size_t off_size = run_pass(0, off);
    CHECK(off.buffers.size() == 1 && off.buffers[0].buffer_type == Shader::BufferType::ClipPlanes);
    CHECK(off.buffers[0].used_types == Shader::IR::Type::Void); // listed, not declared
    CHECK(off_size == 4);
    Shader::Info on(Shader::HwStage::Vertex, Shader::SwStage::Vertex, params);
    const size_t on_size = run_pass(0x3, on);
    CHECK(on.buffers.size() == 1 && on.buffers[0].used_types == Shader::IR::Type::F32);
    CHECK(on_size > off_size);

    // The permutation identity: the same shader at two start bindings.
    const auto make = [&](const Shader::Info& info, u32 mask, u32 start) {
        Shader::RuntimeInfo runtime_info{};
        runtime_info.hw_stage = Shader::HwStage::Vertex;
        runtime_info.hw.vs.user_clip_plane_mask = mask;
        Shader::Backend::Bindings bindings{};
        bindings.buffer = bindings.unified = start;
        return Shader::StageSpecialization(info, runtime_info, profile, bindings);
    };
    const auto a = make(off, 0, 0), b = make(off, 0, 5);
    CHECK(a.bitset.none()); // nothing but the ClipPlanes buffer: the shortcut applies
    CHECK(a == b);          // one module serves every start (and declares no binding)
    const auto c = make(on, 0x3, 0), d = make(on, 0x3, 5);
    CHECK(!(c == d));       // the module reads the buffer at its own binding
    CHECK(c == make(on, 0x3, 0));
    CHECK(!(a == c));       // different runtime info
}

int main(int argc, char** argv) {
    @autoreleasepool {
        std::string reference = argc > 1 ? argv[1] : "";
        if (reference.empty()) {
            // The checkout this test was built from (__FILE__ is its absolute path).
            const std::string source = __FILE__;
            reference = source.substr(0, source.rfind("/tests/")) +
                        "/macos/user/cache/CUSA03173/profile.bin";
        }
        Metal::Device device;
        TestProfile(device, reference.c_str());
        TestSerialization();
        TestClipPlanes();
    }
    std::printf(failures ? "%d check(s) FAILED\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
}
