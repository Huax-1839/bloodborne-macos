// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <span>
#include <utility>

#include "common/types.h"
#include "video_core/buffer_cache/buffer.h"
#include "video_core/cache_backend.h"

namespace VideoCore {

struct ImageInfo;
struct Image;

class TileManager {
public:
    explicit TileManager(CacheBackend& backend, StreamBuffer& stream_buffer);
    ~TileManager();

    void TileImage(Image& in_image, std::span<vk::BufferImageCopy> buffer_copies,
                   const VideoCore::Buffer* out_buffer, u64 out_offset);

    std::pair<const Buffer*, u64> DetileImage(const VideoCore::Buffer* in_buffer, u64 in_offset,
                                              const ImageInfo& info);

    /// The dispatch of the kernel for `info` over the given buffers (the backend runs it).
    static TilingDispatch MakeDispatch(const ImageInfo& info, bool is_tiler,
                                       const KernelBuffer& tiled, const KernelBuffer& linear,
                                       const KernelBuffer& params);

private:
    CacheBackend& backend;
    StreamBuffer& stream_buffer;
};

} // namespace VideoCore
