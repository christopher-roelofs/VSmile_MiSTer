// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>
#include "cheshire/state.hpp"

namespace cheshire {
struct PpuRenderer;
// Scanline-timed picture output. Like the FPGA core, line y is drawn from the
// state at the start of line y-1, and the frame is published at vblank.
class Display {
public:
    static constexpr unsigned width = 320, rendered_lines = 240;
    Display(const std::uint16_t* video_registers, std::function<std::uint16_t(std::uint32_t)> read);
    Display(const Display&) = delete;
    Display& operator=(const Display&) = delete;
    ~Display();
    void reset(bool pal, unsigned sprite_count);
    void update_vertical_compression();
    void render_line(unsigned y);
    void finish_frame();
    // Last complete frame (ARGB8888, 240 or 288 lines), and how many completed.
    const std::vector<std::uint32_t>& frame() const { return completed_; }
    std::uint64_t completed_frames() const { return completed_frames_; }
    // Whole frame from the current state, for the demo and paused stepping.
    std::vector<std::uint32_t> snapshot() const;
    void serialize(StateArchive& archive);
private:
    std::unique_ptr<PpuRenderer> renderer_;
    std::vector<std::uint32_t> working_, completed_;
    std::uint64_t completed_frames_ = 0;
    void draw(unsigned y, std::vector<std::uint32_t>& frame) const;
};
}
