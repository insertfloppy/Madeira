// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// The few liblzma calls ModArchives.swift uses to unpack .7z mods (LZMA and
// LZMA2). The iOS SDK ships liblzma.tbd without headers, so the public ABI is
// declared here under Madeira's own type names (lzma_stream, lzma_filter and
// lzma_options_lzma in liblzma's lzma/base.h, lzma/filter.h, lzma/lzma12.h).

#ifndef ModArchiveLZMA_h
#define ModArchiveLZMA_h

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const uint8_t *next_in;
    size_t avail_in;
    uint64_t total_in;
    uint8_t *next_out;
    size_t avail_out;
    uint64_t total_out;
    const void *allocator;
    void *internal;
    void *reserved_ptr1, *reserved_ptr2, *reserved_ptr3, *reserved_ptr4;
    uint64_t reserved_int1, reserved_int2;
    size_t reserved_int3, reserved_int4;
    int reserved_enum1, reserved_enum2;
} madeira_lzma_stream;

typedef struct {
    uint64_t id;
    void *options;
} madeira_lzma_filter;

/// lzma_options_lzma; the tail leaves room for fields newer liblzma versions add.
typedef struct {
    uint32_t dict_size;
    const uint8_t *preset_dict;
    uint32_t preset_dict_size;
    uint32_t lc, lp, pb;
    int mode;
    uint32_t nice_len;
    int mf;
    uint32_t depth;
    uint32_t reserved_ints[16];
    void *reserved_ptrs[4];
} madeira_lzma_options;

int lzma_raw_decoder(madeira_lzma_stream *strm, const madeira_lzma_filter *filters);
int lzma_alone_decoder(madeira_lzma_stream *strm, uint64_t memlimit);
int lzma_code(madeira_lzma_stream *strm, int action);
void lzma_end(madeira_lzma_stream *strm);

#endif
