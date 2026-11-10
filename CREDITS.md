# Credits and third-party notices

Project Silverfish VR is published by Blind. This file says whose work it stands on, and under what terms each piece is here.

## Thanks

**praydog**, for [UEVR](https://github.com/praydog/UEVR). Everything in this mod runs inside it.

**Markmon (mark-mon)**, for [uevr-joytokey](https://github.com/mark-mon/uevr-joytokey), the plugin that turns controller buttons into key presses. Project Silverfish has no gamepad support at all, so without it there would be no buttons.

**jbusfield**, for [uevrlib](https://github.com/jbusfield/uevrlib). Two techniques in `sf_main.lua` are modelled on it: showing a single widget on the 2D screen, and detecting a level change. No code was copied.

**Siris Pendrake**, for [Project Silverfish](https://store.steampowered.com/app/2941710/Project_Silverfish).

The **Flat2VR** community.

Designed, directed and play-tested in the headset by Blind. The code was written with Claude, Anthropic's AI model.

## What is covered by which terms

### The mod's own files: MIT

`scripts/sf_main.lua`, the plugins `a_sf_hand`, `sf_inv`, `sf_kbd`, `sf_keys`, `sf_mat`, `sf_perf`, `sf_start`, `sf_txt` (binaries and their source in `source/plugins`), `bindings_frame_controller.json`, `joytokey.txt` from the "PROJECT SILVERFISH VR" line down, and the documentation are Copyright (c) 2026 Blind and released under the MIT licence in [LICENSE](LICENSE).

### UEVR: not included

UEVR itself is Copyright (c) 2022-2025 praydog, all rights reserved. It is not part of this package; get it from praydog's GitHub.

`config.txt`, `cameras.txt` and `actions.json` are files UEVR itself writes into a game's profile folder. They are here with this game's settings in them, and `actions.json` has one entry added (the Steam Frame controller layout). `source/plugins/sf_start_actions.h` carries the same `actions.json` text so that `sf_start.dll` can write the file on a first start.

The mod's plugins are built against UEVR's plugin API headers (`API.h`, `API.hpp`, `Plugin.hpp`), which praydog licenses separately from the rest of UEVR:

```
This file (API.h) is licensed under the MIT license and is separate from the rest of the UEVR codebase.

Copyright (c) 2023 praydog

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### uevr-joytokey: included with credit, no published licence

`plugins/joytokey.dll` is a modified build of uevr-joytokey by mark-mon, and `source/joytokey-fork/main.cpp` is its modified source. The first 38 lines of `plugins/joytokey.txt` are that project's own documentation.

As of 10 November 2026 the uevr-joytokey repository publishes no licence. The plugin is included here in the way its README describes it being used (the DLL and its text file in a game's plugin folder), with credit and with every change marked. All rights in the original code remain with its author. If the author would rather it were not distributed here, it will be removed.

What was changed for this mod is listed in `source/joytokey-fork/README.md`.

### OpenVR

`sf_kbd.dll` is compiled with the C header of Valve's OpenVR SDK (`openvr_capi.h`) and calls the OpenVR runtime that SteamVR provides.

```
Copyright (c) 2015, Valve Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
may be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Build tools

The `sf_*` plugins are built with MinGW-w64 GCC 13; `joytokey.dll` was built with llvm-mingw. Each links small parts of its toolchain's runtime (MinGW-w64 runtime, libgcc, libc++), which their licences allow without further notice.

### Project Silverfish

No file of the game is included, changed or redistributed. Project Silverfish is the work of Siris Pendrake. This mod is not affiliated with or endorsed by the game's developer, by praydog, or by Valve.
