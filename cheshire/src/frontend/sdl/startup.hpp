// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <SDL.h>

namespace cheshire {
// Choose the native desktop backend before SDL probes video or creates windows.
// Honor explicit choices, including the dummy backend used by smoke tests.
inline int prepare_video_driver() {
#if defined(__linux__)
    const char* wayland = SDL_getenv("WAYLAND_DISPLAY");
    if (wayland && *wayland && !SDL_getenv("SDL_VIDEODRIVER")) {
        SDL_version version;
        SDL_GetVersion(&version);
        // Older SDL2 versions do not accept ordered driver preference lists.
        const char* drivers = SDL_VERSIONNUM(version.major, version.minor, version.patch)
                                  >= SDL_VERSIONNUM(2, 0, 22)
                              ? "wayland,x11" : "wayland";
        return SDL_setenv("SDL_VIDEODRIVER", drivers, 0);
    }
#endif
    return 0;
}
}
