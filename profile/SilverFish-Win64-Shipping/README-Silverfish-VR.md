# Project Silverfish VR

**Version 1.0 (build 6.6.52) · by Blind**

A UEVR profile that turns [Project Silverfish](https://store.steampowered.com/app/2941710/Project_Silverfish) into a motion-controlled VR game. Your two hands are tracked, the gun sits in your hand and shoots where its barrel points, long guns can be held with both hands, your body follows your head around the room, the HUD sits inside your helmet, and every menu is a panel in front of you that you point at.

It is built for the **Steam Frame** and its controllers, running through **SteamVR**. Nothing else is supported in this version.

Nothing in the game's own folder is changed and your saves are never touched. The mod lives entirely in UEVR's profile folder for the game.

---

## What you get

- Both hands tracked. Guns, tools and melee weapons are held in the hand and aimed by pointing them; shots follow the barrel.
- Two-handed long guns: grab the fore-grip with your other hand to steady and steer.
- Red dot sights that line up with where the shot lands.
- A buzz on every shot, and three ticks when you pull the trigger while the game has your gun blocked against a wall.
- Walking through the game's own movement (so sprint, stamina and ladders behave), steered by where you look; smooth or snap turning.
- Room-scale: step or lean in your room and the game's body moves with you.
- The game's HUD inside your helmet, plus a small dot that shows where your gun hand points.
- Menus, inventory, traders and terminals as panels in the world, used with a pointer from your hand. An on-screen keyboard comes up for terminals and text boxes.
- A fade to black through level loads, and your height reset at every level start.
- Sound that is heard from your head, not from the gun.
- A left-handed mode (experimental).
- Four graphics presets you can step through from inside the headset.
- Its own settings page in UEVR's menu.

Every weapon and tool on the game's test map was fired or used in the headset for this release. The two things that do not work are listed under [Known issues](#known-issues).

---

## What you need

| | |
|---|---|
| Game | Project Silverfish on Steam. Tested with the public build of 10 November 2026. The game is in Early Access; an update can break the mod. |
| UEVR | The **nightly** build from praydog's GitHub ([UEVR-nightly releases](https://github.com/praydog/UEVR-nightly/releases)). Tested with nightly 01143, commit `4ee5c6b` (UEVR's window title shows `1.05+195-4ee5c6b6`). The 2024 "stable" UEVR is too old. UEVR is not included here. |
| VR runtime | **SteamVR** (OpenVR). The profile selects it. OpenXR is not supported. |
| Headset | **Steam Frame with its own controllers.** The layout uses a D-pad, four face buttons on one hand, bumpers and two-stage grips. Other controllers are not supported in 1.0. |
| Renderer | **DirectX 11.** The game must be started with `-dx11` (see Install). DirectX 12 gave UEVR errors with this game during development. |
| Key bindings | The game's **default** keyboard bindings (see the note under Controls). |
| PC | A fast one. Frame rates on an RTX 5080 are in [Graphics presets](#graphics-presets). |

---

## Install

1. **Launch option.** In Steam: right-click Project Silverfish → Properties → General → Launch Options, and type `-dx11`.
2. **Import the profile.** Download `SilverFish-Win64-Shipping.zip` from the Releases page. Start `UEVRInjector.exe`, click **Import Config** and pick the zip. Do not rename it: UEVR uses the file name as the game's folder name. (If your browser saved it as `SilverFish-Win64-Shipping (1).zip`, rename it back first.) UEVR asks whether you trust a profile that contains DLL plugins. That is expected (what each one does is listed under [What is in the package](#what-is-in-the-package)); answer Yes.
3. **Start SteamVR**, put the headset on, then **start the game** and wait for its main menu.
4. **Inject.** In UEVRInjector pick the process `SilverFish-Win64-Shipping`, make sure the runtime is **OpenVR**, and click Inject.
5. **Click once on the game's window** on the desktop, so Windows sends it keyboard and mouse input. The game is keyboard-and-mouse only; the mod presses its keys for you, and Windows only delivers those to the window in front.

Six seconds after injecting, the mod is running. To see its settings, hold **both stick clicks for a second** to open UEVR's menu and choose **Silverfish VR settings** in the list on the left.

If you would rather not use Import Config: unpack the zip into `%APPDATA%\UnrealVRMod\SilverFish-Win64-Shipping\` so that `config.txt` sits directly in that folder.

### If you had another UEVR profile for this game

Delete or rename the old `%APPDATA%\UnrealVRMod\SilverFish-Win64-Shipping` folder first. Saved "attach to controller" entries from another profile (the `uobjecthook` folder) fight with this mod over the gun.

---

## Controls

This is the right-handed layout. The same list is on the settings page, under Controls.

| Control | What it does |
|---|---|
| Right trigger | Fire, use. In menus: click |
| Left trigger | Aim, second use |
| A | Interact |
| B | Reload. Hold: change ammo type |
| X | Fire mode |
| Y | Jump |
| Right bumper | Tap: pick up. Hold: lower / raise the weapon |
| Left bumper | Weapon light / laser, pry, harvest |
| Left stick | Walk. Click: sprint, until you stop or click again |
| Right stick | Turn. Click: crouch. In menus: scroll |
| D-pad up | Flashlight |
| D-pad down | Inventory |
| D-pad left / right | Previous / next weapon |
| View | Journal |
| Menu | Pause |

### Combinations

These are the mod's own, so they are worth reading once.

| Combination | What it does |
|---|---|
| Right grip + Y | **Crouch-jump.** You jump, and the mod crouches for you a split second later and stands you up when you land. |
| Left grip on a long gun | **Two-handed.** Bring your left hand to the fore-grip or barrel and squeeze the grip. That hand now steadies and steers the gun. Let go to release. |
| Left grip, squeezed fully, + D-pad | **Utility slots** 5 (up), 6 (right), 7 (down), 8 (left). |
| Left grip, squeezed fully, + View | **Next graphics preset**: High → Medium → Low → Performance → High. The controller buzzes one to four times to tell you which one you are on. |
| Left grip (squeezed fully) or left stick click, in menus | **Shift-click.** Hold either one and click with the trigger. This is how you do anything the game does on Shift + click, such as moving a whole stack. |
| Left trigger, while your left hand holds the flashlight | Switches the flashlight between its two holds: a torch (beam where the hand points) and a raised hold for a hand held up by your head. |
| Both stick clicks, held for a second | UEVR's own menu. |

Things people ask about:

- **Is my crouch-jump broken?** Probably not. The game lets you jump less high when your character is hungry. Eat something and try again.
- **The grips have two stages.** A light squeeze is enough for two-handed and for crouch-jump. The utility slots, the graphics preset and shift-click want the left grip squeezed all the way.
- **Throwing.** While you carry an object, the trigger throws it where your hand points. Swing your hand as you pull and it flies harder.
- **Trading: Add Money.** The game's Add Money is a slider under your pointer: move the pointer left or right until the balance pointer is past the trader's first mark, then click. If you would rather have the mod set the amount, there is a switch for that under [Optional extras](#optional-extras).
- **The game's on-screen hints show keyboard keys.** They are the game's own texts. Use the table above.

### Left-handed

Tick **Left-handed** under Controls on the settings page. The gun, the pointer dot and the menu pointer move to your left hand, and these change hands with them:

| Right-handed | Left-handed |
|---|---|
| Right trigger: fire, click | **Left** trigger: fire, click |
| Left trigger: aim, second use, flashlight hold | **Right** trigger: aim, second use, flashlight hold |
| Right bumper: pick up / lower weapon | **Left** bumper: pick up / lower weapon |
| Left bumper: light / laser, pry, harvest | **Right** bumper: light / laser, pry, harvest |
| Right grip + Y: crouch-jump | **Left** grip + Y: crouch-jump |
| Left grip on a long gun: two-handed | **Right** grip on a long gun: two-handed |

Everything else stays where it is: both sticks, A B X Y, the D-pad, View, Menu, and the three left-grip combinations (utility slots, graphics preset, shift-click). The list on the settings page always shows the layout that is in use.

The sticks do not swap on purpose: walking on the left stick and turning on the right is what most VR shooters keep for left-handed players. If you are left-handed and want them swapped, say so in an issue.

This mode is marked experimental because it has been tested by a right-handed player only.

### Key bindings in the game

The game has no gamepad support, so the mod presses keyboard keys and mouse buttons for you. It expects the game's defaults: **F** interact, **R** reload, **X** fire mode, **Space** jump, **V** flashlight, **Tab** inventory, **Left Ctrl** crouch, **Left Shift** sprint, **G** pick up / lower weapon, **J** journal, **Esc** pause, **5 6 7 8** utility slots, left mouse fire, right mouse aim. If you have rebound any of these, set them back.

---

## The settings page

Open UEVR's menu (both stick clicks, held) and choose **Silverfish VR settings**. Every change is saved at once, in `data\sf_settings.txt` inside the profile folder. Delete that file to get every default back.

### Graphics

Four buttons, one per preset. See [Graphics presets](#graphics-presets).

### Controls (Steam Frame)

| Setting | Default | What it does |
|---|---|---|
| Left-handed | off | See above. |
| D-pad left / right: weapons only | on | Stepping through your weapons skips the utility items. |
| Two-handed: the other hand steadies a long gun | on | Turns two-handed holding on or off altogether. |
| Two-handed only while that hand's grip is held | on | Off: the hand takes hold as soon as it is at the fore-grip. |
| Two-handed: the pointer dot follows your gun hand | on | The dot, and what you pick up, follow the hand rather than the barrel. Shots always follow the barrel. |
| Buzz in the gun hand on every shot | on | |
| Three ticks when you fire while the gun is blocked | on | The game blocks a gun that is too close to a wall. |
| Off-hand flashlight starts in the raised hold | off | Off: it starts as a torch. The other hand's trigger switches between the two at any time. |

### Walking and turning

| Setting | Default | What it does |
|---|---|---|
| Snap turn | off | Off is smooth turning. |
| Smooth turn speed | 140 degrees per second | |
| Snap turn angle | 30 degrees | |
| Room-scale: your body follows your head | on | Step or lean in your room and the game's body moves with you. |
| Recentre and reset my height now | button | Use it if the floor is not where your feet are. |
| Recentre and reset my height at every level load | on | |

### Gun in the hand

This section is locked until you tick **Unlock these settings**, so that a stray click cannot move your guns. The lock is back on at every start.

| Setting | Default | What it does |
|---|---|---|
| Gun angle in the hand, all guns | -55 degrees | How far the barrel is tipped down from where the controller points. Change it if every gun points too high or too low for the way you hold the controller. |
| Red dot sights: trim | 0 degrees | Plus raises the dot, so shots land lower. |
| Put these two back to the mod's own values | button | |
| Its place in the hand / Its angle | per gun | Shown while you hold a gun. They move that one gun only. |
| Forget my changes to this gun | button | Puts that one gun back the way the mod holds it by itself. |

### HUD and pointer dot

| Setting | Default |
|---|---|
| Helmet HUD: distance | 1.6 metres |
| Helmet HUD: size | 70 degrees of your view |
| Helmet HUD: height | -8 degrees (minus is lower) |
| Pointer dot where your gun hand points, always on | on |
| Pointer dot size | 1.9 |

### Menus and keyboard

| Setting | Default |
|---|---|
| Menu distance | 0.85 metres |
| Menu size | 0.87 |
| Menu height | -0.3 metres (minus is lower) |
| Menu pointer tilt | -35 degrees |
| On-screen keyboard for terminals and text boxes | on |
| Keyboard in front of you at chest height | on (off: where SteamVR puts it) |
| Keyboard: how far below your eyes | 75 cm |
| Keyboard: how far in front of you | 61 cm |

### Carrying and throwing

| Setting | Default | What it does |
|---|---|---|
| A carried object goes where your hand points | on | So a throw goes there too. Off: it floats near the hand. |
| A harder swing of the hand throws harder | on | |
| Throw strength per m/s of hand speed | 130 | |
| Gentlest throw | 450 cm/s | |
| Hardest throw | 1500 cm/s | The game's own throw is 1000. |

### Optional extras

Off unless you tick them.

| Setting | Default | What it does |
|---|---|---|
| Trading: Add Money sets the amount for you | off | See below. |
| Trading: stop at the trader's second mark instead | off | The higher of the two marks on the balance bar. Only matters while the switch above is on. |

**The trading helper.** With it on: put the items on the table, click **Add Money** and hold your hand still. The pointer runs the game's money slider by itself and stops, with a buzz, on the smallest amount the trader accepts (the first mark on the balance bar). That takes a second or two. Click again to take the amount. A long buzz instead means the slider does not go that far: you do not have the money for this trade. To set the amount yourself, move your hand well away once it has stopped, and the slider follows your hand again. The helper only moves the pointer on the game's own slider, so it cannot offer more than you have. It is off by default because it takes the slider out of your hand every time you click Add Money.

---

## Graphics presets

Pick one on the settings page, or step through them in the headset with **left grip (squeezed fully) + View**. The choice is remembered. The mod **ships on Medium**.

All four use the engine's TSR anti-aliasing with its flicker rejection turned up, and switch off motion blur, depth of field, lens flares and colour fringing. They sit on top of the game's own graphics options, which stay as you set them.

| Preset | What it changes | Frame rate, outdoors at the lake | Frames that missed 90 Hz |
|---|---|---|---|
| 1 High | Full internal resolution | 60 to 61 fps | 48% |
| **2 Medium** (default) | 85% internal resolution, sharpened back up. Hard to tell from High in the headset | 53 to 75 fps, average 63 | 44% |
| 3 Low | Medium without soft far shadows, screen-space reflections and ambient occlusion; smaller sun shadows | 69 to 80 fps, average 75 | 20% |
| 4 Performance | Low at 70% internal resolution, with simpler fog and bloom | 84 to 90 fps, average 89 | 1% |

Switching presets while standing in one spot gave: High to Medium +10 to 13 fps, Medium to Low +7 to 10 fps, and Low to Performance reached the 90 fps cap. Indoors, Medium ran at 86 to 90 fps; on the game's test map, 77 to 83.

How these were measured, so you can judge them: one PC (RTX 5080, Ryzen 7 9800X3D, Windows 11), a Steam Frame at 90 Hz streamed through SteamVR, SteamVR's per-application resolution at 83%, the game's own options at Global Illumination 1 and Reflections 1 (medium), Shading, Landscape and Anti-Aliasing 3 (highest). The lake is one of the heaviest outdoor areas. They are one session's numbers from the mod's own log, not a benchmark.

When the frame rate is below your headset's refresh rate, the pointer dot and close objects show a faint double image as you move. That is the missed frames, not a fault in the preset. Go down a preset if it bothers you.

---

## Known issues

- **Binoculars do not work in VR.** Raise them to look and they disappear.
- **The photo camera has no viewfinder.** Photos themselves work and are taken from where your hand holds the camera. Holding aim hides it, like the binoculars.
- **The trade screen's money slider takes a steady hand** with a VR pointer. There is an optional helper for it; see [Optional extras](#optional-extras).
- **A sight or scope can trail the gun slightly while you move.** In the game the optic is a separate part from the gun.
- **UEVR's own menu is always operated with the right controller**, also in left-handed mode. It is UEVR's pointer, not the mod's.
- **Two short hitches in the main menu** in the first seconds after injecting.
- **Objects pop in at a distance.** That is the game's level-of-detail system, more visible in VR.
- **The game's hint texts show keyboard keys.**
- **A crash code when you quit.** Windows may record that the game ended with code `0xC0000005` (-1073741819). It happens after the game has finished closing; saves are not affected.
- **Steam Frame controllers only.**

---

## Troubleshooting

**No button does anything.** Click once on the game's window on the desktop. Check that the game was started with `-dx11` and that UEVR's runtime is OpenVR.

**The buttons do the wrong things** (the face buttons are mixed up, the bumpers do nothing). SteamVR is not using the mod's controller layout. In SteamVR open Settings → Controllers → Manage Controller Bindings, pick Project Silverfish, and choose the default binding; it is called *Project Silverfish VR - Steam Frame (by Blind)*. Then restart the game. If it is not offered, look at the first lines of UEVR's `log.txt` for a line starting `[sf_start]`; it says what happened to the layout file.

**The settings page is not in UEVR's menu.** The script did not load. Your UEVR build is probably too old; use the nightly.

**The picture is a flat screen in front of you.** UEVR is not injected, or it was injected with OpenXR.

**The floor is too high or too low.** Stand up straight and press *Recentre and reset my height now* under Walking and turning.

**Guns point too high or too low.** Settings page → Gun in the hand → Unlock → Gun angle in the hand.

**Low frame rate.** Go down a preset (left grip, squeezed fully, + View), or lower SteamVR's render resolution for the game.

**I want everything back as it came.** Delete `data\sf_settings.txt` for the mod's settings. For UEVR's own settings, import the zip again.

**After updating UEVR, controls are odd.** The mod keeps its own `actions.json` (read-only) so that UEVR does not overwrite the Steam Frame layout. To rebuild it from a new UEVR: untick Read-only on `actions.json` and delete it, move `plugins\sf_start.dll` out of the folder, start the game once with UEVR and quit, put `sf_start.dll` back. On the next start it adds the layout to UEVR's new file.

---

## Reporting a bug

Open an issue on this repository, or post in the mod's thread on the Flat2VR Discord. Play-test it, break it, and tell me what broke.

Please include:

1. The **build number** from the top of the settings page (for this release: 1.0, build 6.6.52), and your UEVR build.
2. Your headset, GPU and CPU, and which **graphics preset** you were on.
3. What happened, and roughly when in the session (minutes after starting).
4. The two log files from `%APPDATA%\UnrealVRMod\SilverFish-Win64-Shipping\`: **`data\sf_main_log.txt`** (the mod's log) and **`log.txt`** (UEVR's log).

Both logs are written fresh at every start, so copy them **before** you start the game again.

If your report is about frame rate or about a graphics preset, the mod's log is what makes it useful: it holds a frame-time line about twice a minute with the preset in use, frames per second, how many frames missed the refresh rate, and where the time went (CPU threads, GPU). A report without it is a guess.

What is in those files, so you can decide what to share: the mod's log has timings, which controls and items were used, error messages, and the names of other programs that were using the graphics card at the time (for example a browser or a recorder). It has no window titles, no paths on your PC and no account names. UEVR's own log contains the full path of the profile folder, **which includes your Windows user name**. Blank that out before posting the file in public if you would rather not share it.

---

## What is in the package

Everything is inside `%APPDATA%\UnrealVRMod\SilverFish-Win64-Shipping\`.

| File | What it is |
|---|---|
| `scripts\sf_main.lua` | The mod: one Lua script run by UEVR. |
| `config.txt`, `cameras.txt` | UEVR's own settings for this game, as the mod needs them. |
| `user_script.txt` | A dozen console settings UEVR applies at start (motion blur off and the like). |
| `bindings_frame_controller.json` | The SteamVR controller layout for the Steam Frame. |
| `plugins\joytokey.dll`, `joytokey.txt` | Turns controller buttons into the game's keys and mouse buttons. A modified build of Markmon's uevr-joytokey; see Credits. |
| `plugins\sf_keys.dll` | Presses keys with real scan codes. The game ignores a Shift without one. |
| `plugins\a_sf_hand.dll` | Swaps the two triggers for a left-handed player. Does nothing until the script asks. |
| `plugins\sf_start.dll` | Runs once at start, before UEVR reads its files. It makes sure `actions.json` lists the Steam Frame layout and is read-only, and puts seven UEVR start settings back (below). |
| `plugins\sf_kbd.dll` | Shows SteamVR's keyboard for terminals and text boxes, and does the fade to black. |
| `plugins\sf_inv.dll`, `sf_mat.dll`, `sf_txt.dll` | Read-only helpers. UEVR's Lua cannot read some kinds of game data (lists of structs, text values); these read them for the script. |
| `plugins\sf_perf.dll` | Measures frame times, thread load and GPU use for the log. |

Written while you play: `data\sf_settings.txt` (your settings), `data\sf_main_log.txt` (the log), `actions.json` (made by `sf_start.dll` on the first start).

**None of this contacts the internet.** No plugin opens a network connection, and nothing is sent anywhere. The source of every plugin is in the `source` folder of this repository.

**UEVR settings the mod keeps hold of.** `sf_start.dll` sets these seven in `config.txt` before every start, because the mod does not work without them: aim method on (the script switches to its own aiming a few seconds in), 2D screen mode off, D-pad shifting off, ghosting fix off, UEVR menu on a *long* press of both sticks, controller inactivity timer 100 s, AHUD compatibility on. While you play, the script also drives UEVR's menu distance and size (from its own Menus sliders), room-scale movement, and the aim method. Everything else in UEVR's menu is yours to change.

---

## Updating and uninstalling

**Updating:** import the new zip the same way. Your settings are kept; the zip has no `data` folder.

**Uninstalling:** delete `%APPDATA%\UnrealVRMod\SilverFish-Win64-Shipping`, and remove `-dx11` from the game's launch options if you like. Nothing was installed anywhere else.

---

## Credits

- **praydog** for [UEVR](https://github.com/praydog/UEVR), which does the hard part: putting an Unreal Engine game into a headset at all.
- **Markmon (mark-mon)** for [uevr-joytokey](https://github.com/mark-mon/uevr-joytokey). `plugins\joytokey.dll` is a modified build of it; what was changed is in `source\joytokey-fork`.
- **jbusfield** for [uevrlib](https://github.com/jbusfield/uevrlib): two techniques in the script (showing single widgets on the 2D screen, and telling when a level has changed) are modelled on it. No code was copied.
- **Siris Pendrake** for Project Silverfish.
- The **Flat2VR** community.

Designed, directed and play-tested in the headset by Blind. The code was written with Claude, Anthropic's AI model.

Full notices for the third-party code are in [CREDITS.md](CREDITS.md).

## Licence

The mod's own files are under the MIT licence; see [LICENSE](LICENSE). `joytokey.dll` and its source are the exception: see CREDITS.md.

This is a fan-made mod. It is not affiliated with or endorsed by the developer of Project Silverfish, by praydog, or by Valve.
