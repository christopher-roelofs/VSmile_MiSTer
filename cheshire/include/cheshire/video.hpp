// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "cheshire/machine.hpp"
#include <vector>

namespace cheshire {
// The scanline-timed frame once one has completed; before that (or for the
// demo, which runs only a few instructions per presentation) a snapshot.
inline std::vector<std::uint32_t> presented_frame(const Machine& machine, bool snapshot = false) {
    const auto& display = machine.display();
    return snapshot || !display.completed_frames() ? display.snapshot() : display.frame();
}
void write_ppm(const std::filesystem::path& path, const std::vector<std::uint32_t>& frame);
}
