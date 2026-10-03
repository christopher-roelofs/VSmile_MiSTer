# Third-party provenance

## µ'nSP CPU and V.Smile reference behavior

`src/core/unsp.cpp` is adapted from the user's
`mister_vtech/rtl/unsp/unsp_core.sv` and the MAME µ'nSP interpreter.
The original MAME CPU implementation credits Segher Boessenkool, Ryan Holtz,
and David Haywood and is licensed GPL-2.0-or-later. Board banking and DMA
behavior are adapted from the user's MiSTer implementation and its MAME
reference sources. Cheshire's implementation is GPL-2.0-or-later.

`src/core/soc.cpp` and `src/core/controller.cpp` implement timer, video-control,
GPIO, UART and controller behavior from the user's `spg2xx_io.sv`,
`spg2xx_vctl.sv` and `vsmile_pad.sv`, checked against the local MAME reference.

Local MiSTer source inspected at commit
`6ba41c5` (with its existing working tree). Local MAME reference revision:
`96016fbe55c76c38214da2fc0a189455630fd2fb`.

## SPG2xx scanline renderer

`src/core/ppu_renderer.hpp` adapts
`mister_vtech/sim/soc/ppu_ref.h`, a C++ port of MAME's
`spg_renderer_device`, including the user's vertical compression work.

Copyright holders: David Haywood and Ryan Holtz.

BSD 3-Clause License:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## Build dependencies

SDL2 is under the zlib license. Optional zlib is under the zlib license.
Their source packages retain their own license files; CMake discovers system
packages or optionally downloads the pinned SDL2 source. No dependency source
or proprietary firmware is checked into this project.
