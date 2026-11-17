# Changelog

## 1.0.2 (build 6.6.64) - 16 November 2026

**Fixed**

- **Crashes during level loads.** During a load the screen is black, but the graphics card kept drawing the world behind it at full load while the game loaded; on the test PC the graphics driver reset (a GPU crash, Windows' "display driver stopped responding") in the middle of a load. While the screen is black for one of the game's loads the mod now switches the world's drawing off (the game's own `SetEnableWorldRendering`), and on again a quarter of a second after the game's black screens are gone, with the view held black a little longer so the first frames are not shown. Safeties: the world comes back on whatever happens after 45 s, when the fade stops being updated, or after repeated errors. Measured: about 100 W and 20 % graphics load during the black part of a load instead of about 285 W and 95 %. No load crash in about seven hours of testing since.
- **A small stutter about every 40 seconds** (about 34 ms). The performance plugin took a snapshot of every thread on the PC on the game's own thread each time the mod asked it for numbers. The snapshot is now taken on the plugin's background thread.
- **The keyboard in terminals.** It now comes up every time a terminal opens: after a level change the mod could look for the terminal with a class object that no longer existed, and it now also uses the moment the game puts the terminal on screen. Done puts the keyboard away and it stays away (a left stick click brings it back); before, it could not be put away. The first keyboard of each terminal sends one Backspace a moment after it appears, which clears a stray character that sat at the start of the line and broke the first command.

**New**

- A double click of the left stick brings up the keyboard in any menu (one click is shift-click, so it cannot be one).
- `data\sf_report.txt`, rewritten every minute and on a button on the Help page: build, settings that differ from the defaults, stutters, marked moments and the end of the log, with personal paths blanked.
- Mark a moment: both hands on top of your head for about a second gives a double buzz and a line with the time in the log.
- The log keeps going in long sessions (it stopped after about 100 minutes), has the computer's time once a minute, and its stutter lines say how much of the frame the mod itself used and keep play apart from level-load pauses.
- The frame-time lines include SteamVR's own graphics-card time per frame (from `sf_perf.dll`, also written once a second to `data\sf_gpu_log.txt`).

**Coming from 1.0 or 1.0.1:** import the new zip the same way. Your settings are kept. Changed: `scripts\sf_main.lua`, `plugins\sf_kbd.dll`, `plugins\sf_perf.dll` and the texts.

## 1.0.1 (build 6.6.55) - 10 November 2026

**Fixed**

- **Scopes while you move.** On every scoped gun, the dark inside of the scope and the picture in it slid out of the tube whenever you walked, strafed or sprinted with the scope up, and sat right again when you stood still. The game works out where a scope's lens is once per frame, before the mod has put the gun in your hand, and the inside of the scope was drawn at that earlier spot: up to 3 cm beside a lens 2.6 cm in radius. The mod now sets the lens position again from the gun as it is drawn.

**Coming from 1.0:** import the new zip the same way. Your settings are kept. Only `scripts\sf_main.lua` and the texts changed.

## 1.0 (build 6.6.52) - 10 November 2026

The first public release. The mod was developed privately up to build 6.6.51; this is what it does on the day it went public.

**Hands and guns**

- Both controllers tracked as the player's hands. Guns, tools and melee weapons are held in the gun hand; shots follow the barrel.
- Every gun is locked to the hand, with the game's own recoil movement taken out and replaced by a buzz in the controller.
- Two-handed hold for long guns, with the other hand steering.
- Red dot sights redrawn from the gun as it is held, so the dot is where the shot lands.
- Three ticks in the gun hand when the trigger is pulled while the game has the gun blocked.
- A lowered weapon is shown tipped down in the hand.
- Left-handed mode (experimental): gun, pointers, triggers, bumpers and grips change hands.

**Moving**

- Walking through the game's own movement input, steered by the head; sprint, crouch, jump and a crouch-jump on one combination.
- Smooth or snap turning.
- Room-scale: the game's body follows the headset.
- Height reset at every level start.

**Seeing**

- The game's HUD on a panel inside the helmet; a pointer dot where the gun hand points.
- Menus, inventory, traders and terminals as world-locked panels with a hand pointer; right stick scrolls; shift-click on the left grip.
- SteamVR's keyboard for terminals and text boxes.
- Fade to black through level loads.
- Four graphics presets (High, Medium, Low, Performance), switchable in the headset.

**Controls**

- A complete layout for the Steam Frame controllers, registered with SteamVR by the profile itself.

**The settings page**

- Its own page in UEVR's menu, in plain words, sized to the window it is shown in.
- The controls listed one per line, for whichever hand is in use.
- The gun adjusters are locked until asked for.
- Optional extras, off by default: on the trade screen, Add Money can set the amount for you (the pointer runs the game's money slider to the least the trader takes; a click confirms it).

**Not in 1.0**

- Binoculars, and the photo camera's viewfinder.
- Controllers other than the Steam Frame's.
