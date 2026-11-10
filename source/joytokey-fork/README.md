# joytokey, as modified for Project Silverfish VR

`main.cpp` in this folder is the source of `plugins/joytokey.dll`. It is [uevr-joytokey](https://github.com/mark-mon/uevr-joytokey) by mark-mon with changes for this one game. The original is his work; see CREDITS.md for the terms it is here under.

To build it you also need `main.h` and the `uevr` folder from the upstream repository. The copy of `main.h` this build used was not kept, so treat this file as the record of what the DLL does rather than as a build that is guaranteed to reproduce byte for byte.

## What was changed

Every change is marked in the source with "Silverfish fork" or a version note (v3 to v9).

- **Input keeps working while the game is not reading the controller.** The game never reads a gamepad; upstream switched its VR input off for good after the first read. Here it only pauses while the game really is reading.
- **Every button press reaches the game's window.** Windows sends key presses to the focused window and mouse clicks to whatever is under the cursor. If another window has taken focus, focus is given back to the game; if another window covers the cursor spot, the click is posted to the game directly.
- **A keep-alive read of the controller** was added in v6 to v8 and switched off again in v9 (Steam Input answers those reads itself). The code is still in the file; `keepalive_pump()` returns at once.
- **Both stick clicks together open UEVR's menu** (by pressing its menu key), since UEVR only sees that combination when the game reads the controller itself.
- **The right stick scrolls menus** as a mouse wheel.
- **`OFF` in `joytokey.txt`** really switches an input off. Upstream read a plain `0` as the 0 key.
- A hand-swing melee attack, armed by a `1` in `data\sf_melee.txt`. It is off in this mod: the script writes that `1` only when its `melee_swing` setting is on, and that setting is off and not on the settings page.

## One change made in the binary only

The fork wrote a description of the window that had taken focus into UEVR's `log.txt`, title included. For the public build the title is no longer written: in the shipped DLL the format string `%s '%s' pid %lu` reads `%s %.0s pid %lu` (four bytes, same length), so the window's class name and process id are still logged and its title is not. `main.cpp` here still shows the original line in `describe()`.
