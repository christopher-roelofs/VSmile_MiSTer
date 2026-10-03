// SPDX-License-Identifier: BSD-3-Clause
// Reference scanline renderer for the SPG2xx PPU: a direct C++ port of
// MAME's spg_renderer_device (src/devices/machine/spg_renderer.cpp,
// David Haywood / Ryan Holtz, BSD-3-Clause), reading from a memory
// callback so it can render from exactly the state the RTL renders from.
//
// Features inherited from the RTL reference: tile pages (row scroll and
// extended attributes), sprites, blending and vertical compression.
// Line-map and hi-colour modes remain unimplemented.
#pragma once
#include <cstdint>
#include <functional>
#include <cstdio>

namespace cheshire {
struct PpuRenderer {
    std::function<uint16_t(uint32_t)> read;     // 22-bit word address
    const uint16_t* regs;                       // video registers 0x2800..

    // vertical compression: MAME's m_ycmp_table, "skip" (0xffffffff) at
    // reset, rebuilt by update_vcmp() on every write to registers 0x1C-0x1E
    uint32_t ycmp[480];
    PpuRenderer() { for (auto& e : ycmp) e = 0xffffffff; }
    void update_vcmp() {                        // MAME update_vcmp_table
        int currentline = 0;
        int step = regs[0x1e] & 0xff;
        if (step & 0x80) step -= 0x100;
        int current_inc_value = regs[0x1c] << 4;
        int counter = 0;
        for (int i = 0; i < 480; i++) {
            if (i < regs[0x1d]) ycmp[i] = 0xffffffff;
            else {
                if (currentline >= 0 && currentline < 256) ycmp[i] = currentline;
                counter += current_inc_value;
                while (counter >= (0x20 << 4)) { currentline++; current_inc_value += step; counter -= (0x20 << 4); }
            }
        }
    }
    const uint16_t* vram;                       // 0x2800.. (palette at 0x300, sprites 0x400)
    uint16_t linebuf[320];
    bool dbg = false;
    unsigned sprite_count = 256;

    static uint8_t mix(uint8_t bottom, uint8_t top, uint8_t alpha) {
        return ((0x20 - alpha) * bottom + alpha * top) >> 5;
    }

    void tilestrip(uint32_t drawwidthmask, bool blend, bool flip_x, uint32_t tile_h, uint32_t tile_w,
                   uint32_t gfxaddr, uint32_t tile, uint32_t tile_scanline, int drawx, bool flip_y,
                   uint32_t palette_offset, uint32_t nc_bpp, uint32_t bits_per_row, uint32_t words_per_tile,
                   uint8_t blendlevel) {
        const uint16_t* palette = vram + 0x300;
        const uint32_t yflipmask = flip_y ? tile_h - 1 : 0;
        uint32_t m = gfxaddr + words_per_tile * tile + bits_per_row * (tile_scanline ^ yflipmask);
        if (dbg) printf("  REF strip row=%06X drawx=%3d w=%2d bpr=%2d pal=%02X fx=%d bl=%d (tile %04X line %u)\n",
                        m, drawx & 0x1ff, tile_w, bits_per_row, palette_offset, flip_x, blend, tile, tile_scanline);
        uint32_t bits = 0, nbits = 0;
        for (int32_t x = flip_x ? (int32_t)(tile_w - 1) : 0; flip_x ? x >= 0 : x < (int32_t)tile_w; flip_x ? x-- : x++) {
            int realdrawpos = (drawx + x) & drawwidthmask;
            bits <<= nc_bpp;
            if (nbits < nc_bpp) {
                uint16_t b = read(m++ & 0x3fffff);
                b = (b << 8) | (b >> 8);
                bits |= b << (nc_bpp - nbits);
                nbits += 16;
            }
            nbits -= nc_bpp;
            uint32_t pal = palette_offset + (bits >> 16);
            bits &= 0xffff;
            if (realdrawpos >= 0 && realdrawpos < 320) {
                uint16_t rgb = palette[pal & 0xff];
                if (!(rgb & 0x8000)) {
                    uint16_t& d = linebuf[realdrawpos];
                    if (blend && !(d & 0x8000))
                        d = (mix((d >> 10) & 0x1f, (rgb >> 10) & 0x1f, blendlevel) << 10) |
                            (mix((d >> 5) & 0x1f, (rgb >> 5) & 0x1f, blendlevel) << 5) |
                            (mix(d & 0x1f, rgb & 0x1f, blendlevel));
                    else
                        d = rgb;
                }
            }
        }
    }

    void page(uint32_t scanline, int priority, uint16_t gfxseg, const uint16_t* scrollregs, const uint16_t* tilemapregs) {
        const uint32_t attr = tilemapregs[0], ctrl = tilemapregs[1];
        if (!(ctrl & 0x0008)) return;
        if (((attr & 0x3000) >> 12) != (uint32_t)priority) return;
        if (ctrl & 0x0001) return;      // linemap: not implemented in RTL
        uint32_t logical = scanline;
        if (ctrl & 0x0040) {            // vertical compression
            logical = ycmp[scanline];
            if (logical == 0xffffffff) return;
        }
        const uint32_t gfxaddr = gfxseg * 0x40;
        const uint32_t xscroll = scrollregs[0], yscroll = scrollregs[1];
        const uint32_t tilemap_rambase = tilemapregs[2], exattr_rambase = tilemapregs[3];
        const int tile_width = (attr & 0x0030) >> 4;
        const uint32_t tile_h = 8 << ((attr & 0x00c0) >> 6), tile_w = 8 << tile_width;
        const uint32_t tile_count_x = 512 / tile_w;
        const uint32_t bitmap_y = (logical + yscroll) & 0xff;
        const uint32_t y0 = bitmap_y / tile_h, tile_scanline = bitmap_y % tile_h;
        const uint32_t nc_bpp = ((attr & 3) + 1) << 1;
        const uint32_t bits_per_row = nc_bpp * tile_w / 16;
        const uint32_t words_per_tile = bits_per_row * tile_h;
        static const uint8_t s_blend[4] = {0x08, 0x10, 0x18, 0x20};
        const uint8_t blendlevel = s_blend[regs[0x2a] & 3];
        int realxscroll = xscroll;
        if (ctrl & 0x0010) realxscroll += (int16_t)vram[0x100 + ((logical + yscroll) & 0xff)];
        const int upperscrollbits = realxscroll >> (tile_width + 3);
        const int endpos = (320 + tile_w) / tile_w;
        for (int x0 = 0; x0 < endpos; x0++) {
            const int realx0 = (x0 + upperscrollbits) & (tile_count_x - 1);
            uint32_t tile_address = realx0 + tile_count_x * y0;
            uint32_t tile = (ctrl & 4) ? read(tilemap_rambase) : read(tilemap_rambase + tile_address);
            if (!tile) continue;
            uint32_t tileattr = attr, tilectrl = ctrl;
            if ((tilectrl & 2) == 0) {
                uint16_t ex = (tilectrl & 4) ? read(exattr_rambase) : read(exattr_rambase + tile_address / 2);
                ex = (realx0 & 1) ? (ex >> 8) : (ex & 0xff);
                tileattr = (tileattr & ~0x000c) | ((ex >> 2) & 0x000c);
                tileattr = (tileattr & ~0x0f00) | ((ex << 8) & 0x0f00);
                tilectrl = (tilectrl & ~0x0100) | ((ex << 2) & 0x0100);
            }
            uint32_t palette_offset = (tileattr & 0x0f00) >> 4;
            palette_offset = (palette_offset >> nc_bpp) << nc_bpp;
            const int drawx = (x0 * tile_w) - (realxscroll & (tile_w - 1));
            tilestrip(511, tilectrl & 0x100, tileattr & 4, tile_h, tile_w, gfxaddr, tile, tile_scanline, drawx,
                      tileattr & 8, palette_offset, nc_bpp, bits_per_row, words_per_tile, blendlevel);
        }
    }

    void sprite(uint32_t scanline, int priority, uint32_t gfxaddr, uint32_t base) {
        const uint16_t* spr = vram + 0x400;
        uint32_t tile = spr[base];
        int16_t x = spr[base + 1], y = spr[base + 2];
        uint16_t attr = spr[base + 3];
        if (!tile) return;
        if (((attr & 0x3000) >> 12) != (uint32_t)priority) return;
        const uint32_t tile_h = 8 << ((attr & 0x00c0) >> 6), tile_w = 8 << ((attr & 0x0030) >> 4);
        if (!(regs[0x42] & 2)) {
            x = (160 + x) - tile_w / 2;
            y = (128 - y) - (tile_h / 2);
        }
        x &= 0x1ff; y &= 0x1ff;
        int firstline = y, lastline = (y + (tile_h - 1)) & 0x1ff;
        const bool blend = attr & 0x4000, flip_x = attr & 4, flip_y = attr & 8;
        const uint32_t nc_bpp = ((attr & 3) + 1) << 1;
        const uint32_t bits_per_row = nc_bpp * tile_w / 16, words_per_tile = bits_per_row * tile_h;
        static const uint8_t s_blend[4] = {0x08, 0x10, 0x18, 0x20};
        const uint8_t blendlevel = s_blend[regs[0x2a] & 3];
        uint32_t palette_offset = (attr & 0x0f00) >> 4;
        palette_offset = (palette_offset >> nc_bpp) << nc_bpp;
        if (firstline < lastline) {
            int scanx = (int)scanline - firstline;
            if (scanx >= 0 && (int)scanline <= lastline)
                tilestrip(0x1ff, blend, flip_x, tile_h, tile_w, gfxaddr, tile, scanx, x, flip_y, palette_offset, nc_bpp, bits_per_row, words_per_tile, blendlevel);
        } else {
            int tempfirst = firstline - 512;
            int scanx = (int)scanline - tempfirst;
            if (scanx >= 0 && (int)scanline <= lastline)
                tilestrip(0x1ff, blend, flip_x, tile_h, tile_w, gfxaddr, tile, scanx, x, flip_y, palette_offset, nc_bpp, bits_per_row, words_per_tile, blendlevel);
            scanx = (int)scanline - firstline;
            if (scanx >= 0 && (int)scanline <= lastline + 512)
                tilestrip(0x1ff, blend, flip_x, tile_h, tile_w, gfxaddr, tile, scanx, x, flip_y, palette_offset, nc_bpp, bits_per_row, words_per_tile, blendlevel);
        }
    }

    // MAME screen_update for one scanline
    void line(uint32_t scanline) {
        for (int i = 0; i < 320; i++) linebuf[i] = 0x8000;
        for (int p = 0; p < 4; p++) {
            page(scanline, p, regs[0x20], regs + 0x10, regs + 0x12);
            page(scanline, p, regs[0x21], regs + 0x16, regs + 0x18);
            if (regs[0x42] & 1)
                for (uint32_t n = 0; n < sprite_count; n++) sprite(scanline, p, 0x40 * regs[0x22], 4 * n);
        }
    }
};

} // namespace cheshire
