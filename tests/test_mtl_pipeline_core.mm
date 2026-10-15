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

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "common/serdes.h"
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

int main(int argc, char** argv) {
    @autoreleasepool {
        std::string reference = argc > 1 ? argv[1] : "";
        if (reference.empty()) {
            if (const char* home = std::getenv("HOME")) {
                reference = std::string{home} +
                            "/Projekte/bloodborne-macos/macos/user/cache/CUSA03173/profile.bin";
            }
        }
        Metal::Device device;
        TestProfile(device, reference.c_str());
        TestSerialization();
    }
    std::printf(failures ? "%d check(s) FAILED\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
}
