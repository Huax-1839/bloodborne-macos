// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <bit>

#include "video_core/cache_backend.h"
#include "video_core/texture_cache/image.h"
#include "video_core/texture_cache/image_info.h"
#include "video_core/texture_cache/image_view.h"
#include "video_core/texture_cache/tile_manager.h"

namespace VideoCore {

struct TilingInfo {
    u32 bank_swizzle;
    u32 micro_tiled_mips;
    u32 num_mips;
    std::array<ImageInfo::MipInfo, 16> mips;
};

TileManager::TileManager(CacheBackend& backend_, StreamBuffer& stream_buffer_)
    : backend{backend_}, stream_buffer{stream_buffer_} {}

TileManager::~TileManager() = default;

TilingDispatch TileManager::MakeDispatch(const ImageInfo& info, bool is_tiler,
                                         const KernelBuffer& tiled, const KernelBuffer& linear,
                                         const KernelBuffer& params) {
    const auto micro_tile_mode = AmdGpu::GetMicroTileMode(info.tile_mode);
    const bool is_macro = AmdGpu::IsMacroTiled(info.array_mode);
    TilingDispatch dispatch{
        .key =
            {
                .tile_mode = info.tile_mode,
                .num_bits = info.num_bits,
                .num_samples = info.num_samples,
                .is_tiler = is_tiler,
            },
        .array_mode = info.array_mode,
        .is_macro = is_macro,
        .constants =
            {
                info.num_samples,
                u32(micro_tile_mode),
                AmdGpu::GetMicroTileThickness(info.array_mode),
                u32(is_tiler),
            },
        .num_constants = is_macro ? 12u : 4u,
        .tiled = tiled,
        .linear = linear,
        .params = params,
    };
    // 64 threads a group, eight threads (a row of 8 texels each) per unit of 64 texels, units
    // of 64 texels per mip (tiling.comp): the groups handle 8 units, the rest of the last group
    // ends at once. The mips are the ones the kernel is given (TilingInfo, levels).
    const u32 bytes_per_texel = info.num_bits / 8;
    u32 units = 0;
    for (u32 mip = 0; mip < std::min<u32>(info.resources.levels, info.mips_layout.size()); ++mip) {
        units += (info.mips_layout[mip].size / bytes_per_texel + 63) / 64;
    }
    dispatch.group_count_x = (units + 7) / 8;
    if (is_macro) {
        auto& spec_data = dispatch.constants;
        const auto macro_tile_mode =
            AmdGpu::CalculateMacrotileMode(info.tile_mode, info.num_bits, info.num_samples);
        spec_data[4] = u32(info.array_mode);
        spec_data[5] = u32(AmdGpu::GetPipeConfig(info.tile_mode));
        spec_data[6] = AmdGpu::GetBankWidth(macro_tile_mode);
        spec_data[7] = AmdGpu::GetBankHeight(macro_tile_mode);
        spec_data[8] = AmdGpu::GetNumBanks(macro_tile_mode);
        spec_data[9] = std::bit_width(spec_data[8]) - 1;
        spec_data[10] = AmdGpu::CalculateTileSplit(info.tile_mode, info.array_mode, micro_tile_mode,
                                                   info.num_bits);
        spec_data[11] = AmdGpu::GetMacrotileAspect(macro_tile_mode);
    }
    return dispatch;
}

std::pair<const Buffer*, u64> TileManager::DetileImage(const VideoCore::Buffer* in_buffer,
                                                       u64 in_offset, const ImageInfo& info) {
    if (!info.props.is_tiled) {
        return {in_buffer, in_offset};
    }

    TilingInfo params{};
    params.bank_swizzle = info.bank_swizzle;
    params.micro_tiled_mips = info.micro_tiled_mips;
    params.num_mips = info.resources.levels;
    for (u32 mip = 0; mip < params.num_mips; ++mip) {
        auto& mip_info = params.mips[mip];
        mip_info = info.mips_layout[mip];
        if (info.props.is_block) {
            mip_info.pitch = std::max((mip_info.pitch + 3) / 4, 1U);
            mip_info.height = std::max((mip_info.height + 3) / 4, 1U);
        }
    }

    const KernelBuffer params_buffer_info{
        .buffer = &stream_buffer,
        .offset =
            stream_buffer.Copy(&params, sizeof(params), backend.Limits().uniform_min_alignment),
        .range = sizeof(params),
    };

    const auto staging = backend.StagingRequest(info.guest_size, MemoryType::DeviceLocal);

    backend.EndRendering();
    backend.FlushBarriers();

    const KernelBuffer tiled_buffer_info{
        .buffer = in_buffer,
        .offset = in_offset,
        .range = info.guest_size,
    };
    const KernelBuffer linear_buffer_info{
        .buffer = staging.buffer,
        .offset = staging.offset,
        .range = info.guest_size,
    };
    // bbport: the backend records with copies of the buffer ranges (threaded recording).
    backend.DispatchTiling(
        MakeDispatch(info, false, tiled_buffer_info, linear_buffer_info, params_buffer_info));
    // bbport: the source may be the arena (BB_PREUPLOAD), which later uploads write: a copy into
    // it must wait for this read.
    backend.AccessBuffer(in_buffer, in_offset, info.guest_size,
                         vk::PipelineStageFlagBits2::eComputeShader,
                         vk::AccessFlagBits2::eShaderRead);

    backend.AccessBuffer(staging.buffer, staging.offset, info.guest_size,
                         vk::PipelineStageFlagBits2::eComputeShader,
                         vk::AccessFlagBits2::eShaderWrite);

    return {staging.buffer, staging.offset};
}

void TileManager::TileImage(Image& in_image, std::span<vk::BufferImageCopy> buffer_copies,
                            const VideoCore::Buffer* out_buffer, u64 out_offset) {
    const auto& info = in_image.info;
    if (!info.props.is_tiled) {
        for (auto& copy : buffer_copies) {
            copy.bufferOffset += out_offset;
        }
        backend.DownloadImage(&in_image, out_buffer, buffer_copies);
        return;
    }

    TilingInfo params{};
    params.bank_swizzle = info.bank_swizzle;
    params.micro_tiled_mips = info.micro_tiled_mips;
    params.num_mips = static_cast<u32>(buffer_copies.size());
    for (u32 mip = 0; mip < params.num_mips; ++mip) {
        auto& mip_info = params.mips[mip];
        mip_info = info.mips_layout[mip];
        if (info.props.is_block) {
            mip_info.pitch = std::max((mip_info.pitch + 3) / 4, 1U);
            mip_info.height = std::max((mip_info.height + 3) / 4, 1U);
        }
    }

    const KernelBuffer params_buffer_info{
        .buffer = &stream_buffer,
        .offset =
            stream_buffer.Copy(&params, sizeof(params), backend.Limits().uniform_min_alignment),
        .range = sizeof(params),
    };

    const auto staging = backend.StagingRequest(info.guest_size, MemoryType::DeviceLocal);
    for (auto& copy : buffer_copies) {
        copy.bufferOffset += staging.offset;
    }

    backend.DownloadImage(&in_image, staging.buffer, buffer_copies);
    backend.FlushBarriers();

    const KernelBuffer tiled_buffer_info{
        .buffer = out_buffer,
        .offset = out_offset,
        .range = info.guest_size,
    };
    const KernelBuffer linear_buffer_info{
        .buffer = staging.buffer,
        .offset = staging.offset,
        .range = info.guest_size,
    };
    // bbport: the backend records with copies of the buffer ranges (threaded recording).
    backend.DispatchTiling(
        MakeDispatch(info, true, tiled_buffer_info, linear_buffer_info, params_buffer_info));

    backend.AccessBuffer(out_buffer, out_offset, info.guest_size,
                         vk::PipelineStageFlagBits2::eComputeShader,
                         vk::AccessFlagBits2::eShaderWrite);
}

} // namespace VideoCore
