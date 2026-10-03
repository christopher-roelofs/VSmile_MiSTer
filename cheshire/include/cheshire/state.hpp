// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <deque>
#include <span>
#include <string>
#include <stdexcept>
#include <type_traits>
#include <vector>

namespace cheshire {
namespace detail {
template<class T> struct Stored { using type = std::make_unsigned_t<T>; };
template<class T> requires std::is_enum_v<T> struct Stored<T> { using type = std::make_unsigned_t<std::underlying_type_t<T>>; };
template<> struct Stored<bool> { using type = std::uint8_t; };
}
// One routine per class both saves and loads its state: integers are stored
// little-endian at their own width, so files move between hosts.
class StateArchive {
public:
    static StateArchive writer() { return StateArchive(); }
    static StateArchive reader(std::span<const std::uint8_t> data) {
        StateArchive archive;
        archive.loading_ = true;
        archive.data_.assign(data.begin(), data.end());
        return archive;
    }
    bool loading() const { return loading_; }
    const std::vector<std::uint8_t>& data() const { return data_; }

    template<class T> requires std::is_integral_v<T> || std::is_enum_v<T>
    void operator()(T& value) {
        using U = typename detail::Stored<T>::type;
        U bits = 0;
        if (loading_) {
            const auto bytes = take(sizeof(U));
            for (unsigned i = 0; i < sizeof(U); ++i) bits |= U(U(bytes[i]) << (8 * i));
            if constexpr (std::is_same_v<T, bool>) {
                if (bits > 1) throw std::runtime_error("Corrupt save state");
                value = bits != 0;
            } else value = static_cast<T>(bits);
        } else {
            bits = static_cast<U>(value);
            for (unsigned i = 0; i < sizeof(U); ++i) data_.push_back(std::uint8_t(bits >> (8 * i)));
        }
    }
    template<class T, std::size_t N> void operator()(std::array<T, N>& values) { for (auto& v : values) (*this)(v); }
    template<class T, std::size_t N> void operator()(T (&values)[N]) { for (auto& v : values) (*this)(v); }
    // Fixed-size buffers: the size is recorded and must match on load.
    template<class T> void operator()(std::vector<T>& values) {
        auto size = std::uint32_t(values.size());
        (*this)(size);
        if (loading_ && size != values.size()) throw std::runtime_error("Save state does not match this machine");
        for (auto& v : values) (*this)(v);
    }
    void operator()(std::deque<std::uint8_t>& values) {
        auto size = std::uint32_t(values.size());
        (*this)(size);
        if (loading_) { if (size > 4096) throw std::runtime_error("Corrupt save state"); values.assign(size, 0); }
        for (auto& v : values) (*this)(v);
    }
    // Section markers catch a truncated or mismatched file early.
    void section(const char (&name)[5]) {
        if (!loading_) { data_.insert(data_.end(), name, name + 4); return; }
        const auto bytes = take(4);
        if (std::memcmp(bytes, name, 4) != 0) throw std::runtime_error(std::string("Corrupt save state (section ") + name + ")");
    }
    void finish() const { if (loading_ && position_ != data_.size()) throw std::runtime_error("Corrupt save state (trailing data)"); }
private:
    std::vector<std::uint8_t> data_;
    std::size_t position_ = 0;
    bool loading_ = false;
    StateArchive() = default;
    const std::uint8_t* take(std::size_t count) {
        if (data_.size() - position_ < count) throw std::runtime_error("Corrupt save state (truncated)");
        const auto* bytes = data_.data() + position_;
        position_ += count;
        return bytes;
    }
};
}
