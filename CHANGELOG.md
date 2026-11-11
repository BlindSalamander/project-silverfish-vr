# Changelog

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
