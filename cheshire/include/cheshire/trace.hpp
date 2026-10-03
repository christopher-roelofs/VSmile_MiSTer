// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "cheshire/machine.hpp"
#include <memory>
#include <iosfwd>

namespace cheshire {
// CPU-only verification: register reads and interrupt timing come from MAME.
// RAM, instructions, banking and DMA are executed by Cheshire.
class TraceSession {
public:
    TraceSession(Machine& machine, const std::filesystem::path& directory, bool audit_io = false);
    ~TraceSession();
    TraceSession(const TraceSession&) = delete;
    TraceSession& operator=(const TraceSession&) = delete;
    bool step(); // false when the instruction capture ends
    std::uint64_t compared() const;
    std::uint64_t register_events() const;
    std::uint64_t io_mismatches() const;
    void print_io_audit(std::ostream& output) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
