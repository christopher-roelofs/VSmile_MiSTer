// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/video.hpp"
#include "ppu_renderer.hpp"
#include <fstream>
#include <stdexcept>

namespace cheshire {
Display::Display(const std::uint16_t* video_registers, std::function<std::uint16_t(std::uint32_t)> read)
    : renderer_(std::make_unique<PpuRenderer>()) {
    renderer_->regs = renderer_->vram = video_registers;
    renderer_->read = std::move(read);
    reset(false, 256);
}
Display::~Display() = default;
void Display::reset(bool pal, unsigned sprite_count) {
    renderer_->sprite_count = sprite_count;
    // MAME starts with every line skipped until a compression register is written.
    for (auto& line : renderer_->ycmp) line = 0xffffffff;
    working_.assign(width * (pal ? 288 : 240), 0xff000000);
    completed_ = working_;
    completed_frames_ = 0;
}
void Display::update_vertical_compression() { renderer_->update_vcmp(); }
void Display::draw(unsigned y, std::vector<std::uint32_t>& frame) const {
    renderer_->line(y);
    // RGB555 to 888 as MAME ((c << 3) | (c >> 2)), then the 0x2830 fade offset;
    // transparent pixels are black.
    const unsigned fade = renderer_->regs[0x30] & 255;
    const auto channel = [fade](unsigned c) { c = (c << 3) | (c >> 2); return c > fade ? c - fade : 0; };
    for (unsigned x = 0; x < width; ++x) {
        const auto rgb = renderer_->linebuf[x] & 0x8000 ? 0 : renderer_->linebuf[x];
        frame[y * width + x] = 0xff000000 | channel((rgb >> 10) & 31) << 16 | channel((rgb >> 5) & 31) << 8 | channel(rgb & 31);
    }
}
void Display::render_line(unsigned y) { if (y < rendered_lines) draw(y, working_); }
void Display::finish_frame() { completed_ = working_; ++completed_frames_; }
std::vector<std::uint32_t> Display::snapshot() const {
    std::vector<std::uint32_t> frame(completed_.size(), 0xff000000);
    for (unsigned y = 0; y < rendered_lines; ++y) draw(y, frame);
    return frame;
}
void Display::serialize(StateArchive& a) {
    a.section("DISP");
    a(renderer_->ycmp); a(renderer_->sprite_count); a(working_); a(completed_); a(completed_frames_);
    if (a.loading() && renderer_->sprite_count != 64 && renderer_->sprite_count != 256) throw std::runtime_error("Corrupt save state (display)");
}
void write_ppm(const std::filesystem::path& path, const std::vector<std::uint32_t>& frame) {
    std::ofstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Cannot open frame output");
    file << "P6\n320 " << frame.size() / 320 << "\n255\n";
    for (const auto pixel : frame) {
        const char bytes[3] = {static_cast<char>(pixel >> 16), static_cast<char>(pixel >> 8), static_cast<char>(pixel)};
        file.write(bytes, 3);
    }
    if (!file) throw std::runtime_error("Cannot write frame output");
}
}
