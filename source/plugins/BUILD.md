# The plugins' source

Each plugin is one C file, built against UEVR's plugin API headers (the `include` folder of the UEVR repository; those headers are MIT-licensed, see CREDITS.md). None of them opens a network connection.

| File | Plugin | What it does |
|---|---|---|
| `a_sf_hand.c` | `a_sf_hand.dll` | Swaps the pad's two trigger values for a left-handed player, before joytokey reads them. Off until the script asks. |
| `sf_inv.c` | `sf_inv.dll` | Reads the player's equipped-item lists (read-only). |
| `sf_kbd.c` | `sf_kbd.dll` | SteamVR's floating keyboard for terminals and text boxes; fade to black through SteamVR's compositor. |
| `sf_keys.c` | `sf_keys.dll` | Presses keys with virtual-key and scan code, the way a real keyboard does. |
| `sf_mat.c` | `sf_mat.dll` | Reads arrays of structs from game objects, used for the sights' material values (read-only). |
| `sf_perf.c` | `sf_perf.dll` | Frame times, per-thread CPU load and GPU use for the mod's log (read-only). |
| `sf_start.c`, `sf_start_logic.h`, `sf_start_actions.h` | `sf_start.dll` | Puts the profile's two start-up files right before UEVR reads them. |
| `sf_txt.c` | `sf_txt.dll` | Reads the game's text values and can set a text widget's text. |
| `sf_start_test.c` | (test program) | Runs the two text fixes of `sf_start` against real files. Plain C, any platform. |

## Building

With MinGW-w64 (the shipped binaries were built with `x86_64-w64-mingw32-gcc` 13, win32 threads, on Linux):

```
UEVR=/path/to/UEVR            # a checkout of praydog's UEVR, for its include folder

x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -o a_sf_hand.dll a_sf_hand.c
x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -o sf_inv.dll    sf_inv.c
x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -o sf_keys.dll   sf_keys.c
x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -o sf_mat.dll    sf_mat.c
x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -o sf_txt.dll    sf_txt.c
x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -o sf_start.dll  sf_start.c
x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -o sf_perf.dll   sf_perf.c -lpdh
x86_64-w64-mingw32-gcc -O2 -shared -s -I$UEVR/include -I$UEVR/dependencies/openvr/headers -o sf_kbd.dll sf_kbd.c
```

A rebuild matches the shipped binary except for the time stamp in the file header and, if the output path differs, the preferred load address the linker derives from it.

The test program:

```
cc -o sf_start_test sf_start_test.c
./sf_start_test <a config.txt> <UEVR's own actions.json> <the profile's actions.json>
```

## How the plugins talk to the script

Through UEVR's custom events. The script sends `uevr.api:dispatch_custom_event("<name>", "<command>")`; a plugin answers with `dispatch_lua_event("<name>", "<text>")`. The commands each plugin understands are in the comment at the top of its source file.
