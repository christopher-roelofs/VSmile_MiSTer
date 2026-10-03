// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/trace.hpp"
#include <array>
#include <fstream>
#include <iomanip>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <map>
#ifdef CHESHIRE_HAVE_ZLIB
#include <zlib.h>
#endif

namespace cheshire {
namespace {
class Lines {
public:
    explicit Lines(std::filesystem::path path) {
        file_.open(path, std::ios::binary);
        if (!file_) {
            file_.clear(); path += ".gz"; file_.open(path, std::ios::binary);
            compressed_ = true;
        }
        if (!file_) throw std::runtime_error("Cannot open trace: " + path.string());
        if (compressed_) {
#ifdef CHESHIRE_HAVE_ZLIB
            if (inflateInit2(&z_, 15 + 16) != Z_OK) throw std::runtime_error("Cannot initialize gzip reader");
            initialized_ = true;
#else
            throw std::runtime_error("Compressed trace requires zlib; provide an uncompressed capture or rebuild with zlib");
#endif
        }
    }
    ~Lines() {
#ifdef CHESHIRE_HAVE_ZLIB
        if (initialized_) inflateEnd(&z_);
#endif
    }
    bool next(std::string& line) {
        line.clear();
        while (true) {
            if (pos_ == end_ && !refill()) return false; // discard incomplete final line
            const char c = output_[pos_++];
            if (c == '\n') { if (!line.empty() && line.back() == '\r') line.pop_back(); return true; }
            if (line.size() == 65536) throw std::runtime_error("Trace line exceeds 64 KB");
            line += c;
        }
    }
private:
    std::ifstream file_;
    bool compressed_ = false, ended_ = false;
    std::array<char, 65536> output_{};
    std::size_t pos_ = 0, end_ = 0;
#ifdef CHESHIRE_HAVE_ZLIB
    z_stream z_{};
    bool initialized_ = false;
    std::array<unsigned char, 65536> input_{};
#endif
    bool refill() {
        pos_ = end_ = 0;
        if (ended_) return false;
        if (!compressed_) {
            file_.read(output_.data(), static_cast<std::streamsize>(output_.size()));
            end_ = static_cast<std::size_t>(file_.gcount());
            if (file_.bad()) throw std::runtime_error("Trace read failed");
            return end_ != 0;
        }
#ifdef CHESHIRE_HAVE_ZLIB
        z_.next_out = reinterpret_cast<Bytef*>(output_.data());
        z_.avail_out = static_cast<uInt>(output_.size());
        while (z_.avail_out == output_.size() && !ended_) {
            if (z_.avail_in == 0) {
                file_.read(reinterpret_cast<char*>(input_.data()), static_cast<std::streamsize>(input_.size()));
                const auto count = file_.gcount();
                if (!count) throw std::runtime_error("Truncated gzip trace");
                z_.next_in = input_.data(); z_.avail_in = static_cast<uInt>(count);
            }
            const auto result = inflate(&z_, Z_NO_FLUSH);
            if (result == Z_STREAM_END) ended_ = true;
            else if (result != Z_OK) throw std::runtime_error("Invalid gzip trace");
        }
        end_ = output_.size() - z_.avail_out;
        return end_ != 0;
#else
        return false;
#endif
    }
};
struct Entry {
    std::array<std::uint16_t, 7> regs{};
    std::uint32_t pc = 0;
    int interrupt = -1;
};
bool parse_entry(const std::string& line, Entry& entry) {
    std::istringstream input(line);
    input >> std::hex;
    unsigned value;
    for (auto& reg : entry.regs) {
        if (!(input >> value) || value > 0xffff) return false;
        reg = std::uint16_t(value);
    }
    char colon;
    return bool(input >> entry.pc >> colon) && entry.pc <= 0x3fffff && colon == ':';
}
}

struct TraceSession::Impl {
    Machine& machine;
    Lines cpu, memory;
    std::optional<Entry> pending;
    std::uint64_t count = 0, events = 0;
    struct Audit { std::uint64_t equal = 0, different = 0, first_instruction = 0; std::uint16_t expected = 0, actual = 0; };
    std::map<std::uint32_t, Audit> audit;
    bool audit_io;
    Impl(Machine& m, const std::filesystem::path& dir, bool compare_io)
        : machine(m), cpu(dir / "cpu.tr"), memory(dir / "mem.log"), audit_io(compare_io) {}
    bool next_entry(Entry& entry) {
        std::string line;
        if (!pending) {
            Entry next;
            while (cpu.next(line)) if (parse_entry(line, next)) { pending = next; break; }
        }
        if (!pending) return false;
        entry = *pending; pending.reset();
        while (cpu.next(line)) {
            const auto marker = line.find("IRQ ");
            if (marker != std::string::npos && line.find("(interrupted at") != std::string::npos) {
                std::istringstream input(line.substr(marker + 4));
                if (!(input >> entry.interrupt) || entry.interrupt < 0 || entry.interrupt > 8)
                    throw std::runtime_error("Invalid interrupt trace marker");
                continue;
            }
            Entry next;
            if (parse_entry(line, next)) { pending = next; break; }
        }
        return true;
    }
    std::uint16_t access(char kind, std::uint32_t address, std::uint16_t data) {
        std::string line;
        if (!memory.next(line)) throw std::runtime_error("Register capture ended before CPU capture at instruction " + std::to_string(count));
        std::istringstream input(line);
        char expected_kind;
        unsigned expected_address, expected_data;
        if (!(input >> expected_kind >> std::hex >> expected_address >> expected_data) || expected_data > 0xffff)
            throw std::runtime_error("Invalid register trace line: " + line);
        if (kind != expected_kind || address != expected_address || (kind == 'W' && data != expected_data)) {
            std::ostringstream error;
            error << "Register mismatch at instruction " << count << ": expected " << line
                  << ", got " << kind << ' ' << std::hex << address << ' ' << data;
            throw std::runtime_error(error.str());
        }
        ++events;
        if (audit_io && kind == 'R' && ((address >= 0x2800 && address <= 0x28ff) || (address >= 0x3d00 && address <= 0x3dff))) {
            auto& stats = audit[address];
            if (data == expected_data) ++stats.equal;
            else {
                if (!stats.different) { stats.first_instruction = count; stats.expected = std::uint16_t(expected_data); stats.actual = data; }
                ++stats.different;
            }
        }
        return std::uint16_t(expected_data);
    }
    bool step() {
        Entry entry;
        if (!next_entry(entry)) {
            if (count == 0) throw std::runtime_error("CPU capture contains no complete instruction entries");
            return false;
        }
        // MAME trace order is R1 R2 R3 R4 SP BP SR, before instruction fetch.
        constexpr std::array<unsigned, 7> order = {1, 2, 3, 4, 0, 5, 6};
        const auto& r = machine.cpu().state().r;
        bool equal = machine.cpu().pc() == entry.pc;
        for (unsigned i = 0; i < order.size(); ++i) equal &= r[order[i]] == entry.regs[i];
        if (!equal) {
            std::ostringstream error;
            error << "CPU mismatch before instruction " << count << ": PC expected " << std::hex << entry.pc
                  << ", got " << machine.cpu().pc();
            for (unsigned i = 0; i < order.size(); ++i)
                if (r[order[i]] != entry.regs[i]) error << "; r" << order[i] << " expected " << entry.regs[i] << ", got " << r[order[i]];
            throw std::runtime_error(error.str());
        }
        const auto result = machine.step(entry.interrupt < 0 ? 0 : std::uint16_t(1u << entry.interrupt));
        if (result.interrupt != entry.interrupt) throw std::runtime_error("CPU interrupt acceptance differs from trace at instruction " + std::to_string(count));
        ++count;
        return true;
    }
};
TraceSession::TraceSession(Machine& m, const std::filesystem::path& dir, bool audit_io) : impl_(std::make_unique<Impl>(m, dir, audit_io)) {
    // Caller selects erased BIOS for MAME's placeholder captures.
    m.set_register_hook([this](char k, std::uint32_t a, std::uint16_t d) { return impl_->access(k, a, d); });
}
TraceSession::~TraceSession() { impl_->machine.set_register_hook({}); }
bool TraceSession::step() { return impl_->step(); }
std::uint64_t TraceSession::compared() const { return impl_->count; }
std::uint64_t TraceSession::register_events() const { return impl_->events; }
std::uint64_t TraceSession::io_mismatches() const {
    std::uint64_t total = 0;
    for (const auto& [address, stats] : impl_->audit) { (void)address; total += stats.different; }
    return total;
}
void TraceSession::print_io_audit(std::ostream& output) const {
    std::uint64_t matches = 0;
    for (const auto& [address, stats] : impl_->audit) { (void)address; matches += stats.equal; }
    output << "Timed video/I/O reads: " << matches << " matched, " << io_mismatches() << " differed\n";
    for (const auto& [address, stats] : impl_->audit)
        if (stats.different) output << "  register 0x" << std::hex << address << std::dec << ": " << stats.different
            << " differences; first at instruction " << stats.first_instruction << ", expected 0x" << std::hex << stats.expected
            << ", actual 0x" << stats.actual << std::dec << '\n';
}
}
