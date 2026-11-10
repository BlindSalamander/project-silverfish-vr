-- sf_main.lua - Project Silverfish VR: a UEVR script that makes Project Silverfish play as a motion-controlled VR game.
-- Published by Blind. What changed in which version: CHANGELOG.md of the release (the development notes - every
-- version, every finding, every dead end - are not part of this file).
-- Log: data\sf_main_log.txt   Settings: data\sf_settings.txt
-- Panel: UEVR menu > "Silverfish VR settings" (its own page; UEVR's "Script UI" page points to it)
--
-- Setup it is built for: Steam Frame through SteamVR (OpenVR), UEVR nightly, Native Stereo, game started with -dx11.
-- Plugins beside it (plugins\): joytokey.dll (buttons -> keys), sf_keys.dll (real Shift), sf_inv.dll (weapon slots),
-- sf_kbd.dll (SteamVR keyboard, fade to black), sf_perf.dll (frame / GPU numbers), sf_mat.dll (material values),
-- sf_txt.dll (the game's texts), a_sf_hand.dll (trigger swap for left-handed play), sf_start.dll (start-up files).
--
-- WHAT IT DOES
--   Hands    Two points of our own on the player follow the controllers, placed in the per-eye view callback from that
--            eye's pose (place_hands). UEVR's own "attach to controller" is not used and is kept off what we hold.
--   Guns     The held item's skeleton (Wep_Skeli) is re-parented from the game's HoldArrow to the right-hand point
--            (take_gun). The game keeps moving it (recoil, sway, draw): it is put back after the game's update
--            (enforce_gun) and in both eye passes before drawing (V62.gun_hold). Lowered weapon = tipped down in the hand.
--   Aim      The game's control rotation = the eye ray through the point the hand / barrel points at, so shots land
--            where the barrel points; while sprinting it follows the head (the game's forward key moves along its look).
--   Sights   A sight's dot is a post-process material carrying the sight's Right / Down axes, written by the game from
--            the recoil-kicked pose. They are rewritten every frame from the gun as drawn, aimed at where the barrel
--            line hits (V62.sight_fix; values read through sf_mat.dll).
--   Body     View from our own body yaw (stick turning) + the headset; walking through the game's own Move input,
--            relative to the head; height reset at level start (standing height if you are bent down at that moment).
--   HUD      The game's HUD widget is taken onto a panel in the world (helmet HUD in front of the eyes; the aiming
--            ring and pointer dot on their own panel where the hand points). Hidden while a level loads.
--   Menus    Every menu is a world-locked panel in front of you; the right controller is the mouse. RetainerBox effect
--            layers (empty through UEVR) are switched off so the UI draws.
--   Levels   Nothing touches the world while a level loads (lvl.*); view fades to black for the transition.
--   Controls Steam Frame layout handled here (bumpers, View, D-pad, grips): see the panel's "Controls" section.
--   Parked   Binoculars (three approaches, none good - binocular_mode 0).
--
-- RULES LEARNED THE HARD WAY
--   * Never hook a game function this script itself calls: the call fails inside UEVR ("resource deadlock").
--   * A hook only sees calls made through ProcessEvent; a hook's "locals" are garbage for calls made from Blueprint.
--   * UEVR's Lua cannot read arrays of structs or text values -> the sf_mat / sf_inv / sf_txt plugins.
--   * Never rebuild a part's world transform from a guessed parent: write the Relative* value.
--   * No engine calls on objects during a level load or while a menu is opening (v4/v5 crashes): obj_ok / alive / vguard.
--   * A function that reads 'body', 'cur', 'grip' ... must be defined after that local; V62.* functions avoid the
--     problem (looked up when called) and the 200-locals limit of the main chunk.
--   * In the simulator a log line is only written on the next flush: tick a few hundred frames before reading it.
--
-- UEVR Lua calling rules (checked against UEVR's ScriptContext.cpp):
--   uevr.api:method(...)            vr.<fn>(...) for all VR functions EXCEPT vr:get_mod_value(name)
--   UEVR_UObjectHook.<fn>(...)      object:Method(...) for game objects      fs. / imgui. with a dot

local SF_VERSION = "6.6.52"          -- the build number: say it in a bug report
local SF_RELEASE = "1.0"             -- the published version

local function sf_main_body()

local api = uevr.api
local vr = uevr.params.vr

---------------------------------------------------------------------------
-- log
---------------------------------------------------------------------------
local T = 0
local loglines, logdirty, lastmsg, repeats = {}, false, nil, 0
local function LOG(s)
    s = tostring(s)
    if s == lastmsg then repeats = repeats + 1; return end
    if repeats > 0 then loglines[#loglines + 1] = string.format("[%7.1f]   (previous line repeated %d more times)", T, repeats) end
    lastmsg, repeats = s, 0
    if #loglines > 4000 then return end
    loglines[#loglines + 1] = string.format("[%7.1f] %s", T, s)
    logdirty = true
end
local function flushlog()
    if logdirty then logdirty = false; pcall(fs.write, "sf_main_log.txt", table.concat(loglines, "\n")) end
end
-- v4.17 CRASH TRACER: for 8 s around every menu open/close, the name of each engine call is written to
-- data\sf_lastcall.txt just before it runs (and "idle" after each tick). After a crash that file names the call.
local trace_until = 0
-- (v6: TRACE_ON constant inlined as false)
local function TRACE(tag)
    if false and T < trace_until then pcall(fs.write, "sf_lastcall.txt", string.format("%.2f %s", T, tag)) end
end


---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------
local S = {
    ui_invert_alpha = false,     -- always OFF (black rectangle); no longer in the panel
    menu_flat_screen = false,    -- v5.1: menus stay in VR (UEVR AHUD overlay). No flat-screen flip = no render-target
                                 -- reallocation = the crash source is GONE, and no jarring "flat menu takes over".
    menu_follow_head = false,    -- false = menu appears in front of you when opened and then stays put
    menu_distance = 0.85,        -- v4.10: closer + bigger so menu text is readable (was ~1.0 m / 0.81)
    menu_size = 0.87,            -- height in metres (width = height x 16/9) -> about 54 x 84 degrees at 0.85 m
    menu_height = -0.30,         -- metres: flat menu screen lowered a bit (was "a TV mounted too high")
    vr_render_tweaks = true,     -- v5.0: turn off flat-screen post effects that hurt in VR (see RENDER_TWEAKS)
    pointer_enabled = true,
    pointer_pitch = -35.0,       -- v6.1: menu pointer 35 deg down (the Frame's "forward" points above the hand)
    trade_money = false,         -- v6.6.51: trade screen: after Add Money the slider runs to the amount by itself (V62.money_cursor)
                                 -- v6.6.52: an optional extra, off unless ticked (it works in the game, but it takes the
                                 -- slider out of your hand every time Add Money is clicked)
    trade_money_ideal = false,   -- v6.6.51: ... to the trader's ideal mark (the second one) instead of the least he takes
    gun_enabled = true,
    flashlight_left_hand = false,  -- v6.6.8: the game's flashlight stays on your head (it lit from the hand before)
    light_x = 5.0, light_y = 0.0, light_z = 0.0,
    two_handed = true,           -- v4.13: left hand on a long gun's fore-grip steers the barrel
    grip_angle = -55.0,          -- Frame controller's tracked "forward" points well above where a hand points a gun (v6.6.6: -55, the tester)
    light_angle = -35.0,
    auto_recenter = true,
    fix_ui_effects = true,
    wrist_hud = true,            -- v4.9: game HUD (its centre = the "can interact" ring) floats where you look
    hud_fov = 50.0,              -- degrees the whole HUD spans across your view
    vr_body = true,              -- aim from the gun (UEVR aim = Game), our own turning + HMD-relative analog movement
    turn_speed = 140.0,          -- degrees per second at full stick
    snap_turn = false, snap_angle = 30.0,
    move_deadzone = 0.15,
    -- v6.0
    frame_controls = true,       -- bumpers / View / D-pad left+right / grip gestures handled here (Steam Frame layout)
    chest_flashlight = false,    -- v6.1: LEFT hand on your chest + grip = flashlight on/off (v6.6.8: off - accidental; D-pad up = V)
    game_walk = true,            -- v6.1: walk through the game's own Move input (sprint works); off = direct walking
    zone_haptics = true,         -- small buzz when a hand enters a gesture zone
    level_settle = 0.3,          -- seconds after a loading screen before gun/HUD/hands go on (v6.6.6: 1.5 -> 0.3, with walking)
    -- v6.2
    melee_swing = false,         -- swing the right hand to melee (the tester: "not ideal at all") - right grip = quick melee
    quick_melee = false,         -- right grip, full click = quick melee (IA_QuickMelee) (v6.3: off - trigger melee is enough)
    weapons_only_dpad = true,    -- D-pad left/right cycle weapon slots 1-4 only, never utility items
    twohand_hold = true,         -- two-handed only while the left grip is held
    show_lowered = true,         -- the game's "weapon lowered" state is shown as the gun pointing down in your hand
    sprint_inject = false,       -- left stick click -> the injected Sprint action (v6.5: off - the real Shift key is used)
    big_cursor = false,          -- menu cursor copy drawn bigger (v6.6: off - it caused a second cursor + stutter)
    -- v6.3
    gfx_level = 2,               -- v6.6.47: 1 High | 2 Medium | 3 Low | 4 Performance (left grip + View = the next one)
    hold_jump_crouch = false,    -- hold Y: crouch while in the air (v6.4: off - right grip + Y instead)
    flashlight_modes = true,     -- left trigger with the off-hand flashlight: torch hold <-> raised hold
    fl_alt_angle = -55.0,        -- the RAISED hold: degrees the beam is turned from where the hand points (negative = down)
    menu_stick_scroll = true,    -- right stick scrolls menu lists
    right_grip_crouch = false,   -- v6.4: right grip (full squeeze) = crouch, held (off: the tester keeps crouch on the stick)
    -- v6.5
    sprint_key = true,           -- left stick click = the real Left Shift key (sf_keys plugin)
    sprint_w = true,             -- while the stick click is down and the stick is forward, also hold the game's W action
    menu_shift = true,           -- in menus: left stick click or left grip held = Shift (shift-click)
    crouch_jump = true,          -- right grip held + Y = jump, then crouch a split second later until you land
    cj_delay = 0.12,             -- seconds between the jump and the crouch
    sprint_toggle = true,        -- v6.6.8: click the left stick = sprint until you stop moving (false = hold the click)
    exact_cycle = true,          -- v6.6.10: D-pad cycles exactly the filled weapon slots 1-4 (read by sf_inv.dll)
    -- v6.6.12
    lower_direct = true,         -- right bumper: tap = pick up (G on release), hold = lower / raise (game state set directly)
    lower_hold = 0.45,           -- seconds the right bumper is held to lower / raise
    sprint_stop_delay = 0.2,     -- seconds without pushing forward before the sprint ends
    sprint_head = true,          -- v6.6.40: while the sprint holds the game's forward key, the game's look follows your head
    sprint_cancel = true,        -- still sprinting 0.15 s after Shift is let go -> the game's CancelSprint
    carry_far_aim = true,        -- carrying: aim parallel to the hand (throws go where you point)
    hide_loading_box = true,     -- loading screen: make its black box see-through
    -- v6.6.13
    kbd_auto = true,             -- SteamVR keyboard for terminals / focused text boxes (sf_kbd.dll)
    kbd_place = true,            -- keyboard placed in front of you at chest height (false = SteamVR's own spot)
    kbd_fwd = 61,                -- v6.6.20: keyboard distance in front of you (cm) - needs sf_kbd.dll v3 (v6.6.48: 61, was 45)
    kbd_down = 75,               -- v6.6.20: below your eyes (cm) - under the terminal screen (v6.6.48: 75, was 55)
    kbd_tilt = 50,               -- v6.6.20: tilted up toward you (deg)
    -- v6.6.14
    fire_aim_pointer = true,     -- firing: the game's eye ray goes through the barrel's aiming point (false = old switch)
    throw_power = true,          -- a harder yank throws a carried object harder
    throw_speed_k = 130,         -- v6.6.42: throw strength per m/s of hand speed (cm/s) - about the hand's own speed
    throw_speed_min = 450,       -- v6.6.42: the gentlest throw (cm/s): a press with a still hand lobs it ~2 m
    throw_speed_max = 1500,      -- v6.6.42: the hardest (cm/s); the game's own is 1000
    gun_autofit = true,          -- guns whose barrel sits below / beside your hand are moved into the hand (once per gun)
    binoculars_2d = true,        -- raised binoculars = the game's own binocular view, flat in front of your eyes
    transition_fade = true,      -- level transitions: SteamVR fades to black instead of the loading box
    -- v6.6.15
    binocular_mode = 0,          -- 0 = off: binoculars as the game has them (parked) | 1 = the game's scope on them (v6.6.25) | 2 = the game's flat view (v6.6.14)
    bino_scope_class = "",       -- v6.6.25: the game's scope class borrowed for the binoculars (learned from a scoped gun)
    bino_lens = true,            -- v6.6.25: show the borrowed scope's lens on the binoculars
    bino_plane = true,           -- v6.6.25: also show its picture on a flat panel at the eye end
    bino_scope_x = -17.0,        -- v6.6.25/26: where the scope's LENS ends up along the binoculars (cm; minus = toward your eye)
    bino_scope_z = 6.0,          -- v6.6.25/26: lens height (cm)
    bino_pp_drive = true,        -- v6.6.26: switch the scope's zoom effect on/off ourselves (the scope's script may not, on binoculars)
    head_light = true,           -- v6.6.26: a light the game hangs on its camera follows your head instead
    hud_head = true,             -- v6.6.26: HUD with information (helmet) in front of your eyes, following your head
    hud_head_dist = 1.6,         -- v6.6.26: that HUD's distance (m)
    hud_head_down = -8,          -- v6.6.26: that HUD's tilt below eye level (deg)
    hud_head_fov = 70,           -- v6.6.28: that HUD's size (deg of your view it spans) (v6.6.30: the tester's 70)
    hud_ring_mirror = false,     -- v6.6.28: flip the ring's left/right on the head HUD (only if the ring could not be separated)
    hud_ring_separate = true,    -- v6.6.29: the aiming ring on its own panel where your hand points
    sight_fix = true,            -- v6.6.38: the sight's crosshair axes (Right/Down) rewritten from the gun as drawn, every frame
    sight_impact = true,         -- v6.6.39: the dot points where the barrel line hits (the shot lands there), not parallel above it
    sight_trim_deg = 0.0,        -- v6.6.39: manual dot trim, degrees (+ = dot higher -> shots land lower; - = dot lower)
    hud_ads_crosshair = false,   -- v6.6.32: the game's ADS crosshair shown only when the game shows it (LT) - used when pointer_dot is off
    pointer_dot = true,          -- v6.6.41: the small dot where your hand points, always on (the tester: "you need to know where you're pointing")
    pointer_dot_size = 1.9,      -- v6.6.41: its size (1 = the game's) (v6.6.48: 1.9, was 1.5)
    uevr_attach_guard = true,    -- v6.6.43: a UEVR "attach to controller" on the part the mod holds is taken off (the Rusty Old Pistol)
    gun_hold_both = true,        -- v6.6.43: the gun is put back in the hand in BOTH eye passes (nothing may move it between them)
    height_stand = true,         -- v6.6.43: a height reset while you are bent down for a moment uses your standing height
    hud_hide_loading = true,     -- v6.6.43: the game's HUD stays hidden while a level loads
    hint_log = false,            -- v6.6.43: every hint / prompt text the game shows goes to the log (through sf_txt.dll) (v6.6.48: off by default)
    dev_tools = false,           -- v6.6.48: true (written into sf_settings.txt by hand) = the panel also shows every development switch
    left_handed = false,         -- v6.6.49: the gun, pointer and menu pointer in the LEFT hand (experimental; needs plugins\a_sf_hand.dll for the triggers)
    twohand_hand_pointer = true, -- v6.6.45: two-handed: dot + pick-up follow the right hand itself (shots still follow the barrel)
    pointer_solid = true,        -- v6.6.45: the dot / ring panel is drawn solid (masked) - no ghost trail when it moves
    fl_start_raised = false,     -- v6.6.47: the off-hand flashlight starts in the RAISED hold each time it is taken out (false = torch: beam where the hand points)
    blocked_buzz = true,         -- v6.6.45-47: three ticks in the gun hand when the trigger is pulled while the game blocks the gun (near a wall)
    roomscale = true,            -- v6.6.45: the game's body follows your head when you step / lean (UEVR's room-scale movement) (v6.6.48: on)
    hud_ring_r = 1.0,            -- the aiming ring's tint (linear colour; its image is white): orange
    hud_ring_g = 0.18,
    hud_ring_b = 0.0,
    bino_scope_yaw = 0.0,        -- v6.6.25: lens turn (deg; 0 = looks where the binoculars point)
    bino_scope_scale = 3.0,      -- v6.6.25: lens enlargement
    bino_scope_body = false,     -- v6.6.25: also show the scope's body (default: lens only)
    bino_plane_x = -17.5,        -- v6.6.25: flat picture position along the binoculars (cm)
    bino_plane_z = 6.0,          -- v6.6.25: flat picture height (cm)
    bino_zoom = 0.0,             -- v6.6.25: 0 = the game's own binocular magnification, else this many x
    bino_hide_overlay = true,    -- v6.6.25: hide the game's flat binocular screen (the black box) in mode 1
    bino_orient = 0,             -- picture turn 0-3 (x90 deg), +4 = mirrored (panel button cycles it)
    bino_size = 11.0,            -- picture size on the binoculars, cm
    audio_head = true,           -- v6.6.18: the game hears from your head (sound directions follow the headset, not the gun)
    fade_hands_wait = 0.5,       -- v6.6.18: after a level load, stay black this long after your hands are on (s)
    camera_away_fade = true,     -- sleeping: the game moves the camera to the bed - fade to black meanwhile (v6.6.16: sleep only)
    vr_recoil = true,            -- each shot kicks the gun in your hand + buzz (aim / view not moved)
    recoil_scale = 0.6,          -- share of the gun's own recoil values used for the kick
    recoil_rise = 0.2,           -- v6.6.18: share of the kick that tips the muzzle up (the rest lifts the gun: sight stays on target)
    recoil_visual = false,       -- v6.6.19: our own visual kick off - the gun stays locked to your hand (buzz only)
    gun_hold_still = true,       -- v6.6.19: put the gun back right before each frame is drawn (the game's recoil moves it)
    flat_inventory = false,      -- v6.6.3 test: false = inventory/shop as VR panels like the other menus; true = flat screen
}
local GUNS = {}
local FILE = "sf_settings.txt"

local function save_settings()
    local out = {}
    for k, v in pairs(S) do out[#out + 1] = k .. "=" .. tostring(v) end
    for cls, g in pairs(GUNS) do
        out[#out + 1] = string.format("gun3.%s=%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%s", cls, g.x, g.y, g.z, g.pitch, g.yaw, g.roll, tostring(g.fitted))
    end
    table.sort(out)
    pcall(fs.write, FILE, table.concat(out, "\n"))
end

local function load_settings()
    local ok, txt = pcall(fs.read, FILE)
    if not ok or type(txt) ~= "string" then return end
    for k, v in txt:gmatch("([%w_%.]+)=([^\r\n]+)") do
        local cls = k:match("^gun3%.(.+)$")   -- v4.1: hands tracked by this script now (older gun2. fits were made with frozen hands)
        if cls then
            local n = {}
            for part in v:gmatch("[^,]+") do n[#n + 1] = part end
            if #n >= 6 then
                GUNS[cls] = { x = tonumber(n[1]) or 0, y = tonumber(n[2]) or 0, z = tonumber(n[3]) or 0,
                    pitch = tonumber(n[4]) or 0, yaw = tonumber(n[5]) or 0, roll = tonumber(n[6]) or 0, fitted = (n[7] == "true") }
            end
        elseif k == "ui_invert_alpha" or k == "menu_flat_screen" or k == "menu_follow_head" or k == "wrist_hud" or k == "vr_body"
            or k == "fix_ui_effects" or k == "gun_enabled" or k == "flashlight_left_hand" or k == "pointer_enabled"
            or k == "gun_tilt" or k == "light_tilt" then
            -- fixed in 3.3 (invert alpha off, flat menus on, static menus by default)
        elseif S[k] ~= nil then
            if type(S[k]) == "boolean" then S[k] = (v == "true")
            elseif type(S[k]) == "number" then S[k] = tonumber(v) or S[k]
            elseif type(S[k]) == "string" then S[k] = v end                       -- v6.6.25
        end
    end
end
load_settings()

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function safe(f, ...) local ok, r = pcall(f, ...); if ok then return r end; return nil end
local function num(s, d) return tonumber(s) or d end
local function X(v) return v.x or v.X or 0 end
local function Y(v) return v.y or v.Y or 0 end
local function Z(v) return v.z or v.Z or 0 end
local function W(v) return v.w or v.W or 1 end
local function addr(o) if o == nil then return nil end; return safe(function() return o:get_address() end) end
local function same(a, b) if a == nil and b == nil then return true end; local x, y = addr(a), addr(b); return x ~= nil and x == y end
local KSYS = nil   -- KismetSystemLibrary default object (set in lookups)
-- v4.14: "alive" = still in the object table AND not being destroyed (both crashes were engine calls on objects the
-- game was tearing down while a menu opened)
local function alive(o)
    if o == nil or safe(function() return UEVR_UObjectHook.exists(o) end) ~= true then return false end
    if KSYS ~= nil then
        if T < trace_until then TRACE("IsValid " .. (safe(function() return o:get_full_name() end) or "?")) end
        return safe(function() return KSYS:IsValid(o) end) == true
    end
    return true
end
local function attach_parent(c)   -- read the property; no engine call
    if c == nil then return nil end
    local p = safe(function() return c.AttachParent end)
    if p == nil then p = safe(function() return c:GetAttachParent() end) end
    return p
end
local function fullname(o) if o == nil then return "nil" end; return safe(function() return o:get_full_name() end) or "?" end
local function shortclass(o) return safe(function() return o:get_class():get_fname():to_string() end) or "unknown" end
local function getmod(name) return tostring(safe(function() return vr:get_mod_value(name) end) or "") end
local function setmod(name, value) pcall(vr.set_mod_value, name, tostring(value)) end

local errors, paused = {}, {}
local last_feature = "startup"    -- v4.21 hitch detector: which feature was running when a stall happened
local function guarded(tag, f, ...)
    if paused[tag] then return end
    last_feature = tag
    local ok, err = pcall(f, ...)
    if not ok then
        errors[tag] = (errors[tag] or 0) + 1
        LOG("ERROR in " .. tag .. ": " .. tostring(err))
        if errors[tag] >= 20 then paused[tag] = true; LOG("feature '" .. tag .. "' paused after 20 errors (rest keeps running)") end
    end
end

-- v5.3 (earlier instance): flag big one-frame jumps in the game's control-rotation yaw. The camera spring-arm follows
-- this, so a jump shows up as a felt "yank". Pure logging - confirms or kills the aim-flip theory without guessing.
local ctrl_jump = { last = nil, n = 0 }
local function report_ctrl_jump(yaw, src)
    if type(yaw) ~= "number" then return end
    if ctrl_jump.last ~= nil then
        local d = yaw - ctrl_jump.last
        while d > 180 do d = d - 360 end
        while d < -180 do d = d + 360 end
        if math.abs(d) > 20 then ctrl_jump.all = (ctrl_jump.all or 0) + 1 end
        if math.abs(d) > 20 and ctrl_jump.n < 60 and T > (ctrl_jump.nt or 0) then   -- v6.6.14: at most one per 2 s
            ctrl_jump.n, ctrl_jump.nt = ctrl_jump.n + 1, T + 2.0
            LOG(string.format("CTRL-JUMP: control yaw jumped %.0f deg in one frame (aim=%s) - possible camera yank", d, tostring(src)))
        end
    end
    ctrl_jump.last = yaw
end

-- game lookups (done on the first game tick, not while loading)
local G = { ready = false }
local function lookups()
    local function cdo(path) local c = api:find_uobject(path); if c == nil then return nil end; return c:get_class_default_object() end
    G.KML = G.KML or cdo("Class /Script/Engine.KismetMathLibrary")
    G.KSL = G.KSL or cdo("Class /Script/Engine.KismetStringLibrary")
    G.GPS = G.GPS or cdo("Class /Script/Engine.GameplayStatics")
    G.Vec = G.Vec or api:find_uobject("ScriptStruct /Script/CoreUObject.Vector")
    G.Rot = G.Rot or api:find_uobject("ScriptStruct /Script/CoreUObject.Rotator")
    G.Hit = G.Hit or api:find_uobject("ScriptStruct /Script/Engine.HitResult")
    G.ActorClass = G.ActorClass or api:find_uobject("Class /Script/Engine.Actor")
    G.SceneClass = G.SceneClass or api:find_uobject("Class /Script/Engine.SceneComponent")
    G.Layout = G.Layout or api:find_uobject("WidgetLayoutLibrary /Script/UMG.Default__WidgetLayoutLibrary")
    G.Retainer = G.Retainer or api:find_uobject("Class /Script/UMG.RetainerBox")
    G.WidgetComp = G.WidgetComp or api:find_uobject("Class /Script/UMG.WidgetComponent")
    G.Vec2 = G.Vec2 or api:find_uobject("ScriptStruct /Script/CoreUObject.Vector2D")
    G.UserWidget = G.UserWidget or api:find_uobject("Class /Script/UMG.UserWidget")
    G.LinColor = G.LinColor or api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor")
    if KSYS == nil then local c = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"); KSYS = c and c:get_class_default_object() end
    G.KSys = G.KSys or KSYS
    if G.KSL and G.NONE == nil then G.NONE = G.KSL:Conv_StringToName("None") end
    G.ready = G.KML ~= nil and G.KSL ~= nil and G.GPS ~= nil and G.Vec ~= nil and G.Rot ~= nil and G.Hit ~= nil
        and G.ActorClass ~= nil and G.SceneClass ~= nil and G.NONE ~= nil
    LOG("game lookups ready=" .. tostring(G.ready))
end

local function mkvec(x, y, z) local v = StructObject.new(G.Vec); v.X, v.Y, v.Z = x, y, z; return v end
local function mkrot(p, yw, r) local v = StructObject.new(G.Rot); v.Pitch, v.Yaw, v.Roll = p, yw, r; return v end
local function set_rel(comp, x, y, z, p, yw, r)
    comp:K2_SetRelativeLocationAndRotation(mkvec(x, y, z), mkrot(p, yw, r), false, StructObject.new(G.Hit), false)
end

local function haptic(hand, dur, amp)
    if S.left_handed == true then hand = 1 - hand end           -- v6.6.49: hand 1 = the gun hand, 0 = the other one
    local src = (hand == 0) and safe(vr.get_left_joystick_source) or safe(vr.get_right_joystick_source)
    if src ~= nil then pcall(vr.trigger_haptic_vibration, 0.0, dur or 0.05, 120.0, amp or 0.5, src) end
end

---------------------------------------------------------------------------
-- controller drivers (v4.1): this script moves the components itself, every frame, from the controller poses.
-- UEVR's UObjectHook stopped moving them once UEVR's aim mode was set to Game, so we no longer depend on it.
-- Math: hand pose relative to the headset, placed relative to the eye views UEVR just computed -> exact, and
-- independent of UEVR's recentre / rotation offsets / aim mode.
---------------------------------------------------------------------------
local driven = {}     -- address -> { comp, hand, label, samples, lx, ly, lz }
local track = { calls = 0, applied = 0, eyes = {}, eyeoff = {}, last1 = -10, errs = 0, off = false, logged = false }
-- v4.9 shared with the view callbacks (declared up here so the callbacks can see them)
local ui_rescan = false
local quiet_until = 0   -- v4.16: no optional engine calls for a moment after a menu opens/closes (all 3 crashes were then)
local lvl                -- v6.0 level lifecycle state (filled in further down; read by the per-eye callback)
-- v4.13 two-handed grip: on = left hand holds the gun's fore-grip; m = muzzle direction in grip axes
local twohand = { on = false, m = nil, log = 0 }
-- v6.2: everything new lives in this one table (Lua allows only 200 locals in the main chunk)
local V62 = { fl_alt = true, low = 0, wrap = {}, watch = {}, spr = {}, gfx_q = {}, gfx_orig = {}, pulses = 0,
              wm = { model = "control", off = { control = 0, actor = 0 }, dev = { control = 0, actor = 0 }, n = 0,
                     es = 0, ec = 0, big = 0, steep = 0, steep_err = 0, rep_t = 0 } }
function V62.reg(name, f)                  -- v6.6.5: register a UEVR callback with its time added to SF_SCRIPT_T
    local clock = os and os.clock
    if clock == nil then return uevr.sdk.callbacks[name](f) end
    return uevr.sdk.callbacks[name](function(...)
        local c0 = clock()
        local r = f(...)
        SF_SCRIPT_T = (SF_SCRIPT_T or 0) + (clock() - c0)
        return r
    end)
end
local cur, fit = nil, nil                                   -- weapon in hand (set further down; declared here for the view callback)
local menu_mode = false                                     -- a menu is open (declared here: the view callback reads it too)
V62.ua = { on = false }                                     -- v6.6.43: UEVR's own attachment on the held part (see V62.uevr_attach_watch)
V62.sh = { buf = {}, n = 0, i = 0, t = 0, p = Vector3f.new(0, 0, 0), q = Quaternionf.new(0, 0, 0, 1) }   -- v6.6.43: headset heights
local offh = { actor = nil, grip = nil, root = nil, fixes = 0 }   -- off-hand item (same)
local view = { ok = false, yaw = 0, arm = nil, errs = 0, off = false, count = 0 }   -- render-rotation override
local hudp = { comp = nil, dist = 150, scale = 0, errs = 0, P = nil }                -- HUD panel (P = where the right hand points)
local tp_h, tq_h = Vector3f.new(0, 0, 0), Quaternionf.new(0, 0, 0, 1)
local tp_c, tq_c = Vector3f.new(0, 0, 0), Quaternionf.new(0, 0, 0, 1)
local hand_vec, hand_rot, hand_hit = nil, nil, nil

local function drive(comp, hand, label, lx, ly, lz)
    if comp == nil then return false end
    pcall(UEVR_UObjectHook.remove_motion_controller_state, comp)   -- never let two systems move it
    driven[addr(comp)] = { comp = comp, hand = hand, label = label, samples = 0, last = nil, lx = lx or 0, ly = ly or 0, lz = lz or 0,
                           cls = safe(function() return comp:get_class():get_fname():to_string() end) }
    LOG(label .. " now follows the " .. (hand == 0 and "LEFT" or "RIGHT") .. " controller")
    return true
end

local function undrive(comp, label)
    if comp == nil then return end
    pcall(UEVR_UObjectHook.remove_motion_controller_state, comp)
    driven[addr(comp) or 0] = nil
    LOG(label .. " released")
end

-- OpenVR quaternion rotate
local function qv(q, x, y, z)
    local qx, qy, qz, qw = X(q), Y(q), Z(q), W(q)
    local tx, ty, tz = 2 * (qy * z - qz * y), 2 * (qz * x - qx * z), 2 * (qx * y - qy * x)
    return x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx)
end
-- OpenVR (x right, y up, -z forward) -> Unreal (x forward, y right, z up)
local function ovr2ue(x, y, z) return -z, x, y end

local function rot_axes(p, y, r)   -- Unreal FRotationMatrix axes (forward, right, up)
    local sp, cp = math.sin(math.rad(p)), math.cos(math.rad(p))
    local sy, cy = math.sin(math.rad(y)), math.cos(math.rad(y))
    local sr, cr = math.sin(math.rad(r)), math.cos(math.rad(r))
    return { cp * cy, cp * sy, sp },
           { sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp },
           { -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp }
end
local function axes_rot(f, rt, u)  -- FMatrix::Rotator()
    local pitch = math.deg(math.atan(f[3], math.sqrt(f[1] * f[1] + f[2] * f[2])))
    local yaw = math.deg(math.atan(f[2], f[1]))
    local sy, cy = math.sin(math.rad(yaw)), math.cos(math.rad(yaw))
    local roll = math.deg(math.atan(u[1] * -sy + u[2] * cy, rt[1] * -sy + rt[2] * cy))
    return pitch, yaw, roll
end
-- v6.2: the gun's in-hand transform, tipped down about the hand when the game has the weapon LOWERED (hold R bumper)
function V62.lowered(g)
    local a = V62.low or 0
    if g == nil or a < 0.02 then return g end
    local p = math.rad(-50 * a)
    local c, sn = math.cos(p), math.sin(p)
    local function ry(v) return { v[1] * c - v[3] * sn, v[2], v[1] * sn + v[3] * c } end
    local F, R, U = rot_axes(g.pitch, g.yaw, g.roll)
    local pp, yw, rr = axes_rot(ry(F), ry(R), ry(U))
    local l = ry({ g.x, g.y, g.z })
    return { x = l[1], y = l[2], z = l[3] - 3 * a, pitch = pp, yaw = yw, roll = rr, fitted = g.fitted }
end
local function mv(F, Rt, U, x, y, z)   -- world = F*x + R*y + U*z
    return F[1] * x + Rt[1] * y + U[1] * z, F[2] * x + Rt[2] * y + U[2] * z, F[3] * x + Rt[3] * y + U[3] * z
end

-- v5.5 SAME-FRAME VIEW GUARD. Crash-dump analysis (11 UE minidumps, 2026-09-27): 9 of 11 crashes since v4.19 are ONE
-- crash - identical engine fault (GAME+0x3afee21, a virtual call through a dead object, address 0x20/-1) reached
-- through an identical call chain that starts in THIS per-eye view callback (our Lua -> UEVR -> ProcessEvent), on the
-- GameThread. The view callback runs AFTER the game's tick in the same frame - i.e. after the game has opened a menu /
-- swapped or destroyed the item hanging under our hand point - but our "menu open" flag only flips at the start of
-- the NEXT frame (and since v4.22 only after a 0.35 s debounce). So: here, before touching anything, check the
-- game's state for THIS frame with plain memory reads (no engine calls), and hold still while it is changing.
local vguard = { pc = nil, pawn = nil, hold = nil, until_t = 0, hsig = nil, holds = 0 }
local menu_shift = { yaw = 0, ro = nil }   -- v5.5: VR-menu placement (see place_menu_front)
local function obj_ok(o, cls)              -- in the object table + still the same class: NO engine call
    if o == nil or safe(function() return UEVR_UObjectHook.exists(o) end) ~= true then return false end
    if cls == nil then return true end
    return safe(function() return o:get_class():get_fname():to_string() end) == cls
end
local function kids_sig(c)                 -- addresses of what hangs under a component: plain reads, NO engine call
    local t = {}
    local kids = safe(function() return c.AttachChildren end)
    if type(kids) == "table" then for i, k in ipairs(kids) do t[i] = tostring(safe(function() return k:get_address() end) or 0) end end
    local ca = safe(function() return c.ChildActor end)
    if ca ~= nil then t[#t + 1] = "ca" .. tostring(safe(function() return ca:get_address() end) or 0) end
    return table.concat(t, ",")
end
local function vguard_hold(reason, secs)
    secs = secs or 0.3
    vguard.until_t = math.max(vguard.until_t, T + secs)
    vguard.holds = vguard.holds + 1
    if vguard.holds <= 12 then LOG("hands held still " .. string.format("%.1f", secs) .. " s: " .. reason) end
    pcall(fs.write, "sf_lastcall.txt", string.format("%.2f hold: %s", T, reason))   -- rare; crash breadcrumb
end

-- Re-baselined at the END of our tick every frame: a difference seen in the view callback can then only come from
-- the GAME's tick in this same frame (our own attaches happen in our tick and are absorbed here).
local function vguard_rebase()
    local h = vguard.hold
    if h ~= nil and obj_ok(h) then vguard.hsig = kids_sig(h) end
    for _, d in pairs(driven) do if obj_ok(d.comp) then d.sig = kids_sig(d.comp) end end
end

local function place_hands(view_index, w2m, pos, rot)
    track.calls = track.calls + 1
    if (track.menu and V62.menu_flat) or G.Vec == nil then return end   -- v6.6.5: every VR-panel menu: hands keep moving
    if not lvl.ready then return end   -- v6.0: never during a level load
    if next(driven) == nil and hudp.comp == nil then return end
    -- v5.5 same-frame guard (see vguard above)
    if T < vguard.until_t or T < (V62.hand_hold or 0) then return end   -- v6.6.4: own hold, only around inventory/shop
    local pc0 = vguard.pc
    if pc0 ~= nil then
        if not obj_ok(pc0) then return end
        -- a cursor is up: hold still until we know which menu it is (v6.6.4: VR-panel menus then move freely)
        if safe(function() return pc0.bShowMouseCursor end) == true and (not track.menu or V62.menu_flat) then vguard.until_t = T + 0.3; return end
    end
    local h0 = vguard.hold
    if h0 ~= nil and obj_ok(h0) then
        local sig = kids_sig(h0)
        if vguard.hsig ~= nil and sig ~= vguard.hsig then vguard.hsig = sig; vguard_hold("the item in the gun holder changed"); return end
        vguard.hsig = sig
    end
    -- v4.7: placed for EVERY eye from that eye's own pose (4.6 placed once per frame, so with Synchronized Sequential
    -- the other eye saw the gun where your hand was a frame earlier -> the gun "split" between the eyes)
    local F, Rt, U = rot_axes(rot.x, rot.y, rot.z)
    for e = 0, 1 do
        if track.eyeoff[e] == nil then
            local v = Vector3f.new(0, 0, 0)
            local ok = pcall(vr.get_eye_offset, e, v)
            local eo
            if ok and (math.abs(X(v)) + math.abs(Y(v)) + math.abs(Z(v))) > 0.005 then eo = { X(v), Y(v), Z(v) }
            else eo = { e == 0 and -0.032 or 0.032, 0, 0 } end
            track.eyeoff[e] = eo
            LOG(string.format("eye %d offset from head centre: %.3f %.3f %.3f m", e, eo[1], eo[2], eo[3]))
        end
    end
    local scale = (w2m or 100) * (track.world_scale or 1)
    -- v4.11: WHICH eye is this? Synchronized Sequential draws one eye per frame (left, right, left...) but always
    -- reports view 0 - so 4.7-4.10 treated every right-eye frame as the left eye and put the gun (and HUD) one eye-width
    -- off in the right eye: the "ghost" / double gun. Now each view picks the eye whose head centre (measured from the
    -- body camera, so walking/turning don't matter) matches the last one: the right eye matches within millimetres,
    -- the wrong one is off by a whole eye-width.
    if view_index == 1 then track.last_v1 = track.calls end
    local afr = (track.calls - (track.last_v1 or -1000)) > 20
    local w = {}
    for e = 0, 1 do
        local o = track.eyeoff[e]
        local ex, ey, ez = ovr2ue(o[1], o[2], o[3])
        local ox, oy, oz = mv(F, Rt, U, ex * scale, ey * scale, ez * scale)
        w[e] = { pos.x - ox, pos.y - oy, pos.z - oz }
    end
    local eye = view_index % 2
    local base = track.base
    if afr and base ~= nil then
        local r = {}
        for e = 0, 1 do r[e] = { w[e][1] - base[1], w[e][2] - base[2], w[e][3] - base[3] } end
        local ref = track.relref
        if ref ~= nil then
            local function d(a) return (a[1] - ref[1]) ^ 2 + (a[2] - ref[2]) ^ 2 + (a[3] - ref[3]) ^ 2 end
            eye = (d(r[0]) <= d(r[1])) and 0 or 1
        end
        track.relref = r[eye]
        track.eyecount = track.eyecount or { [0] = 0, [1] = 0 }
        track.eyecount[eye] = track.eyecount[eye] + 1
        if not track.afr_logged and track.eyecount[0] + track.eyecount[1] >= 200 then
            track.afr_logged = true
            LOG(string.format("one eye per frame: left %d / right %d of the last 200 views (should be about half each)", track.eyecount[0], track.eyecount[1]))
        end
    end
    local hx, hy, hz = w[eye][1], w[eye][2], w[eye][3]
    hand_vec = hand_vec or StructObject.new(G.Vec)
    hand_rot = hand_rot or StructObject.new(G.Rot)
    hand_hit = hand_hit or StructObject.new(G.Hit)
    if view_index == 0 or track.head == nil then track.head = { hx, hy, hz, F[1], F[2], F[3] } end
    if view_index == 0 and V62.binoc_on and V62.binoc.mode == "live" then pcall(V62.bino_place, hx, hy, hz, F) end   -- v6.6.15
    if view_index == 0 and V62.au.on then pcall(V62.audio_place, hx, hy, hz, rot.x, rot.y, rot.z) end   -- v6.6.18
    -- UEVR's own "attach to controller" must not move the part the mod holds: taken off here, in the first eye pass
    -- (UEVR re-creates a SAVED attachment every tick and applies it in its second-eye pass)
    -- v6.6.45: is the held item WHOLE right now? On a swap the game destroys it and makes a new one; a dying part still
    -- exists and reports nonsense (the playtest's "44099 cm from your hand", blamed on UEVR). Asked once per eye pass,
    -- used for the gun hold here and for the hand points further down.
    local gun_whole = cur ~= nil and alive(cur.actor) and alive(cur.mesh)
    if view_index == 0 and gun_whole and V62.ua.on then pcall(UEVR_UObjectHook.remove_motion_controller_state, cur.mesh) end
    if gun_whole and view_index <= 1 then pcall(V62.gun_hold, view_index) end      -- the gun stays in the hand, in both eye passes
    if view_index == 0 and gun_whole then guarded("sightfix", V62.sight_fix) end
    -- v4.9: the game's HUD floats straight ahead of your eyes, at the distance of whatever you look at (so walls never
    -- hide it and it never looks doubled); its size scales with distance so it always covers the same part of your view
    if hudp.comp ~= nil then
        if obj_ok(hudp.comp, "WidgetComponent") and hudp.comp.K2_SetWorldLocationAndRotation ~= nil then
            -- v4.10: the HUD sits where your RIGHT HAND points (its centre ring = what Y / RB will use), facing your eyes
            local dx, dy, dz, dd = F[1], F[2], F[3], hudp.dist
            local P = hudp.P
            if hudp.info == true and S.hud_head ~= false then
                -- v6.6.26: a HUD with information (helmet): in front of your eyes, a little below, following your head
                local pch = math.rad(S.hud_head_down or -8)
                local hl = math.sqrt(F[1] * F[1] + F[2] * F[2])
                local fy = math.atan(F[2], F[1])
                local fp = math.atan(F[3], hl) + pch
                dx, dy, dz = math.cos(fp) * math.cos(fy), math.cos(fp) * math.sin(fy), math.sin(fp)
                dd = (S.hud_head_dist or 1.6) * 100
            elseif P ~= nil then
                local vx, vy, vz = P[1] - hx, P[2] - hy, P[3] - hz
                local len = math.sqrt(vx * vx + vy * vy + vz * vz)
                if len > 1 then dx, dy, dz = vx / len, vy / len, vz / len; dd = math.max(25, math.min(800, len - 6)) end
            end
            local headhud = hudp.info == true and S.hud_head ~= false
            local sc = 2 * dd * math.tan(math.rad((headhud and (S.hud_head_fov or 75) or (S.hud_fov or 50)) * 0.5)) / 1920
            if hudp.shown_ref ~= nil and not hudp.shown_ref.shown then sc = 0.0001 end
            if math.abs(sc - hudp.scale) > hudp.scale * 0.01 then
                hudp.scale = sc
                hudp.comp:SetWorldScale3D(mkvec(sc, sc, sc))
            end
            hand_vec.X, hand_vec.Y, hand_vec.Z = hx + dx * dd, hy + dy * dd, hz + dz * dd
            hand_rot.Pitch = math.deg(math.asin(math.max(-1, math.min(1, -dz))))
            hand_rot.Yaw, hand_rot.Roll = math.deg(math.atan(-dy, -dx)), 0
            if T < trace_until then TRACE("view: HUD panel place") end
            hudp.comp:K2_SetWorldLocationAndRotation(hand_vec, hand_rot, false, hand_hit, true)
            -- v6.6.28: on the head HUD the aiming ring is slid to where the eye-to-pointer line crosses the panel
            local ring = hudp.ring
            if ring ~= nil and alive(ring) and G.Vec2 ~= nil and not hudp.ring_sep then
                local tx, ty = 0, 0
                if headhud and P ~= nil and sc > 0.001 then
                    local Fp, Rp, Up = rot_axes(hand_rot.Pitch, hand_rot.Yaw, 0)      -- the panel's own axes (forward = toward the eyes)
                    local cx, cy, cz = hand_vec.X, hand_vec.Y, hand_vec.Z
                    local nx, ny, nz = dx, dy, dz                                     -- the panel plane's normal (away from the eyes)
                    local vx, vy, vz = P[1] - hx, P[2] - hy, P[3] - hz
                    local den = vx * nx + vy * ny + vz * nz
                    if den > 1e-3 then
                        local t = ((cx - hx) * nx + (cy - hy) * ny + (cz - hz) * nz) / den
                        local qx, qy, qz = hx + vx * t - cx, hy + vy * t - cy, hz + vz * t - cz
                        local ux = (qx * Rp[1] + qy * Rp[2] + qz * Rp[3]) / sc        -- panel pixels along its right axis
                        local uy = (qx * Up[1] + qy * Up[2] + qz * Up[3]) / sc        -- ... and up axis
                        tx = (S.hud_ring_mirror and 1 or -1) * ux                     -- the widget's x runs against the component's right axis
                        ty = -uy
                        tx = math.max(-1100, math.min(1100, tx)); ty = math.max(-700, math.min(700, ty))
                    end
                end
                if math.abs(tx - (hudp.rtx or 0)) > 0.5 or math.abs(ty - (hudp.rty or 0)) > 0.5 then
                    hudp.rtx, hudp.rty = tx, ty
                    hudp.rv = hudp.rv or StructObject.new(G.Vec2)
                    hudp.rv.X, hudp.rv.Y = tx, ty
                    pcall(function() ring:SetRenderTranslation(hudp.rv) end)
                end
            end
        else
            hudp.comp = nil
        end
    end
    -- v6.6.29: the aiming ring's own panel: where your hand points, facing your eyes, same apparent size as before
    local rc = hudp.rcomp
    if rc ~= nil then
        if obj_ok(rc, "WidgetComponent") and rc.K2_SetWorldLocationAndRotation ~= nil then
            local P = hudp.P
            local dx, dy, dz, dd = F[1], F[2], F[3], 150
            if P ~= nil then
                local vx, vy, vz = P[1] - hx, P[2] - hy, P[3] - hz
                local len = math.sqrt(vx * vx + vy * vy + vz * vz)
                if len > 1 then dx, dy, dz = vx / len, vy / len, vz / len; dd = math.max(25, math.min(800, len - 6)) end
            end
            local sc = 2 * dd * math.tan(math.rad((S.hud_fov or 50) * 0.5)) / 1920
            if menu_mode or not lvl.ready or view.ok == false then sc = 0.0001 end
            if math.abs(sc - (hudp.rscale or 0)) > (hudp.rscale or 0) * 0.01 then
                hudp.rscale = sc
                rc:SetWorldScale3D(mkvec(sc, sc, sc))
            end
            hudp.rv3 = hudp.rv3 or StructObject.new(G.Vec)
            hudp.rr3 = hudp.rr3 or StructObject.new(G.Rot)
            hudp.rh3 = hudp.rh3 or StructObject.new(G.Hit)
            hudp.rv3.X, hudp.rv3.Y, hudp.rv3.Z = hx + dx * dd, hy + dy * dd, hz + dz * dd
            hudp.rr3.Pitch = math.deg(math.asin(math.max(-1, math.min(1, -dz))))
            hudp.rr3.Yaw, hudp.rr3.Roll = math.deg(math.atan(-dy, -dx)), 0
            rc:K2_SetWorldLocationAndRotation(hudp.rv3, hudp.rr3, false, hudp.rh3, true)
        else
            hudp.rcomp = nil
        end
    end
    if next(driven) == nil then return end
    -- v4.18: if the game is tearing down the weapon / off-hand item at this very moment, leave the hand points alone
    -- this view (moving them would drag a dying child component along - that was the crash)
    local skip_r = cur ~= nil and not gun_whole
    local skip_l = offh.actor ~= nil and (not alive(offh.actor) or not alive(offh.root))
    if skip_r and not track.skip_logged then track.skip_logged = true; LOG("weapon being removed by the game - hand point not moved this frame") end
    -- v4.19: the same for ANYTHING hanging under a hand point (the flashlight mount's child actor, attached items):
    -- a component is only moved when it, its owner, its child actor and its attached children are all valid
    -- v5.5: what hangs under each hand point is compared by ADDRESS with last view (plain reads). If it changed this
    -- frame (the game is swapping / tearing down the item), no hand point moves for half a second. The v4.19
    -- version called GetOwner / IsValid through the engine on every child - engine calls on the very objects being
    -- torn down.
    for _, d in pairs(driven) do
        d.kids_ok = true
        if obj_ok(d.comp) then
            local sig = kids_sig(d.comp)
            if d.sig ~= nil and sig ~= d.sig then d.sig = sig; vguard_hold("something under " .. (d.label or "?") .. " changed"); return end
            d.sig = sig
            -- and nothing hanging under it may be mid-teardown (validity asked of the engine's utility object, never ON them)
            local ca = safe(function() return d.comp.ChildActor end)
            if ca ~= nil and not alive(ca) then d.kids_ok = false end
            local kids = safe(function() return d.comp.AttachChildren end)
            if d.kids_ok and type(kids) == "table" then
                for _, k in ipairs(kids) do if not alive(k) then d.kids_ok = false; break end end
            end
        end
    end
    vr.get_pose(vr.get_hmd_index(), tp_h, tq_h)
    local hinv = { x = -X(tq_h), y = -Y(tq_h), z = -Z(tq_h), w = W(tq_h) }
    -- both controllers in world space (through the eye pose UEVR just rendered with), computed once per view
    local hands = {}
    for hand = 0, 1 do
        local ctl = hand                                        -- v6.6.49: left-handed = hand 1 (gun) is the LEFT controller
        if S.left_handed == true then ctl = 1 - hand end
        local idx = (ctl == 0) and vr.get_left_controller_index() or vr.get_right_controller_index()
        vr.get_pose(idx, tp_c, tq_c)
        -- controller relative to the headset (headset-local OpenVR space)
        local rx, ry, rz = qv(hinv, X(tp_c) - X(tp_h), Y(tp_c) - Y(tp_h), Z(tp_c) - Z(tp_h))
        local lx, ly, lz = ovr2ue(rx, ry, rz)
        -- controller axes relative to the headset, in Unreal head-local axes
        local fx, fy, fz = ovr2ue(qv(hinv, qv(tq_c, 0, 0, -1)))
        local sx, sy, sz = ovr2ue(qv(hinv, qv(tq_c, 1, 0, 0)))
        local ux, uy, uz = ovr2ue(qv(hinv, qv(tq_c, 0, 1, 0)))
        local wx, wy, wz = mv(F, Rt, U, lx * scale, ly * scale, lz * scale)
        local f = { mv(F, Rt, U, fx, fy, fz) }
        local r = { mv(F, Rt, U, sx, sy, sz) }
        local u = { mv(F, Rt, U, ux, uy, uz) }
        local tilt = math.rad((hand == 1) and S.grip_angle
            or (S.light_angle + ((V62.fl_alt and offh.actor ~= nil) and (S.fl_alt_angle or 35) or 0)))   -- v6.3: FLAT hold
        if tilt ~= 0 then
            local c, sn = math.cos(tilt), math.sin(tilt)
            f, u = { f[1] * c + u[1] * sn, f[2] * c + u[2] * sn, f[3] * c + u[3] * sn },
                   { u[1] * c - f[1] * sn, u[2] * c - f[2] * sn, u[3] * c - f[3] * sn }
        end
        hands[hand] = { x = hx + wx, y = hy + wy, z = hz + wz, f = f, r = r, u = u }
    end
    -- v4.13 two-handed grip: with the left hand on the fore-grip the gun's barrel points from the right hand to the
    -- left hand (roll kept as close to the one-handed pose as possible)
    if twohand.on and twohand.m ~= nil then
        local R, Lh, m = hands[1], hands[0], twohand.m
        local dx, dy, dz = Lh.x - R.x, Lh.y - R.y, Lh.z - R.z
        local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dl > 5 then
            dx, dy, dz = dx / dl, dy / dl, dz / dl
            local f, r, u = R.f, R.r, R.u
            local mw = { f[1] * m[1] + r[1] * m[2] + u[1] * m[3], f[2] * m[1] + r[2] * m[2] + u[2] * m[3], f[3] * m[1] + r[3] * m[2] + u[3] * m[3] }
            if view_index == 0 then V62.thf = { t = T, d = mw } end   -- v6.6.45: where the right hand alone points (V62.free_hand_ray)
            -- shortest rotation taking mw -> d (Rodrigues)
            local ax, ay, az = mw[2] * dz - mw[3] * dy, mw[3] * dx - mw[1] * dz, mw[1] * dy - mw[2] * dx
            local sn = math.sqrt(ax * ax + ay * ay + az * az)
            local cs = mw[1] * dx + mw[2] * dy + mw[3] * dz
            if sn > 1e-4 then
                ax, ay, az = ax / sn, ay / sn, az / sn
                local function rot(v)
                    local dot = ax * v[1] + ay * v[2] + az * v[3]
                    local cx, cy, cz = ay * v[3] - az * v[2], az * v[1] - ax * v[3], ax * v[2] - ay * v[1]
                    return { v[1] * cs + cx * sn + ax * dot * (1 - cs), v[2] * cs + cy * sn + ay * dot * (1 - cs), v[3] * cs + cz * sn + az * dot * (1 - cs) }
                end
                R.f, R.r, R.u = rot(f), rot(r), rot(u)
            end
        end
    end
    for _, d in pairs(driven) do
        local ok_move = obj_ok(d.comp, d.cls) and d.kids_ok and not ((d.hand == 1 and skip_r) or (d.hand == 0 and skip_l and d.comp == offh.grip))
        if not ok_move and obj_ok(d.comp) then
            track.skips = (track.skips or 0) + 1
            if track.skips <= 5 then LOG("not moving " .. (d.label or "?") .. " this frame: something under it is being removed by the game") end
        end
        if ok_move then
            local H = hands[d.hand]
            local f, r, u = H.f, H.r, H.u
            local wx, wy, wz = H.x, H.y, H.z
            wx = wx + f[1] * d.lx + r[1] * d.ly + u[1] * d.lz
            wy = wy + f[2] * d.lx + r[2] * d.ly + u[2] * d.lz
            wz = wz + f[3] * d.lx + r[3] * d.ly + u[3] * d.lz
            local p, yw, rl = axes_rot(f, r, u)
            hand_vec.X, hand_vec.Y, hand_vec.Z = wx, wy, wz
            hand_rot.Pitch, hand_rot.Yaw, hand_rot.Roll = p, yw, rl
            if T < trace_until then TRACE("view: K2_SetWorldLocationAndRotation " .. (d.label or "?")) end
            if d.comp.K2_SetWorldLocationAndRotation ~= nil then   -- a component being torn down (level change) has no methods
                d.comp:K2_SetWorldLocationAndRotation(hand_vec, hand_rot, false, hand_hit, true)
            end
        end
    end
    track.applied = track.applied + 1
end

-- v4.5: the per-eye hook is only switched on once you're in the game world, not at startup. 4.0 (buttons worked) had no
-- per-eye hook; every version since that had it at startup had dead buttons. The log shows exactly what happens when it
-- starts, so this settles whether it is the cause.
local function start_hand_hook()
    if track.hooked then return end
    track.hooked = true
    LOG("per-eye hand tracking starting now (controller read by the game so far: " .. tostring(track.pad_seen == true) .. ")")
    -- v4.9: the game's camera now turns with your head (so "what am I looking at" - Y interact, RB pick up, the HUD ring -
    -- is where you really look). The picture must not turn twice, so the eyes are rendered from the body direction here
    -- (exactly what 4.8 rendered) and UEVR adds your head on top as before.
    V62.reg("on_pre_calculate_stereo_view_offset", function(device, view_index, world_to_meters, position, rotation, is_double)
        track.base = track.base or {}
        track.base[1], track.base[2], track.base[3] = position.x, position.y, position.z   -- v4.11: body camera, for eye detection
        if view.off or not view.ok then return end
        local ok, err = pcall(function()
            local a = view.arm
            if a ~= nil then
                local F0, R0, U0 = rot_axes(rotation.x, rotation.y, rotation.z)
                local F1, R1, U1 = rot_axes(0, view.yaw, 0)
                local ox, oy, oz = mv(F0, R0, U0, a[1], a[2], a[3])
                local nx, ny, nz = mv(F1, R1, U1, a[1], a[2], a[3])
                position.x, position.y, position.z = position.x - ox + nx, position.y - oy + ny, position.z - oz + nz
            end
            rotation.x, rotation.y, rotation.z = 0, view.yaw, 0
            view.count = view.count + 1
            track.base[1], track.base[2], track.base[3] = position.x, position.y, position.z
        end)
        if not ok then
            view.errs = view.errs + 1
            if view.errs <= 3 then LOG("ERROR view fix: " .. tostring(err)) end
            if view.errs >= 20 then view.off = true; LOG("view fix switched itself off after 20 errors") end
        end
    end)
    V62.reg("on_post_calculate_stereo_view_offset", function(device, view_index, world_to_meters, position, rotation, is_double)
        if track.off then return end
        local ok, err = pcall(place_hands, view_index, world_to_meters, position, rotation)
        if not ok then
            track.errs = track.errs + 1
            if track.errs <= 3 then LOG("ERROR hand tracking: " .. tostring(err)) end
            if track.errs >= 20 then track.off = true; LOG("hand tracking switched itself off after 20 errors") end
        end
    end)
end

-- proof that the component really moves: log its world position a few times
local function sample_driven()
    for _, d in pairs(driven) do
        if d.samples < 6 and alive(d.comp) then
            local loc = safe(function() return d.comp:K2_GetComponentLocation() end)
            if loc ~= nil then
                local p = string.format("%.0f %.0f %.0f", loc.X or 0, loc.Y or 0, loc.Z or 0)
                LOG(string.format("check %s position: %s%s   [hand updates %d, views %d, controllers active %s]", d.label, p,
                    (d.last ~= nil and d.last ~= p) and "  (moving - good)" or "", track.applied, track.calls, tostring(safe(vr.is_using_controllers))))
                d.last = p
                d.samples = d.samples + 1
            end
        end
    end
end

---------------------------------------------------------------------------
-- 1 + 2: UI visibility, flat-screen menus, pointer
---------------------------------------------------------------------------
local ORIG = nil
-- v5.1: when a menu opens, list the on-screen UMG widgets (class + whether UEVR is showing them). This tells us
-- which menus render in VR through the AHUD overlay and which (if any - maybe the escape/pause menu) do not, so we
-- can give just those the flat-screen treatment later. One line per open; guarded and cheap.
local function menu_widget_names()
    local names = {}
    if G.UserWidget == nil then return names end
    local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(G.UserWidget, false) end)
    if type(all) ~= "table" then return names end
    local seen = {}
    for _, w in ipairs(all) do
        if alive(w) and not fullname(w):find("Default__") and safe(function() return w:IsInViewport() end) == true then
            local c = shortclass(w)
            if not seen[c] then seen[c] = true; names[#names + 1] = c end
        end
    end
    return names
end
-- v5.3: PER-WIDGET flat screen (the uevrlib "screen2DWhenActive" pattern). Measured in Test 39: every open of the
-- Inventory or Shop screen makes UEVR log "Inserting new scene state" - those two screens draw a 3D item/character
-- PREVIEW, i.e. a second scene view. Left in VR, that extra view collides with UEVR's stereo hook every frame
-- ("vtable is already hooked") until the game dies (Exception address is null). So THOSE two get the flat screen
-- (debounced, so two flips can't race); dialogue / sleep / shop-less menus / game-over stay in VR, where they
-- look great and never touch the render target.
local FLAT_WIDGETS = { InventoryScreen_C = true, ShopScreen_C = true }
local menu_flat_now = false
local pointer_inside = false
-- v6.6: the full scan of every UI widget (to see which menu opened) took 7-9 ms on each open. The first 3 menus still
-- get it (the log lists them); after that only the two flat-view screens are looked up by their own class - a short
-- list. If those classes can't be looked up, the full scan stays (the flat view keeps the game from crashing).
V62.flat_cls, V62.flat_n = {}, 0
function V62.flat_lookup()
    local want = 0
    for _ in pairs(FLAT_WIDGETS) do want = want + 1 end
    if V62.flat_n >= want then return true end
    if V62.wbgc == nil then V62.wbgc = api:find_uobject("Class /Script/UMG.WidgetBlueprintGeneratedClass") end
    if V62.wbgc == nil then return false end
    local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(V62.wbgc, false) end)
    if type(all) ~= "table" then return false end
    for _, k in ipairs(all) do
        local n = fullname(k):match("[%w_]+$")
        if n ~= nil and FLAT_WIDGETS[n] and V62.flat_cls[n] == nil then V62.flat_cls[n] = k; V62.flat_n = V62.flat_n + 1 end
    end
    return true                  -- a screen not loaded yet can't be on screen either; it is looked up again next time
end
function V62.menu_names()
    V62.mn = (V62.mn or 0) + 1
    if V62.mn <= 3 or not V62.flat_lookup() then return V62.timed("menu widget scan", menu_widget_names) end
    local names = {}
    for n, c in pairs(V62.flat_cls) do
        local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(c, false) end)
        if type(all) == "table" then
            for _, w in ipairs(all) do
                if alive(w) and not fullname(w):find("Default__") and safe(function() return w:IsInViewport() end) == true then
                    names[#names + 1] = n; break
                end
            end
        end
    end
    if V62.mn == 4 then LOG("menus: from now on only the inventory / shop screens are looked for when a menu opens") end
    return names
end

local fixed_retainers, fixed_count = {}, 0
local function fix_ui_effects()
    if not S.fix_ui_effects or G.Retainer == nil then return end
    -- v6.0: switching retain-rendering off frees a render target - never while a level is loading / settling
    if lvl.loading or (api:get_local_pawn(0) ~= nil and not lvl.ready) then ui_rescan = true; return end
    if T - (lvl.ready_t or -99) < 1.5 then ui_rescan = true; return end   -- v6.6.6: keeps its old 1.5 s settle
    local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(G.Retainer, false) end)
    if type(all) ~= "table" then return end
    local newly = 0
    for _, rb in ipairs(all) do
        local a = addr(rb)
        if a ~= nil and not fixed_retainers[a] and alive(rb) and safe(function() return rb.Slot end) ~= nil then
            fixed_retainers[a] = true
            -- v4.17: flip the property (no engine call); the engine call only for a box that is already drawing
            local was = safe(function() return rb.bRetainRender end)
            pcall(function() rb.bRetainRender = false end)
            TRACE("SetRetainRendering " .. fullname(rb))
            local ok = pcall(function() rb:SetRetainRendering(false) end)
            TRACE("idle")
            if ok then newly = newly + 1; fixed_count = fixed_count + 1 else LOG("could not switch off effect on " .. fullname(rb)) end
        end
    end
    if newly > 0 then LOG("UI effect layers switched off: " .. newly .. " new (" .. fixed_count .. " total)") end
end

local function remember_ui()
    ORIG = { follow = getmod("UI_FollowView"), dist = getmod("UI_Distance"), size = getmod("UI_Size"), screen2d = getmod("VR_2DScreenMode"),
             yoff = getmod("UI_Y_Offset"), xoff = getmod("UI_X_Offset") }
    if ORIG.screen2d == "true" then ORIG.screen2d = "false" end   -- never restore into flat mode by accident
    if ORIG.follow == "true" then ORIG.follow = "false" end
    LOG("UI at start: follow=" .. ORIG.follow .. " dist=" .. ORIG.dist .. " size=" .. ORIG.size
        .. " invertAlpha=" .. getmod("UI_InvertAlpha") .. " ui tex " .. tostring(safe(vr.get_ui_width)) .. "x" .. tostring(safe(vr.get_ui_height)))
    setmod("UI_InvertAlpha", S.ui_invert_alpha and "true" or "false")
    setmod("VR_DecoupledPitchUIAdjust", "false")
    ORIG.aim = getmod("VR_AimMethod")
    -- v6.0: OFF. The Steam Frame has no thumbrests; our Frame layout re-uses UEVR's spare "thumbrest touch" actions for
    -- the bumpers, which D-pad shifting would otherwise turn into a D-pad while you move the stick.
    if getmod("VR_DPadShifting") ~= "false" then setmod("VR_DPadShifting", "false") end
    track.world_scale = tonumber(getmod("VR_WorldScale")) or 1
    -- v6.6.50: UEVR starts its head-tracking hook only once an aim method other than "Game" is active
    -- (IXRTrackingSystemHook::on_pre_engine_tick) - without it the game never reads the VR controllers - and this script
    -- runs on "Game" (we aim ourselves, like jbusfield's 6DOF profiles). UEVR saves whatever is set when its menu
    -- closes, so config.txt says "Game" after every session. plugins\sf_start.dll puts the start value back before
    -- UEVR reads the file. If the session still started on "Game" (that plugin missing, the file not writable), an aim
    -- method is switched on here for one second first (V62.aim_kick; update_body leaves it alone meanwhile).
    if S.vr_body then
        if ORIG.aim == "0" or ORIG.aim == "" then
            ORIG.aim = "2"                                       -- (what a script reset puts back: never "Game")
            setmod("VR_AimMethod", "2")
            V62.aim_kick = T + 1.0
            LOG("UEVR started on aim method 'Game' (plugins\\sf_start.dll did not put the start value back): switched on for one second so UEVR's tracking hook starts")
        else
            setmod("VR_AimMethod", "0")
        end
    end
    LOG("UI_InvertAlpha now " .. getmod("UI_InvertAlpha") .. ", UEVR aim method " .. ORIG.aim .. " -> " .. getmod("VR_AimMethod"))
end

local place_menu_front    -- v5.5: assigned further down (needs the quaternion helpers)
local saved_view = nil
local function snap_menu_in_front()
    -- remember the current view, then put the static menu screen where you are looking right now
    local ro, so = Quaternionf.new(0, 0, 0, 1), Vector3f.new(0, 0, 0)
    vr.get_rotation_offset(ro)
    vr.get_standing_origin(so)
    saved_view = { ro = ro, so = so }
    local hp, hq = Vector3f.new(0, 0, 0), Quaternionf.new(0, 0, 0, 1)
    vr.get_pose(vr.get_hmd_index(), hp, hq)
    pcall(vr.recenter_view)
    pcall(vr.set_standing_origin, hp)
end
local function restore_view()
    if saved_view == nil then return end
    pcall(vr.set_rotation_offset, saved_view.ro)
    pcall(vr.set_standing_origin, saved_view.so)
    saved_view = nil
end

local function set_menu_mode(on)
    if ORIG == nil or on == menu_mode then return end
    menu_mode = on
    quiet_until = T + ((not on and not menu_flat_now) and 0 or 1.0)   -- v6.6.5: any VR-panel menu closed: no pause
    if not on and menu_flat_now then V62.hand_hold = T + 1.0 end        -- flat screen closed: hold the hand 1 s
    if on then V62.inv_check_at = T + 0.3 end                           -- v6.6.5: inventory widget may appear a moment later
    trace_until = T + 8.0
    track.menu = on
    -- UEVR re-aims its whole frame at the right controller while controller-aim is active; pause that in menus
    pcall(vr.set_aim_allowed, not on)
    if on then
        local names = V62.menu_names()
        if #names > 0 then LOG("menu widgets on screen: " .. table.concat(names, ", ")) end
        menu_flat_now = S.menu_flat_screen
        V62.inv_menu = false
        V62.menu_flat = S.menu_flat_screen == true                 -- v6.6.4: known before the hands' check runs again
        for _, c in ipairs(names) do
            if FLAT_WIDGETS[c] then
                V62.inv_menu = true
                if S.flat_inventory then menu_flat_now = true; V62.menu_flat = true; V62.hand_hold = T + 1.0
                else
                    V62.invn = (V62.invn or 0) + 1
                    if V62.invn <= 20 then LOG("inventory/shop as a VR panel (test) - open #" .. V62.invn) end
                end
            end
        end
        setmod("UI_Distance", S.menu_distance); setmod("UI_Size", S.menu_size)
        setmod("UI_Y_Offset", string.format("%.3f", S.menu_height))
        if menu_flat_now then
            -- flat screen: anchor it in front of you (the world is hidden behind it, so the recenter is invisible)
            setmod("UI_FollowView", "false")
            snap_menu_in_front()
        else
            -- v5.5: VR overlay menu is WORLD-LOCKED straight in front of you (the tester: following the head "obviously not
            -- ideal"). UEVR places a non-following panel from the play-space origin + its forward direction only
            -- (OverlayComponent.cpp), so: turn UEVR's forward to where you look, turn our rendered body view back by
            -- the same angle (the world does not move), and put the panel in front of your HEAD with the X/Y/distance
            -- offsets instead of moving the origin (that origin move was the old ~0.8 m jolt).
            setmod("UI_FollowView", "false")
            pcall(place_menu_front)
        end
    else
        setmod("UI_FollowView", "false")
        setmod("UI_Distance", ORIG.dist ~= "" and ORIG.dist or "2.0")
        setmod("UI_Size", ORIG.size ~= "" and ORIG.size or "2.0")
        setmod("UI_Y_Offset", (ORIG.yoff ~= nil and ORIG.yoff ~= "") and ORIG.yoff or "0.000")
        setmod("UI_X_Offset", (ORIG.xoff ~= nil and ORIG.xoff ~= "") and ORIG.xoff or "0.000")
        if menu_flat_now then restore_view()
        else
            -- v5.5: undo the VR-menu turn exactly (UEVR forward back, body view back) - the world stays put
            if menu_shift.ro ~= nil then pcall(vr.set_rotation_offset, menu_shift.ro) end
            view.yaw = view.yaw - menu_shift.yaw
            menu_shift.yaw, menu_shift.ro = 0, nil
        end
        menu_flat_now = false
    end
    if not on and V62.inv_menu then V62.inv_menu = false end
    V62.menu_flat = on and menu_flat_now                   -- v6.6: weapon cycling forgets empty slots after these
    setmod("VR_2DScreenMode", (on and menu_flat_now) and "true" or "false")
    LOG("menu mode " .. tostring(on) .. " (2D=" .. getmod("VR_2DScreenMode") .. ", follow=" .. getmod("UI_FollowView") .. ")")
end

local function v3(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v3(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function qrot(q, v) local u = v3(q.x, q.y, q.z); local t = mul(cross(u, v), 2); return add(add(v, mul(t, q.w)), cross(u, t)) end
local function qconj(q) return { x = -q.x, y = -q.y, z = -q.z, w = q.w } end
local tp, tq = Vector3f.new(0, 0, 0), Quaternionf.new(0, 0, 0, 1)
local to, tr = Vector3f.new(0, 0, 0), Quaternionf.new(0, 0, 0, 1)

local function viewport_size(pc)
    TRACE("GetViewportSize")
    local vs = G.Layout and safe(function() return G.Layout:GetViewportSize(pc) end)
    if vs ~= nil and X(vs) > 0 and Y(vs) > 0 then return X(vs), Y(vs) end
    local w, h = safe(vr.get_ui_width), safe(vr.get_ui_height)
    if w and h and w > 0 and h > 0 then return w, h end
    return 2560, 1440
end

-- v4.22 CRASH FIX. Flipping VR_2DScreenMode (menu flat-screen) makes UEVR reallocate the whole stereo render
-- target (2896x2896/eye <-> 1920x1080). Opening AND closing a menu QUICKLY fired two of those reallocations a few
-- frames apart; they raced, the second copied from a texture the first had not finished making (nullptr / compositor
-- "AlreadySubmitted"), and the GAME crashed. Fix: (1) don't flip until the cursor state has HELD for MENU_DEBOUNCE
-- (a quick open+close then causes ZERO flips), and (2) never flip within MODE_SETTLE of the last flip, so two
-- reallocations can never overlap. Real menus (held open) still go flat as before, just ~1/3 s later.
local menu_want, menu_want_since, last_menu_flip, menu_pending = false, -100.0, -100.0, false
-- (v6: MENU_DEBOUNCE = 0.35 s and MODE_SETTLE = 1.0 s are written inline below)
-- v6.5: the game draws its cursor itself and ignores scale changes on it, so we draw our OWN copy of its cursor widget
-- on top, 2x, at the pointer, only while a menu shows the cursor (it never takes clicks: hit-test invisible)
function V62.cursor_overlay(on, x, y)
    if not S.big_cursor then on = false end
    if on == "hide" then                       -- pointer off the menu panel: hide it, keep it for later
        if V62.cw ~= nil and V62.cw_shown then V62.cw_shown = false; pcall(function() V62.cw:SetVisibility(2) end) end
        return
    end
    if not on then
        if V62.cw ~= nil then
            local w = V62.cw
            V62.cw = nil
            pcall(function() w:RemoveFromParent() end)
        end
        return
    end
    if V62.cw == nil or not alive(V62.cw) then
        V62.cw = nil
        if T < quiet_until or T < (V62.cw_retry or 0) or G.Vec2 == nil then return end
        V62.cw_retry = T + 3.0
        if V62.cur_cls == nil then V62.cur_cls = api:find_uobject("WidgetBlueprintGeneratedClass /Game/Classes/GUI/New/Components/CursorWidget.CursorWidget_C") end
        if V62.wbl == nil then local c = api:find_uobject("Class /Script/UMG.WidgetBlueprintLibrary"); V62.wbl = c and c:get_class_default_object() end
        local pc = api:get_player_controller(0)
        if V62.cur_cls == nil or V62.wbl == nil or pc == nil then
            if not V62.cw_logged then V62.cw_logged = true; LOG("big cursor: cursor widget or widget library not found") end
            return
        end
        local ok, w = pcall(function() return V62.wbl:Create(pc, V62.cur_cls, pc) end)
        if not ok or w == nil then
            if not V62.cw_logged then V62.cw_logged = true; LOG("big cursor: could not create one (" .. tostring(w) .. ")") end
            return
        end
        local sc = StructObject.new(G.Vec2); sc.X, sc.Y = 2.0, 2.0
        local z = StructObject.new(G.Vec2); z.X, z.Y = 0, 0
        local ok2, err = pcall(function()
            w:SetVisibility(3)                     -- HitTestInvisible: clicks go through to the menu
            w:SetRenderTransformPivot(z)
            w:SetRenderScale(sc)
            w:SetAlignmentInViewport(z)
            w:AddToViewport(10000)
        end)
        if not V62.cw_logged2 then V62.cw_logged2 = true; LOG("big cursor: " .. (ok2 and "on" or ("failed: " .. tostring(err)))) end
        if not ok2 then return end
        V62.cw, V62.cw_shown = w, true
    end
    if not V62.cw_shown then V62.cw_shown = true; pcall(function() V62.cw:SetVisibility(3) end) end
    local p = StructObject.new(G.Vec2); p.X, p.Y = x, y
    pcall(function() V62.cw:SetPositionInViewport(p, true) end)
end
-- v6.5: how long did that take? (logged when over 4 ms, first 30 times) - for the menu stutter hunt
function V62.timed(name, f, ...)
    local ok0, c0 = pcall(os.clock)
    local r = f(...)
    if ok0 then
        local ms = (os.clock() - c0) * 1000
        if ms > 4 and (V62.tlog or 0) < 30 then V62.tlog = (V62.tlog or 0) + 1; LOG(string.format("timing: %s took %.0f ms", name, ms)) end
    end
    return r
end
local function update_menus()
    local pc = api:get_player_controller(0)
    local cursor = pc ~= nil and pc.bShowMouseCursor == true
    if cursor ~= menu_want then
        menu_want = cursor; menu_want_since = T
        quiet_until = T + 1.0   -- v4.22: calm heavy engine calls across the whole menu transition, not just at the flip
        if menu_mode and not menu_want and not menu_flat_now then quiet_until = T end   -- v6.6.5: VR-panel menu closing (all menus)
        if menu_want == menu_mode and menu_pending then
            menu_pending = false
            LOG("quick menu open/close - skipped the flat-screen flip (no render reallocation, avoids the crash)")
        elseif menu_want ~= menu_mode then
            menu_pending = true
        end
    end
    local vr_only = not S.flat_inventory and not S.menu_flat_screen        -- v6.6.5: no flat screens -> no waiting
    if menu_want ~= menu_mode and (T - menu_want_since) >= (vr_only and 0 or 0.35) and (T - last_menu_flip) >= (vr_only and 0 or 1.0) then
        last_menu_flip = T; menu_pending = false
        V62.timed("menu switch", set_menu_mode, menu_want)
        if not menu_want then V62.mc = { t = T, max = 0, n = 0, feats = {} } end   -- v6.5: watch the 4 s after a menu closes
    end
    if menu_mode and V62.inv_check_at ~= nil and T > V62.inv_check_at then   -- v6.6.5: was it the inventory / shop?
        V62.inv_check_at = nil
        if not V62.inv_menu and (V62.mn or 0) >= 3 then
            for _, n in ipairs(V62.menu_names()) do if FLAT_WIDGETS[n] then V62.inv_menu = true end end
        end
    end
    -- v6.2: drive the cursor whenever the game shows it - not only once the menu mode has switched (that took up to
    -- 1 s after opening/closing something, and the cursor sat still meanwhile)
    if not cursor or not S.pointer_enabled then pointer_inside = false; if V62.cw ~= nil then pcall(V62.cursor_overlay, false) end; return end

    local money_has = false                                    -- v6.6.51: the trade screen's Add Money has the cursor for a moment
    if V62.mny ~= nil then
        local okm, mx, my = pcall(V62.money_cursor, pc)
        if not okm then
            V62.mny = nil
            if not V62.mny_err then V62.mny_err = true; LOG("ERROR in money: " .. tostring(mx)) end
        elseif mx ~= nil then
            money_has = true
            TRACE("SetMouseLocation"); pc:SetMouseLocation(mx, my); TRACE("idle")
            if S.big_cursor then pcall(V62.cursor_overlay, true, mx, my) end
        end
    end

    local dist, size = num(getmod("UI_Distance"), 2.0), num(getmod("UI_Size"), 2.0)
    local xo, yo = num(getmod("UI_X_Offset"), 0.0), num(getmod("UI_Y_Offset"), 0.0)
    local fq
    if getmod("UI_FollowView") == "true" then
        vr.get_pose(vr.get_hmd_index(), to, tr)
        fq = { x = X(tr), y = Y(tr), z = Z(tr), w = W(tr) }
    else
        vr.get_rotation_offset(tr)
        vr.get_standing_origin(to)
        fq = qconj({ x = X(tr), y = Y(tr), z = Z(tr), w = W(tr) })
    end
    local fp = v3(X(to), Y(to), Z(to))
    local ax, ay, az = qrot(fq, v3(1, 0, 0)), qrot(fq, v3(0, 1, 0)), qrot(fq, v3(0, 0, 1))
    local center = add(add(sub(fp, mul(az, dist)), mul(ax, xo)), mul(ay, yo))

    vr.get_pose((S.left_handed == true) and vr.get_left_controller_index() or vr.get_right_controller_index(), tp, tq)   -- (v6.6.49: the gun hand)
    local cq = { x = X(tq), y = Y(tq), z = Z(tq), w = W(tq) }
    local p = v3(X(tp), Y(tp), Z(tp))
    local a = math.rad(S.pointer_pitch)
    local d = qrot(cq, v3(0, math.sin(a), -math.cos(a)))
    local denom = dot(d, az)
    if math.abs(denom) < 1e-4 then pointer_inside = false; return end
    local t = dot(sub(center, p), az) / denom
    if t <= 0 then pointer_inside = false; return end
    local rel = sub(add(p, mul(d, t)), center)
    local vw, vh = viewport_size(pc)
    local u = dot(rel, ax) / (size * vw / vh) + 0.5
    local v = 0.5 - dot(rel, ay) / size
    local inside = u >= 0 and u <= 1 and v >= 0 and v <= 1
    if inside and not pointer_inside then haptic(1, 0.02, 0.2) end
    pointer_inside = inside
    V62.hand_px, V62.hand_py = u * vw, v * vh                  -- v6.6.51: where your hand points on the menu, in pixels
    if money_has then return end
    if inside then TRACE("SetMouseLocation"); pc:SetMouseLocation(math.floor(u * vw + 0.5), math.floor(v * vh + 0.5)); TRACE("idle") end
    if S.big_cursor then pcall(V62.cursor_overlay, inside or "hide", math.floor(u * vw + 0.5), math.floor(v * vh + 0.5)) end
end

---------------------------------------------------------------------------
-- 3: gun in right hand (mesh put directly on the controller-driven HoldArrow)
---------------------------------------------------------------------------
local hold = nil      -- the game's HoldArrow (tells us which gun is in hand)
track.hold_logged = false
local grip = nil      -- v4.7: our own right-hand point on the pawn - the game never moves it, so the muzzle
                      -- (and every shot) is always exactly where your hand is

local held_other = nil   -- v4.13: a non-gun item in the hand (knife, tool...) - class name, for the melee swing
track.seen_items = {}
local function find_active_weapon(pawn)
    local kids = safe(function() return pawn.Children end)
    if hold == nil or type(kids) ~= "table" then return nil end
    local other = nil
    for _, a in ipairs(kids) do
        local cls = shortclass(a)
        local root = nil
        if (cls:sub(1, 4) == "Wep_" or cls:sub(1, 9) == "MeleeWep_" or cls:sub(1, 4) == "Eqp_" or cls:sub(1, 5) == "Tool_" or cls:sub(1, 5) == "Gren_") and alive(a) then   -- v6.6.8: + grenades
            root = safe(function() return a.RootComponent end)
        end
        local parent = root and attach_parent(root)
        if parent ~= nil and same(parent, hold) then
            if cls:sub(1, 4) == "Wep_" then held_other = nil; return a, cls end
            other = cls
            if not track.seen_items[cls] then track.seen_items[cls] = true; LOG("item in hand (not a gun): " .. cls .. " - put on the hand like a gun") end
            held_other = cls
            return a, cls          -- v4.19: melee weapons / tools are taken onto the grip point too
        end
    end
    held_other = other
    return nil
end

-- WHERE THE HELD GUN BELONGS, and putting it there. Used by everything that holds the gun in the hand: after the game's
-- update (enforce_gun), in both eye passes before drawing (V62.gun_hold), when it is taken or its offset changes.
local function gs_ad(a, b) return math.abs(((a or 0) - b + 180) % 360 - 180) end
local function gun_want()                                    -- its place in the hand (lowered pose included), or nil
    local g = cur ~= nil and GUNS[cur.cls] or nil
    return g and V62.lowered(g) or nil
end
local function gun_off(g)                                    -- how far it is from that place: cm, degrees (plain reads)
    local rl, rr = cur.mesh.RelativeLocation, cur.mesh.RelativeRotation
    if rl == nil then return nil end
    return math.sqrt(((rl.X or 0) - g.x) ^ 2 + ((rl.Y or 0) - g.y) ^ 2 + ((rl.Z or 0) - g.z) ^ 2),
           rr ~= nil and math.max(gs_ad(rr.Pitch, g.pitch), gs_ad(rr.Yaw, g.yaw), gs_ad(rr.Roll, g.roll)) or 0
end
local function gun_put(g) set_rel(cur.mesh, g.x, g.y, g.z, g.pitch, g.yaw, g.roll) end
local function apply_gun()
    local g = gun_want()
    if g ~= nil then gun_put(g) end
end
local function gun_attach()                                  -- the held part onto our hand point, at its place in the hand
    pcall(UEVR_UObjectHook.remove_motion_controller_state, cur.mesh)   -- never let two systems move it (as for the hand points)
    cur.mesh:K2_AttachToComponent(grip or hold, G.NONE, 2, 2, 1, false)
    apply_gun()
end
function V62.muzzle(c)                                       -- a held gun's barrel arrow (its aim arrow if it has no muzzle arrow)
    c = c or cur
    if c == nil then return nil end
    return safe(function() return c.actor.Arrow_Muzzle end) or safe(function() return c.actor.Arrow_Aim end)
end

local function release_gun()
    if cur == nil then return end
    local c = cur
    cur = nil
    if alive(c.mesh) and alive(c.parent) then
        c.mesh:K2_AttachToComponent(c.parent, c.socket or G.NONE, 0, 0, 0, false)
        set_rel(c.mesh, c.rl.x, c.rl.y, c.rl.z, c.rr.p, c.rr.y, c.rr.r)
        LOG("gun back to the game: " .. c.cls)
    end
end

local function take_gun(actor, cls)
    local mesh = safe(function() return actor.Wep_Skeli end)
    if mesh == nil then
        -- v4.19: knife / pipe / tools have no gun skeleton: the whole item (its root) goes on the grip point
        mesh = safe(function() return actor.RootComponent end)
        if mesh == nil then LOG("no mesh on " .. cls); return end
    end
    local rl, rr = mesh.RelativeLocation, mesh.RelativeRotation
    cur = { actor = actor, mesh = mesh, cls = cls, parent = attach_parent(mesh),
        socket = safe(function() return mesh:GetAttachSocketName() end),
        rl = { x = rl.X, y = rl.Y, z = rl.Z }, rr = { p = rr.Pitch, y = rr.Yaw, r = rr.Roll } }
    if GUNS[cls] == nil then
        -- keep the angle the gun already has relative to HoldArrow; put its origin (grip area) at the hand
        local rel = safe(function() return G.KML:InverseTransformRotation(hold:K2_GetComponentToWorld(), mesh:K2_GetComponentRotation()) end)   -- same pose as grip
        -- v6.6.50: what is measured here is the game's hold pose AT THIS MOMENT, idle sway included: the same carbine,
        -- measured 16 times in a row, gave yaw -87.8 .. -90.2 and roll -1.4 .. 1.4, and the 60 guns measured on the test
        -- map all sit within 2.5 degrees of (0, -90, 0). So a measurement that close to that pose IS that pose: every
        -- install holds a gun the same way, and "forget my changes to this gun" gives the same result every time.
        -- Anything further off (tools, the binoculars) is kept as measured.
        local gp, gy, gr = rel and rel.Pitch or 0, rel and rel.Yaw or 0, rel and rel.Roll or 0
        local sway = math.abs(gp) < 3 and math.abs(gr) < 3 and gs_ad(gy, -90) < 3
        GUNS[cls] = { x = 0, y = 0, z = 0, pitch = sway and 0 or gp, yaw = sway and -90 or gy, roll = sway and 0 or gr, fitted = false }
        LOG(string.format("new gun %s, automatic angle %.1f %.1f %.1f%s", cls, GUNS[cls].pitch, GUNS[cls].yaw, GUNS[cls].roll,
            sway and string.format(" (measured %.1f %.1f %.1f: the game's own hold, idle sway taken out)", gp, gy, gr) or ""))
        save_settings()
    end
    gun_attach()
    cur.dn = safe(function()                                   -- v6.6.8: the in-game name (a string or an FName)
        local n = actor.DisplayName
        if type(n) == "string" then return n end
        if n ~= nil and n.to_string ~= nil then return n:to_string() end
        return n ~= nil and tostring(n) or nil
    end)
    if cur.dn == "None" or cur.dn == "" then cur.dn = nil end
    LOG("gun in right hand: " .. cls .. (cur.dn and (' ("' .. cur.dn .. '")') or "") .. (safe(function() return actor.Wep_Skeli end) ~= nil and " (its skeleton)" or " (whole item - no skeleton)"))   -- v6.6.41
    V62.gchk = { cls = cls, t = T + 0.4 }                      -- v6.6.14: measure the barrel against the hand
    if (S.binocular_mode or 0) == 1 then pcall(V62.scope_learn, actor, cls) end   -- (parked binoculars: the scope they borrow)
end
-- v6.6.14: where does the barrel sit relative to your hand? Logged once per gun ("gun geometry"). A barrel below the hand
-- or far to the side would mean the gun's origin isn't its grip: such a gun is moved once so the barrel runs just above
-- the hand. (Built for the Rusty Old Pistol, whose real trouble was UEVR's own attachment - v6.6.43. Every gun seen so
-- far, 21 classes, sits 7-11 cm above the hand and centred, so this has never had to act.)
V62.gseen = {}
function V62.gun_check(pawn)
    local c = V62.gchk
    if c == nil or T < c.t then return end
    V62.gchk = nil
    if cur == nil or cur.cls ~= c.cls or not alive(cur.mesh) or V62.watch.low == true or fit ~= nil then return end
    local g = GUNS[cur.cls]
    local gh = grip or hold
    if g == nil or not alive(gh) then return end
    local mz = V62.muzzle()
    if mz == nil then return end
    local ml, mr, hl = mz:K2_GetComponentLocation(), mz:K2_GetComponentRotation(), gh:K2_GetComponentLocation()
    local F, R, U = rot_axes(mr.Pitch or 0, mr.Yaw or 0, mr.Roll or 0)
    local vx, vy, vz = (ml.X or 0) - (hl.X or 0), (ml.Y or 0) - (hl.Y or 0), (ml.Z or 0) - (hl.Z or 0)
    local fwd = vx * F[1] + vy * F[2] + vz * F[3]
    local side = vx * R[1] + vy * R[2] + vz * R[3]
    local up = vx * U[1] + vy * U[2] + vz * U[3]
    if not V62.gseen[cur.cls] then
        V62.gseen[cur.cls] = true
        LOG(string.format("gun geometry %s: muzzle %.0f cm ahead of your hand, %.0f cm %s it, %.0f cm to the %s%s", cur.cls, fwd,
            math.abs(up), up >= 0 and "above" or "below", math.abs(side), side >= 0 and "right" or "left", g.fitted and " (fitted by hand)" or ""))
    end
    if S.gun_autofit == false or g.fitted or g.afit or fwd < 5 then return end
    if up >= -4 and up <= 22 and math.abs(side) <= 10 then return end
    local dU, dR = 7 - up, -side                               -- barrel 7 cm above the hand, centred
    local wx, wy, wz = U[1] * dU + R[1] * dR, U[2] * dU + R[2] * dR, U[3] * dU + R[3] * dR
    local lv = G.KML:InverseTransformDirection(gh:K2_GetComponentToWorld(), mkvec(wx, wy, wz))
    if lv == nil then return end
    g.x, g.y, g.z, g.afit = (g.x or 0) + (lv.X or 0), (g.y or 0) + (lv.Y or 0), (g.z or 0) + (lv.Z or 0), true
    save_settings()
    apply_gun()
    LOG(string.format("gun moved into your hand: %s (barrel was %.0f cm %s your hand, %.0f cm to the side) - offset now %.1f %.1f %.1f",
        cur.cls, math.abs(up), up >= 0 and "above" or "below", side, g.x, g.y, g.z))
end

local function start_fit()
    if cur == nil or not alive(cur.mesh) then return end
    local loc, rot = cur.mesh:K2_GetComponentLocation(), cur.mesh:K2_GetComponentRotation()
    cur.mesh:K2_DetachFromComponent(1, 1, 1)
    fit = { t = 8.0, buzz = 8.0, loc = { loc.X, loc.Y, loc.Z }, rot = { rot.Pitch, rot.Yaw, rot.Roll } }
    haptic(1, 0.2, 0.8)
    LOG("fit started: " .. cur.cls)
end

local function hold_fit_still()
    -- the game keeps animating the gun; pin it in the air while you put your hand on it
    if fit == nil or cur == nil or not alive(cur.mesh) then return end
    cur.mesh:K2_SetWorldLocationAndRotation(mkvec(fit.loc[1], fit.loc[2], fit.loc[3]), mkrot(fit.rot[1], fit.rot[2], fit.rot[3]),
        false, StructObject.new(G.Hit), true)
end

local function finish_fit()
    if cur == nil or not alive(cur.mesh) or (grip or hold) == nil then fit = nil; return end
    hold_fit_still()
    fit = nil
    cur.mesh:K2_AttachToComponent(grip or hold, G.NONE, 1, 1, 1, false)
    local rl, rr = cur.mesh.RelativeLocation, cur.mesh.RelativeRotation
    GUNS[cur.cls] = { x = rl.X, y = rl.Y, z = rl.Z, pitch = rr.Pitch, yaw = rr.Yaw, roll = rr.Roll, fitted = true }
    save_settings()
    haptic(1, 0.4, 1.0)
    LOG(string.format("fit saved %s: %.1f %.1f %.1f / %.1f %.1f %.1f", cur.cls, rl.X, rl.Y, rl.Z, rr.Pitch, rr.Yaw, rr.Roll))
end

-- every frame AFTER the game's own update: the game re-positions the gun (sway/aim animation, ~66 cm to the side);
-- put it back on our grip offset so it stays in your hand
track.enforce_logged = 0
local function enforce_gun()
    if fit ~= nil then hold_fit_still(); return end
    if cur == nil or not alive(cur.mesh) or not alive(cur.actor) then return end
    local g = gun_want()
    if g == nil then return end
    local dl, dr = gun_off(g)
    if dl == nil or (dl <= 0.05 and dr <= 0.05) then return end
    if dl > 0.05 and track.enforce_logged < 3 then
        track.enforce_logged = track.enforce_logged + 1
        local rl = cur.mesh.RelativeLocation
        LOG(string.format("game moved the gun to %.1f %.1f %.1f - putting it back in the hand", rl.X or 0, rl.Y or 0, rl.Z or 0))
    end
    gun_put(g)
end

track.gun_timer = 0
local function update_gun(pawn, delta)
    if fit ~= nil then
        fit.t = fit.t - delta
        if fit.t < fit.buzz - 1.0 then fit.buzz = fit.buzz - 1.0; haptic(1, 0.03, 0.3) end
        if fit.t <= 0 then finish_fit() end
        return
    end
    track.gun_timer = track.gun_timer - delta
    if track.gun_timer > 0 then return end
    track.gun_timer = 0.2
    if not S.gun_enabled then
        release_gun()
        if hold ~= nil and driven[addr(hold) or 0] then undrive(hold, "HoldArrow") end
        return
    end
    if hold == nil or not alive(hold) then
        -- v4.18: HoldArrow is only used to SEE which weapon is in hand - it is no longer moved by us. The crash tracer
        -- caught the game tearing a weapon down under it while we moved it (menu opening).
        hold = safe(function() return pawn.HoldArrow end)
        if hold == nil then return end
        if not track.hold_logged then track.hold_logged = true; LOG("HoldArrow (gun holder) left to the game; the gun rides on our own grip point") end
    end
    if grip == nil or not alive(grip) then
        grip = api:add_component_by_class(pawn, G.SceneClass, false)
        local root = safe(function() return pawn.RootComponent end)
        if grip ~= nil and root ~= nil then
            grip:K2_AttachToComponent(root, G.NONE, 2, 2, 2, false)
            drive(grip, 1, "right-hand grip point (our own)")
            if cur ~= nil then gun_attach() end
        else
            grip = nil
        end
    end
    local actor, cls = find_active_weapon(pawn)
    -- the game briefly moves the gun aside (quick menus, reload): keep it in the hand unless it's really gone
    if cur ~= nil and actor == nil and alive(cur.mesh) then
        cur.gone = (cur.gone or 0) + 0.2
        if cur.gone < 0.8 then return end
    elseif cur ~= nil then cur.gone = 0 end
    if cur ~= nil and (not alive(cur.mesh) or not same(cur.actor, actor)) then release_gun() end
    if cur == nil and actor ~= nil then take_gun(actor, cls) end
    if cur ~= nil and not same(attach_parent(cur.mesh), grip or hold) then
        gun_attach()
        LOG("gun taken back after the game moved it")
    end
end

---------------------------------------------------------------------------
-- 4: flashlight in left hand
---------------------------------------------------------------------------
local light = nil
local light_timer = 0

-- v4.13: melee swing (done in the joytokey plugin, which can press the attack button): tell it whether the item in
-- hand is a melee weapon - a gun has a muzzle arrow, a knife / crowbar has none
local melee_flag = nil
local function update_melee()
    local melee = false
    if cur ~= nil and alive(cur.mesh) then
        local mz = V62.muzzle()
        melee = (mz == nil)
    elseif held_other ~= nil then
        melee = true
    end
    if not S.melee_swing then melee = false end      -- v6.2: swing-to-melee off by default
    if melee ~= melee_flag then
        melee_flag = melee
        pcall(fs.write, "sf_melee.txt", melee and "1" or "0")
        LOG("melee swing " .. (melee and "ARMED (swing the right hand to attack)" or "off"))
    end
end

-- v6.6.2: guns without a usable fore-grip point: use a point 42% of the way from the right hand to the muzzle
function V62.virtual_foregrip(c)
    local mz = V62.muzzle(c)
    local gh = grip or hold
    if mz == nil or gh == nil then return nil end
    local m = safe(function() return mz:K2_GetComponentLocation() end)
    local g = safe(function() return gh:K2_GetComponentLocation() end)
    if m == nil or g == nil then return nil end
    local f = 0.42
    return { X = (g.X or 0) + ((m.X or 0) - (g.X or 0)) * f, Y = (g.Y or 0) + ((m.Y or 0) - (g.Y or 0)) * f,
             Z = (g.Z or 0) + ((m.Z or 0) - (g.Z or 0)) * f }
end
function V62.barrel_dist(c, ll)            -- v6.6.5: left hand vs the line right hand -> muzzle (long guns only)
    local mz = V62.muzzle(c)
    local gh = grip or hold
    if mz == nil or gh == nil or ll == nil then return nil end
    local m = safe(function() return mz:K2_GetComponentLocation() end)
    local g = safe(function() return gh:K2_GetComponentLocation() end)
    if m == nil or g == nil then return nil end
    local vx, vy, vz = (m.X or 0) - (g.X or 0), (m.Y or 0) - (g.Y or 0), (m.Z or 0) - (g.Z or 0)
    local L2 = vx * vx + vy * vy + vz * vz
    if L2 < 35 * 35 then return nil end                 -- shorter than 35 cm: a pistol - no two-handed grip there
    local wx, wy, wz = (ll.X or 0) - (g.X or 0), (ll.Y or 0) - (g.Y or 0), (ll.Z or 0) - (g.Z or 0)
    local t = math.max(0, math.min(1, (wx * vx + wy * vy + wz * vz) / L2))
    local px, py, pz = wx - vx * t, wy - vy * t, wz - vz * t
    local L = math.sqrt(L2)
    return math.sqrt(px * px + py * py + pz * pz), t * L, L
end
function V62.th_diag(c, fg, own, fl)      -- once per gun, the first time the left grip is held with it
    V62.thd = V62.thd or {}
    if V62.thd[c.cls] or not V62.lgrip_held() then return end
    V62.thd[c.cls] = true
    local why = own and "its own fore-grip point" or (fg == nil and "no fore-grip point on this gun"
        or ("its fore-grip point sits on another part (" .. shortclass(attach_parent(fg)) .. ")"))
    LOG("two-handed check " .. tostring(c.cls) .. ": " .. why .. ((not own) and (fl ~= nil and " - using a point 42% of the way to the muzzle" or " - and no muzzle point either: no two-handed grip") or ""))
end
-- v4.13: two-handed grip - left hand within reach of the gun's fore-grip takes hold of it
local function update_twohand(pawn)
    if not S.two_handed or cur == nil or not alive(cur.mesh) or not alive(cur.actor) or light == nil or not alive(light) then
        if twohand.on then twohand.on = false; twohand.m = nil; LOG("two-handed grip released") end
        return
    end
    local fg = safe(function() return cur.actor.Arrow_Forgrip end)
    local own = fg ~= nil and same(attach_parent(fg), cur.mesh)
    local fl = own and safe(function() return fg:K2_GetComponentLocation() end) or nil
    if fl == nil then own = false; fl = V62.virtual_foregrip(cur) end     -- v6.6.2: e.g. the battle rifle
    V62.th_diag(cur, fg, own, fl)
    if fl == nil then
        if twohand.on then twohand.on = false; twohand.m = nil end
        return
    end
    local ll = safe(function() return light:K2_GetComponentLocation() end)
    if fl == nil or ll == nil then return end
    local d = math.sqrt(((fl.X or 0) - (ll.X or 0)) ^ 2 + ((fl.Y or 0) - (ll.Y or 0)) ^ 2 + ((fl.Z or 0) - (ll.Z or 0)) ^ 2)
    local gh = grip or hold
    local gl = gh and safe(function() return gh:K2_GetComponentLocation() end)
    local dg = gl and math.sqrt(((fl.X or 0) - (gl.X or 0)) ^ 2 + ((fl.Y or 0) - (gl.Y or 0)) ^ 2 + ((fl.Z or 0) - (gl.Z or 0)) ^ 2) or 0
    local hold_ok = (not S.twohand_hold) or V62.lgrip_held()     -- v6.2: only while the left grip is held
    local bl, along, glen = V62.barrel_dist(cur, ll)                -- v6.6.5: anywhere along the front of the gun
    if bl ~= nil then
        if hold_ok and not twohand.on then
            V62.thm = V62.thm or { cls = cur.cls, min = 999 }
            if bl < V62.thm.min then V62.thm.min, V62.thm.al = bl, along end   -- v6.6.8: closest point, wherever along
        end
        if not hold_ok and V62.thm ~= nil then
            local mcls, mmin, mal = V62.thm.cls, V62.thm.min, V62.thm.al or 0
            V62.thm = nil
            V62.thmiss = V62.thmiss or {}
            if not V62.thmiss[mcls] and not (V62.thg or {})[mcls] then
                V62.thmiss[mcls] = true
                LOG(string.format("two-handed: left grip held on %s%s but no grab - closest your left hand came to the barrel: %.0f cm, %.0f cm out from your right hand (needs under 15 cm, over 15 cm out)", mcls, (cur and cur.dn) and (' "' .. cur.dn .. '"') or "", mmin, mal))
            end
        end
    end
    local grab = (bl ~= nil and bl < 15 and along > 15) or (bl == nil and d < 22 and dg > 24)
    if bl ~= nil then d = bl end
    if not twohand.on and hold_ok and grab then     -- long guns only (v6.6.5: anywhere along the barrel)
        -- muzzle direction in the grip's own axes (so the two-handed pose keeps the gun's fitted angle)
        local mz = V62.muzzle()
        local mr = mz and safe(function() return mz:K2_GetComponentRotation() end)
        local gr = gh and safe(function() return gh:K2_GetComponentRotation() end)
        if mr ~= nil and gr ~= nil then
            local MF = rot_axes(mr.Pitch or 0, mr.Yaw or 0, mr.Roll or 0)
            local F, R, U = rot_axes(gr.Pitch or 0, gr.Yaw or 0, gr.Roll or 0)
            twohand.m = { MF[1] * F[1] + MF[2] * F[2] + MF[3] * F[3], MF[1] * R[1] + MF[2] * R[2] + MF[3] * R[3], MF[1] * U[1] + MF[2] * U[2] + MF[3] * U[3] }
            twohand.on = true
            haptic(0, 0.04, 0.6); haptic(1, 0.04, 0.6)
            twohand.log = twohand.log + 1
            V62.thg = V62.thg or {}
            if twohand.log <= 3 or not V62.thg[cur.cls] then LOG(string.format("two-handed grip: left hand on %s%s (%.0f cm from the barrel%s)", cur.cls, cur.dn and (' "' .. cur.dn .. '"') or "", d, along and string.format(", %.0f cm along a %.0f cm gun", along, glen) or "")) end
            V62.thm = nil
            V62.thg[cur.cls] = true
        end
    elseif twohand.on and (not hold_ok or d > (S.twohand_hold and 45 or 32)) then
        twohand.on = false; twohand.m = nil
        haptic(0, 0.03, 0.3)
        if twohand.log <= 6 then twohand.log = twohand.log + 1; LOG("two-handed grip released (" .. (hold_ok and "hand too far" or "left grip let go") .. ")") end
    end
end

local function update_light(pawn, delta)
    light_timer = light_timer - delta
    if light_timer > 0 then return end
    light_timer = 0.5
    if not S.flashlight_left_hand then
        -- v6.6.8: the game's flashlight is left on the head; the left hand gets our own point (two-handed grip uses it)
        if light ~= nil and light ~= V62.lh then undrive(light, "flashlight"); light = nil end
        -- v6.6.12: also made again if it isn't ours to move any more or belongs to a previous body (a level load kept the
        -- old one alive once - the two-handed grip then measured a hand left behind in the previous level)
        local lho = V62.lh ~= nil and safe(function() return V62.lh:GetOwner() end) or nil
        if V62.lh == nil or not alive(V62.lh) or driven[addr(V62.lh) or 0] == nil or (lho ~= nil and not same(lho, pawn)) then
            if V62.lh ~= nil then V62.lhn = (V62.lhn or 0) + 1; if V62.lhn <= 6 then LOG("left-hand point: the old one belonged to a previous body - making a new one") end end
            V62.lh = nil
            local root = safe(function() return pawn.RootComponent end)
            local g = api:add_component_by_class(pawn, G.SceneClass, false)
            if g == nil or root == nil then light = nil; return end
            g:K2_AttachToComponent(root, G.NONE, 2, 2, 2, false)
            V62.lh = g
            drive(g, 0, "left-hand point (our own)")
        end
        light = V62.lh
        return
    end
    if light ~= nil and alive(light) and driven[addr(light) or 0] then return end
    light = safe(function() return pawn.FlashLight_Source_BP end)
    if light ~= nil then drive(light, 0, "flashlight", S.light_x, S.light_y, S.light_z) end
end

---------------------------------------------------------------------------
-- 4b: v4.9 HEAD HUD - the game's HUD widget on a panel that floats in front of your eyes (placed per eye in
--     place_hands). Its centre is the game's reticle / "you can use this" ring, so it now marks exactly what Y / RB act on.
--     (4.7/4.8 hung it on the left wrist: only the centre ring ever shows, so it looked like a tiny dot near your hand.)
--     UEVR's own UI layer stays empty in this game, so without this the HUD is never visible in VR.
---------------------------------------------------------------------------
local wrist = nil   -- { comp, hud, checks, dumped }
local wrist_timer, wrist_readds = 0, 0

local function find_hud()
    -- v6.0: the body keeps a reference to ITS HUD (pawn.HUD) - use that, so after a level load we can never grab the
    -- previous level's dying HUD widget (the old scan returned the first HUD_Widget_C it found)
    local pawn = api:get_local_pawn(0)
    local own = pawn and safe(function() return pawn.HUD end)
    if own ~= nil and obj_ok(own) and alive(own) then return own end
    local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(G.UserWidget, false) end)
    if type(all) ~= "table" then return nil end
    for _, w in ipairs(all) do
        if shortclass(w) == "HUD_Widget_C" and not fullname(w):find("Default__") then return w end
    end
    return nil
end

-- (v6: unused place_wrist stub removed)

local function remove_wrist(reason)
    hudp.comp = nil
    hudp.shown_ref = nil
    if wrist == nil then return end
    local w = wrist
    wrist = nil
    if alive(w.comp) then
        pcall(function() w.comp:SetWidget(nil) end)
        pcall(function() w.comp:SetVisibility(false, false) end)
    end
    -- The HUD widget is not handed back to the flat screen here: this only runs when UEVR resets its scripts, and the
    -- reloaded script takes the HUD onto a new panel within a second. (Its AddToViewport cannot be called from this
    -- script anyway - the script watches that function, see V62.hook_loading.)
    LOG("HUD panel removed (" .. reason .. ")")
end

-- one-time list of what the HUD contains (so the next step can be based on facts)
local function dump_widget(w, depth, n)
    if w == nil or n.c >= 150 then return end
    n.c = n.c + 1
    local name = fullname(w):match("([^%.:]+)$") or "?"
    if n.found ~= nil then n.found[name] = w end
    if not n.quiet then                                         -- v6.6.43: quiet = only collect the parts by name
        LOG(string.rep("  ", depth + 1) .. shortclass(w) .. " '" .. name .. "' vis=" .. tostring(safe(function() return w:GetVisibility() end))
            .. " opacity=" .. string.format("%.2f", safe(function() return w:GetRenderOpacity() end) or -1))
    end
    local cnt = safe(function() return w:GetChildrenCount() end)
    if type(cnt) == "number" then
        for i = 0, math.min(cnt, 40) - 1 do dump_widget(safe(function() return w:GetChildAt(i) end), depth + 1, n) end
    end
    local root = safe(function() return w.WidgetTree.RootWidget end)
    if root ~= nil then dump_widget(root, depth + 1, n) end
end

local function update_wrist(pawn, delta)
    wrist_timer = wrist_timer - delta
    if wrist_timer > 0 then return end
    wrist_timer = 0.5
    if not S.wrist_hud then if wrist ~= nil then remove_wrist("switched off") end; return end
    if G.WidgetComp == nil or G.Vec2 == nil or G.UserWidget == nil then return end
    if wrist ~= nil then
        if not alive(wrist.comp) or not alive(wrist.hud) then wrist = nil; hudp.comp = nil; if hudp.rcomp == nil then hudp.ring = nil end
        elseif (TRACE("IsInViewport") or safe(function() return wrist.hud:IsInViewport() end)) == true then
            -- the game put the HUD back on the flat screen: never host it in two places at once
            pcall(function() wrist.comp:SetWidget(nil) end)
            wrist = nil
            hudp.comp = nil
            wrist_readds = wrist_readds + 1
            wrist_timer = 10.0                        -- back off: don't fight the game
            LOG("game re-added the HUD to the screen - HUD panel released (" .. wrist_readds .. ")")
            return
        else
            -- v4.11: health / ammo / compass showing right now? (the game collapses them when not needed)
            local info = false
            for _, iw in ipairs(wrist.info or {}) do
                local v = safe(function() return iw:GetVisibility() end)
                if v == 0 or v == 3 or v == 4 then info = true; break end
            end
            hudp.info = info
            if not wrist.dumped then
                wrist.dumped = true
                local n = { c = 0, found = {}, quiet = V62.hud_listed == true }   -- v6.6.43: listed once per session (was: every level)
                if not n.quiet then LOG("HUD contents:") end
                pcall(dump_widget, wrist.hud, 0, n)
                wrist.info = {}
                for _, nm in ipairs({ "HorizontalBox_HealthBar", "Compass", "VerticalBox_AmmoDisplay", "HorizontalBox_ShieldBar", "TextBlock_EatherCounter" }) do
                    if n.found[nm] ~= nil then wrist.info[#wrist.info + 1] = n.found[nm] end
                end
                hudp.ring = n.found["Image_Interactable"]                                 -- v6.6.28: the aiming ring
                hudp.cross = n.found["Image_Crosshair"]                                   -- v6.6.30: the game's ADS crosshair
                if hudp.ring == nil then LOG("HUD: no aiming ring (Image_Interactable) found - it stays where the HUD is") end
                if not n.quiet then LOG("HUD contents: " .. n.c .. " widgets listed") end
                V62.hud_listed = true
            end
            if wrist.checks < 2 then
                wrist.checks = wrist.checks + 1
                local l = safe(function() return wrist.comp:K2_GetComponentLocation() end)
                LOG(string.format("HUD check: panel at %s, %.0f cm in front of your eyes, scale %.4f, visible=%s, material=%s",
                    l and string.format("%.0f %.0f %.0f", l.X or 0, l.Y or 0, l.Z or 0) or "?", hudp.dist, hudp.scale,
                    tostring(safe(function() return wrist.comp:IsVisible() end)), fullname(safe(function() return wrist.comp:GetMaterial(0) end))))
            end
            return
        end
    end
    if wrist_readds >= 3 then return end                   -- the game keeps reclaiming it on this level: give up quietly
    local hud = find_hud()
    if hud == nil then wrist_timer = 3.0; return end        -- v4.10: object scans are costly - look again in 3 s
    local root = safe(function() return pawn.RootComponent end)
    if root == nil then return end
    local comp = api:add_component_by_class(pawn, G.WidgetComp, false)
    if comp == nil then LOG("HUD: could not create panel"); return end
    comp:K2_AttachToComponent(root, G.NONE, 2, 2, 2, false)
    pcall(function() comp:SetWidgetSpace(0) end)
    local ds = StructObject.new(G.Vec2); ds.X, ds.Y = 1920, 1080
    pcall(function() comp:SetDrawSize(ds) end)
    pcall(function() comp:SetTwoSided(true) end)
    pcall(function() comp:SetBlendMode(2) end)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetHiddenInGame(false, false) end)
    pcall(function() comp:SetOwnerNoSee(false) end)
    pcall(function() comp:SetOnlyOwnerSee(false) end)
    pcall(function() comp:SetManuallyRedraw(false) end)
    pcall(function() comp:SetDrawAtDesiredSize(false) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetComponentTickEnabled(true) end)
    if G.LinColor ~= nil then
        local c = StructObject.new(G.LinColor)
        c.R, c.G, c.B, c.A = 0, 0, 0, 0                        -- fully see-through: only the HUD itself shows
        pcall(function() comp:SetBackgroundColor(c) end)
    end
    hud:RemoveFromParent()
    comp:SetWidget(hud)
    pcall(V62.hud_unhide, "on its VR panel")                   -- v6.6.43: hidden since the game added it during the load
    pcall(function() comp:SetVisibility(true, false) end)
    wrist = { comp = comp, hud = hud, checks = 0, shown = false }
    hudp.shown_ref = wrist
    hudp.scale = 0
    hudp.dist = 150
    hudp.comp = comp
    LOG("HUD on (floats in front of your eyes): " .. fullname(hud))
end

-- v6.6.29: THE AIMING RING ON ITS OWN PANEL. The HUD's interaction ring (Image_Interactable) is moved out of the game's
-- HUD widget into a small widget of our own, hosted by a second WidgetComponent that sits where your hand points (as the
-- whole HUD did before the head HUD). The game keeps its reference to the Image, so it still shows / hides it.
local function make_ring_panel(pawn)
    if S.hud_ring_separate == false or hudp.rcomp ~= nil or hudp.ring == nil or not alive(hudp.ring) then return end
    if hudp.rtry ~= nil and T < hudp.rtry then return end
    hudp.rtry = T + 3.0
    if V62.wbl == nil then local c = api:find_uobject("Class /Script/UMG.WidgetBlueprintLibrary"); V62.wbl = c and c:get_class_default_object() end
    local pc = api:get_player_controller(0)
    if V62.wbl == nil or pc == nil or G.WidgetComp == nil or G.Vec2 == nil then return end
    local function fail(why) hudp.rfail = (hudp.rfail or 0) + 1; if hudp.rfail <= 3 then LOG("HUD ring: own panel not possible (" .. why .. ") - the ring stays in the HUD") end end
    local w, root = nil, nil
    local ok, r = pcall(function() return V62.wbl:Create(pawn, G.UserWidget, pc) end)
    if ok and r ~= nil then
        w = r
        local tree = safe(function() return w.WidgetTree end)
        if tree ~= nil then
            root = safe(function() return tree.RootWidget end)
            if root == nil then
                local cc = api:find_uobject("Class /Script/UMG.CanvasPanel")
                local canvas = cc and safe(function() return api:spawn_object(cc, tree) end)
                if canvas ~= nil then pcall(function() tree.RootWidget = canvas end); root = safe(function() return tree.RootWidget end) end
            end
        end
    end
    if root == nil then                                            -- fallback: the game's own cursor widget (a canvas root)
        if V62.cur_cls == nil then V62.cur_cls = api:find_uobject("WidgetBlueprintGeneratedClass /Game/Classes/GUI/New/Components/CursorWidget.CursorWidget_C") end
        local ok2, r2 = pcall(function() return V62.wbl:Create(pawn, V62.cur_cls, pc) end)
        if ok2 and r2 ~= nil then
            w = r2
            root = safe(function() return w.WidgetTree.RootWidget end)
            if root ~= nil then
                local n = safe(function() return root:GetChildrenCount() end) or 0
                for i = 0, n - 1 do pcall(function() root:GetChildAt(i):SetVisibility(1) end) end   -- its own picture away
            end
        end
    end
    if w == nil or root == nil then fail("no widget to hold it"); return end
    if (safe(function() return shortclass(root) end) or "") ~= "CanvasPanel" then fail("holder is not a canvas") end
    local ring = hudp.ring
    -- The ring's image is white; its orange in the flat game comes from the RetainerBox effect material around the HUD,
    -- which comes out white on a panel in the world (v6.6.32). So the ring gets a plain tint (hud_ring_r / g / b).
    local okm, e = pcall(function()
        ring:RemoveFromParent()
        -- v6.6.41: ring and dot centred on each other in an Overlay (in a canvas both sat at the top-left corner)
        local want_dot = hudp.cross ~= nil and alive(hudp.cross) and (S.pointer_dot ~= false or S.hud_ads_crosshair == true)
        local ov = nil
        if want_dot then
            local oc = api:find_uobject("Class /Script/UMG.Overlay")
            local tree = safe(function() return w.WidgetTree end)
            ov = oc and tree and safe(function() return api:spawn_object(oc, tree) end)
        end
        if ov ~= nil then
            local slot = root:AddChildToCanvas(ov)
            if slot ~= nil then pcall(function() slot:SetAutoSize(true) end); pcall(function() slot:SetPosition(V62.v2(0, 0)) end) end
            for _, img in ipairs({ ring, hudp.cross }) do
                if img ~= hudp.cross or want_dot then
                    pcall(function() img:RemoveFromParent() end)
                    local os = ov:AddChildToOverlay(img)
                    if os ~= nil then pcall(function() os:SetHorizontalAlignment(2) end); pcall(function() os:SetVerticalAlignment(2) end) end
                end
            end
            hudp.dot_in = true
        else
            local slot = root:AddChildToCanvas(ring)
            if slot ~= nil then
                pcall(function() slot:SetAutoSize(true) end)
                pcall(function() slot:SetPosition(V62.v2(0, 0)) end)
            end
            if want_dot then
                hudp.cross:RemoveFromParent()
                local s2 = root:AddChildToCanvas(hudp.cross)
                if s2 ~= nil then pcall(function() s2:SetAutoSize(true) end); pcall(function() s2:SetPosition(V62.v2(0, 0)) end) end
                hudp.dot_in = true
            end
        end
        if hudp.dot_in then hudp.dot_scale = nil end
    end)
    if not okm then fail("could not move the ring (" .. tostring(e) .. ")"); return end
    pcall(function()
        local c = StructObject.new(G.LinColor)
        c.R, c.G, c.B, c.A = S.hud_ring_r or 1.0, S.hud_ring_g or 0.16, S.hud_ring_b or 0.0, 1.0
        hudp.ring_col = string.format("tint %.2f %.2f %.2f", c.R, c.G, c.B)
        w:SetColorAndOpacity(c)
    end)
    local rootc = safe(function() return pawn.RootComponent end)
    local comp = api:add_component_by_class(pawn, G.WidgetComp, false)
    if comp == nil or rootc == nil then fail("no panel"); return end
    comp:K2_AttachToComponent(rootc, G.NONE, 2, 2, 2, false)
    pcall(function() comp:SetWidgetSpace(0) end)
    pcall(function() comp:SetTwoSided(true) end)
    -- v6.6.45: 1 = masked (solid where the picture is, nothing elsewhere): drawn with the solid world, so it has motion
    -- vectors and the anti-aliasing can follow it. 2 = see-through (as before): no motion vectors - TSR smeared the dot
    -- along its path whenever the hand or the player moved.
    pcall(function() comp:SetBlendMode(S.pointer_solid ~= false and 1 or 2) end)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetDrawAtDesiredSize(true) end)
    pcall(function() comp:SetComponentTickEnabled(true) end)
    if G.LinColor ~= nil then
        local c = StructObject.new(G.LinColor); c.R, c.G, c.B, c.A = 0, 0, 0, 0
        pcall(function() comp:SetBackgroundColor(c) end)
    end
    comp:SetWidget(w)
    pcall(function() comp:SetVisibility(true, false) end)
    hudp.rcomp, hudp.rw, hudp.ring_sep, hudp.rscale = comp, w, true, 0
    if not V62.solid_logged then
        V62.solid_logged = true
        local m0 = safe(function() return comp:GetMaterial(0) end)                 -- (which widget material the engine picked)
        local par = m0 and safe(function() return m0.Parent end)
        LOG("HUD: the dot / ring panel is drawn " .. (S.pointer_solid ~= false and "solid (no ghost trail)" or "see-through (as before v6.6.45)") .. " - material " .. fullname(par or m0))
    end
    LOG("HUD: the aiming ring" .. (hudp.dot_in and (S.pointer_dot ~= false and " and the pointer dot (always on) have" or " and the ADS crosshair (LT) have") or " has") .. " its own panel where your hand points (colour: " .. tostring(hudp.ring_col) .. "); the HUD stays in front of your eyes")
end
function V62.ring_panel_update(pawn)                          -- v6.6.29 (every tick)
    if hudp.rcomp ~= nil and not alive(hudp.rcomp) then hudp.rcomp, hudp.rw, hudp.ring_sep = nil, nil, false end
    if hudp.ring ~= nil and hudp.rcomp == nil then pcall(make_ring_panel, pawn) end
    -- v6.6.41: the pointer dot: the game's crosshair image, kept visible (the game shows it only on LT) and scaled
    if S.pointer_dot ~= false and hudp.dot_in and hudp.cross ~= nil and alive(hudp.cross) and hudp.rcomp ~= nil then
        local v = safe(function() return hudp.cross:GetVisibility() end)
        if v ~= 4 then pcall(function() hudp.cross:SetVisibility(4) end) end
        local sz = S.pointer_dot_size or 1.5
        if hudp.dot_scale ~= sz then hudp.dot_scale = sz; pcall(function() hudp.cross:SetRenderScale(V62.v2(sz, sz)) end) end
    end
    -- v6.6.32: with the dot off, the game's ADS crosshair (the small dot it shows on LT when the aim lands on something)
    -- is taken out of every widget tree: the game keeps showing/hiding it, but it is drawn nowhere.
    if S.pointer_dot == false and S.hud_ads_crosshair ~= true and hudp.cross ~= nil and not hudp.cross_off and alive(hudp.cross) then
        hudp.cross_off = true
        pcall(function() hudp.cross:RemoveFromParent() end)
        if not hudp.cross_logged then hudp.cross_logged = true; LOG("HUD: the game's ADS crosshair (the small dot on LT) is off - the aiming ring marks the aim") end
    end
end
-- 4c (v4.10): RIGHT-HAND POINTER - what Y (interact) and RB (pick up) act on is where your right hand / gun points.
--     We trace from the hand along the barrel, then aim the game's camera from the head at that exact spot, so the
--     game's own "what am I looking at" check lands on the same thing. The HUD ring is drawn there too.
---------------------------------------------------------------------------
local ptr = { hit = nil, col = nil, logged = false, errs = 0, t = 0 }

local function hand_ray()
    -- v4.11: your right CONTROLLER (not the gun's muzzle): a long barrel poking into a box no longer matters
    local gh = grip or hold
    if gh ~= nil and alive(gh) then
        local l = safe(function() return gh:K2_GetComponentLocation() end)
        local r = safe(function() return gh:K2_GetComponentRotation() end)
        if l ~= nil and r ~= nil then
            -- v6.6.9: holding a gun: aim along the BARREL line (where its laser goes), starting level with the hand
            -- v6.6.14: a LOWERED gun points at the floor - the pointer comes from your hand then
            local mz = V62.watch.low ~= true and cur ~= nil and alive(cur.actor) and (V62.muzzle()) or nil
            local ml = mz and safe(function() return mz:K2_GetComponentLocation() end)
            local mr = mz and safe(function() return mz:K2_GetComponentRotation() end)
            if mz ~= nil and V62.rk ~= nil and V62.rk.t0 ~= nil then          -- v6.6.15: aim ignores the visual kick
                local a, b = V62.rest_muzzle(gh)
                if a ~= nil then ml, mr = a, b end
            end
            if ml ~= nil and mr ~= nil then
                local F = rot_axes(mr.Pitch or 0, mr.Yaw or 0, 0)
                local hx, hy, hz = (l.X or 0) - (ml.X or 0), (l.Y or 0) - (ml.Y or 0), (l.Z or 0) - (ml.Z or 0)
                local t = hx * F[1] + hy * F[2] + hz * F[3]                 -- how far behind the muzzle your hand is
                local off2 = (hx - F[1] * t) ^ 2 + (hy - F[2] * t) ^ 2 + (hz - F[3] * t) ^ 2
                if t < 0 and off2 < 30 * 30 then                            -- a sane barrel: in front of the hand, close to it
                    if not V62.barrel_ptr_logged then V62.barrel_ptr_logged = true; LOG(string.format("aiming dot follows the gun barrel (barrel line %.0f cm from your hand)", math.sqrt(off2))) end
                    return { X = (ml.X or 0) + F[1] * t, Y = (ml.Y or 0) + F[2] * t, Z = (ml.Z or 0) + F[3] * t }, mr
                end
            end
            return l, r
        end
    end
    return nil, nil
end

-- v6.6.45: TWO-HANDED, THE POINTER FOLLOWS YOUR RIGHT HAND. With the left hand on the gun the barrel runs from hand to
-- hand, and the pointer (dot, what you pick up / use) followed it: to pick something up you had to aim the rifle at
-- it, and the dot was a free laser sight in a firefight. Now the pointer runs where the gun WOULD point from the right
-- hand alone (the direction the two-handed code starts from) - turn the wrist and the dot moves, the gun does not.
-- Shots are not changed: while a trigger is held the game's aim goes to the barrel's own point (hudp.PB).
function V62.free_hand_ray()
    local f = V62.thf
    if S.twohand_hand_pointer == false or not twohand.on or f == nil or T - f.t > 0.25 or V62.watch.low == true then return nil end
    local gh = grip or hold
    local l = gh ~= nil and alive(gh) and safe(function() return gh:K2_GetComponentLocation() end) or nil
    if l == nil then return nil end
    local d = f.d
    return l, { Pitch = math.deg(math.asin(math.max(-1, math.min(1, d[3])))), Yaw = math.deg(math.atan(d[2], d[1])), Roll = 0 }
end

-- v4.11: the HUD (and its ring) only shows when there is something to use, or when the game shows health / ammo -
-- a permanent dot where the gun points would be a free laser sight
local function hud_visibility(pawn)
    if wrist == nil or not alive(wrist.comp) then return end
    local can = (not menu_mode) and safe(function() return pawn.CanInteract end) == true
    local want = (not menu_mode) and lvl.ready and view.ok ~= false and (can or hudp.info == true)   -- v6.6.26: not while loading
    if wrist.shown ~= want then
        wrist.shown = want                    -- v4.16: applied as the panel's scale in the per-eye placement (no
        hudp.scale = 0                        -- widget visibility calls while the game may be rebuilding its UI)
    end
end

local function held_object(pawn)
    local ph = safe(function() return pawn.PhysicsHandle end)
    local gc = ph and safe(function() return ph:GetGrabbedComponent() end)
    return gc
end

-- v6.2: actors the pointer ray must pass through: you, and EVERYTHING attached to you (weapon, off-hand item, the
-- flashlight's own actor, inventory preview copies...). The left-hand flashlight in the beam was steering your walk.
function V62.ignore_list(pawn)
    if V62.ign ~= nil and same(V62.ign_pawn, pawn) and T < (V62.ign_t or 0) and T >= quiet_until then return V62.ign end
    local l, seen = { pawn }, {}
    seen[addr(pawn) or 0] = true
    local function add(a)
        if a == nil or not alive(a) then return end
        local k = addr(a)
        if k ~= nil and not seen[k] then seen[k] = true; l[#l + 1] = a end
    end
    local kids = safe(function() return pawn.Children end)
    if type(kids) == "table" then for _, a in ipairs(kids) do add(a) end end
    if cur ~= nil then add(cur.actor) end
    add(offh.actor)
    if light ~= nil then add(safe(function() return light.ChildActor end)) end
    V62.ign, V62.ign_pawn, V62.ign_t = l, pawn, T + 0.25
    if not V62.ign_logged then V62.ign_logged = true; LOG("pointer ignores you and " .. (#l - 1) .. " things you carry") end
    return l
end
local swing = { last = nil, t = 0, hold = 0 }
local function update_pointer(pawn)
    hud_visibility(pawn)
    if menu_mode then return end
    hudp.PB = nil                                               -- v6.6.45: the barrel's own point, only set when it differs from the pointer
    local l, r = hand_ray()
    if l == nil then hudp.P = nil; return end
    -- v4.14: melee: a swing is aimed where the hand pointed as it STARTED (by the end of a downward swing the hand
    -- points somewhere else entirely) - the aim spot is held for 0.4 s once the hand moves faster than 1.5 m/s
    if melee_flag == true then
        local now = T
        if swing.last ~= nil and now > swing.t then
            local dx, dy, dz = (l.X or 0) - swing.last[1], (l.Y or 0) - swing.last[2], (l.Z or 0) - swing.last[3]
            local sp = math.sqrt(dx * dx + dy * dy + dz * dz) / 100 / (now - swing.t)
            if sp > 1.5 and now > swing.hold then swing.hold = now + 0.4 end
        end
        swing.last = { l.X or 0, l.Y or 0, l.Z or 0 }; swing.t = now
        if T < swing.hold and hudp.P ~= nil then return end   -- keep the aim spot from the start of the swing
    end
    G.KSys = G.KSys or (function() local c = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"); return c and c:get_class_default_object() end)()
    local F = rot_axes(r.Pitch or 0, r.Yaw or 0, 0)
    local ox, oy, oz = l.X or 0, l.Y or 0, l.Z or 0
    -- v4.11: carrying something (Y on a loose object): it should sit just in front of your hand, not fly off to
    -- wherever the pointer lands (the old trace hit the carried object itself -> jitter)
    local held = held_object(pawn)
    if held ~= nil then
        if not ptr.held_logged then ptr.held_logged = true; LOG("carrying an object: it now follows your right hand") end
        -- v6.6.47: two-handed, hand_ray() above is the BARREL (it runs from hand to hand) - what you carry went where
        -- the rifle pointed. Like the pointer since v6.6.45, it follows the right hand's own direction.
        local cl, cr = V62.free_hand_ray()
        if cl ~= nil then
            ox, oy, oz = cl.X or 0, cl.Y or 0, cl.Z or 0
            F = rot_axes(cr.Pitch, cr.Yaw, 0)
            if not V62.thc_logged then V62.thc_logged = true; LOG("two-handed: what you carry follows your right hand too (not the barrel)") end
        end
        local cd = S.carry_far_aim and 1500 or 45          -- v6.6.12: far = the aim runs parallel to your hand
        hudp.P = { ox + F[1] * cd, oy + F[2] * cd, oz + F[3] * cd }
        return
    end
    local reach = (cur ~= nil and V62.watch.low ~= true) and 20000 or 600   -- v6.6.14: a gun aims out to 200 m
    local function spot(ox, oy, oz, F)                          -- where a ray from there along F ends: what it hits, else its full reach
        local ex, ey, ez = ox + F[1] * reach, oy + F[2] * reach, oz + F[3] * reach
        local px, py, pz = ex, ey, ez
        if G.KSys ~= nil then
            ptr.hit = ptr.hit or StructObject.new(G.Hit)
            if ptr.col == nil and G.LinColor ~= nil then ptr.col = StructObject.new(G.LinColor) end
            local ignore = V62.ignore_list(pawn)
            local ok, hit = pcall(function()
                return G.KSys:LineTraceSingle(pawn, mkvec(ox, oy, oz), mkvec(ex, ey, ez), 0, false, ignore, 0, ptr.hit, true, ptr.col, ptr.col, 0.0)
            end)
            if ok and hit == true then
                local d = safe(function() return ptr.hit.Distance end)
                if type(d) == "number" and d > 0 then px, py, pz = ox + F[1] * d, oy + F[2] * d, oz + F[3] * d end
            elseif not ok then
                ptr.errs = ptr.errs + 1
                if ptr.errs <= 3 then LOG("pointer trace failed: " .. tostring(hit)) end
            end
        end
        return px, py, pz
    end
    local px, py, pz = spot(ox, oy, oz, F)
    local fl, fr = V62.free_hand_ray()                          -- v6.6.45: two-handed -> the right hand's own direction
    if fl ~= nil then
        hudp.PB = { px, py, pz }                                -- where the BARREL points: shots and the red dot
        px, py, pz = spot(fl.X or 0, fl.Y or 0, fl.Z or 0, rot_axes(fr.Pitch, fr.Yaw, 0))
        if not V62.thf_logged then V62.thf_logged = true; LOG("two-handed: the dot and what you pick up follow your right hand; with a trigger held the game's aim goes where the barrel points") end
    end
    hudp.P = { px, py, pz }
    if not ptr.logged then
        ptr.logged = true
        LOG(string.format("right-hand pointer on: hand at %.0f %.0f %.0f, pointing at %.0f %.0f %.0f", ox, oy, oz, px, py, pz))
    end
end

-- aim the game's camera (from wherever the game has it) at the spot the hand points at
local function pointer_rotation(pawn, barrel)
    local P = (barrel and hudp.PB) or hudp.P
    if P == nil then return nil end
    local cam = safe(function() return pawn.Camera end)
    local c = cam and safe(function() return cam:K2_GetComponentLocation() end)
    if c == nil then return nil end
    local dx, dy, dz = P[1] - (c.X or 0), P[2] - (c.Y or 0), P[3] - (c.Z or 0)
    if dx * dx + dy * dy + dz * dz < 1 then return nil end
    return math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), math.deg(math.atan(dy, dx))
end

---------------------------------------------------------------------------
-- 4d (v4.10): LADDERS / CHAINS - the game climbs with its own Move input (W/S "regardless of where you face").
--     Our analog walking doesn't send W/S, so on a ladder the left stick is handed to the game's Move action directly.
---------------------------------------------------------------------------
local inj = { tried = false, fn = nil, move = nil, cls = nil, sub = nil, logged = false, errs = 0 }
-- v6.0: generic version - send any of the game's 32 input actions (IA_*) straight into Enhanced Input
local IAX = { cache = {} }
function IAX.get(name)
    local a = IAX.cache[name]
    if a == nil then
        a = api:find_uobject("InputAction /Game/Classes/Player/Player_Inputs/" .. name .. "." .. name) or false
        IAX.cache[name] = a
        if not a then LOG("input action not found: " .. name) end
    end
    return a or nil
end
local inject_move   -- below
function IAX.send(name, x)
    if not inj.tried then pcall(inject_move, 0, 0) end   -- sets up function + subsystem (and logs what it found)
    if inj.fn == nil or inj.cls == nil then return false end
    local a = IAX.get(name)
    if a == nil then return false end
    if inj.sub == nil or not alive(inj.sub) then
        inj.sub = nil
        local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(inj.cls, false) end)
        if type(all) == "table" then
            for _, o in ipairs(all) do if not fullname(o):find("Default__") then inj.sub = o; break end end
        end
        if inj.sub == nil then return false end
    end
    local ok, err = pcall(function() inj.fn(inj.sub, a, mkvec(x or 1, 0, 0), {}, {}) end)
    if not ok then
        inj.errs = inj.errs + 1
        if inj.errs <= 6 then LOG("input send failed (" .. name .. "): " .. tostring(err)) end
        return false
    end
    return true
end
inject_move = function(x, y)
    if not inj.tried then
        inj.tried = true
        local ic = api:find_uobject("Class /Script/EnhancedInput.EnhancedInputSubsystemInterface")
        inj.fn = ic and safe(function() return ic:find_function("InjectInputVectorForAction") end)
        inj.move = api:find_uobject("InputAction /Game/Classes/Player/Player_Inputs/IA_Move.IA_Move")
        inj.cls = api:find_uobject("Class /Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
        LOG("ladder input: inject=" .. tostring(inj.fn ~= nil) .. " IA_Move=" .. tostring(inj.move ~= nil) .. " subsystem class=" .. tostring(inj.cls ~= nil))
    end
    if inj.fn == nil or inj.move == nil or inj.cls == nil then return false end
    if inj.sub == nil or not alive(inj.sub) then
        inj.sub = nil
        local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(inj.cls, false) end)
        if type(all) == "table" then
            for _, o in ipairs(all) do if not fullname(o):find("Default__") then inj.sub = o; break end end
        end
        if inj.sub == nil then return false end
    end
    local ok, err = pcall(function() inj.fn(inj.sub, inj.move, mkvec(x, y, 0), {}, {}) end)
    if not ok then
        inj.errs = inj.errs + 1
        if inj.errs <= 3 then LOG("ladder input failed: " .. tostring(err)) end
        return false
    end
    if not inj.logged then inj.logged = true; LOG(string.format("ladder: left stick sent to the game's Move (%.2f, %.2f)", x, y)) end
    return true
end

---------------------------------------------------------------------------
-- 4e (v4.10): OFF-HAND ITEMS - with a one-handed weapon the game can hold the flashlight in the off hand
--     (flashlight key = LB + D-pad up). Whatever the game puts in the off hand now rides on the LEFT controller.
---------------------------------------------------------------------------
-- v6.2: send this frame's walking request (set in update_body) using the control rotation we JUST gave the game
function V62.walk_send(b, delta)
    local w = b.wreq
    b.wreq = nil
    if w == nil then return end
    local M = V62.wm
    local ay = b.carrying and (b.cy or b.yaw) or b.yaw
    local base = (M.model == "actor") and ay or (b.cy or b.yaw)
    local rel = math.rad(w.want - (base + (M.off[M.model] or 0)))
    local ix, iy = math.sin(rel) * w.m, math.cos(rel) * w.m
    if inject_move(ix, iy) then
        b.inj = { x = ix, y = iy, t = T, cy = b.cy or b.yaw, ay = ay, cp = b.cp or 0, want = w.want }
        b.walk_try = (b.walk_try or 0) + delta
    else
        b.walk = "direct"; LOG("walking: the game's Move input is not available - direct walking")
    end
end
-- v6.2: the off-hand item's transform on the left-hand point: the same in-hand angle it gets in the right hand
-- (held items face along their Y axis, so without it the flashlight pointed 90 degrees off to the side)
function V62.offhand_rel()
    local g = offh.cls and GUNS[offh.cls]
    if g ~= nil then return g.x, g.y, g.z, g.pitch, g.yaw, g.roll end
    return 0, 0, 0, 0, -90, 0
end
function V62.offhand_release()
    local o, m = offh.orig, offh.root
    offh.orig = nil
    if o == nil or m == nil or not alive(m) or not alive(offh.actor) then return end
    if o.parent ~= nil and alive(o.parent) and not same(o.parent, offh.grip) then
        pcall(function()
            m:K2_AttachToComponent(o.parent, o.socket or G.NONE, 0, 0, 0, false)
            set_rel(m, o.rl[1], o.rl[2], o.rl[3], o.rr[1], o.rr[2], o.rr[3])
        end)
    end
end
local function update_offhand(pawn)
    local oe = safe(function() return pawn.OffhandEquipment end)
    if oe == nil or not alive(oe) then
        if offh.actor ~= nil then LOG("off-hand item put away"); V62.offhand_release(); offh.actor, offh.root, offh.cls = nil, nil, nil end
        return
    end
    if offh.grip == nil or not alive(offh.grip) then
        local root = safe(function() return pawn.RootComponent end)
        local g = api:add_component_by_class(pawn, G.SceneClass, false)
        if g == nil or root == nil then return end
        g:K2_AttachToComponent(root, G.NONE, 2, 2, 2, false)
        offh.grip = g
        drive(g, 0, "left-hand grip point (off-hand items)")
    end
    if not same(oe, offh.actor) then
        if offh.actor ~= nil then V62.offhand_release() end
        -- v6.2: like the right hand: the item's own mesh (the game animates it inside the item - raise/lower), else the item
        local root = safe(function() return oe.RootComponent end)
        local m = safe(function() return oe.Wep_Skeli end) or root
        if m == nil then return end
        local rl, rr = m.RelativeLocation, m.RelativeRotation
        offh.actor, offh.root, offh.cls = oe, m, shortclass(oe)
        -- v6.6.45: the hold used to carry over from the last time (and every left-trigger press flips it), so it "started"
        -- either way. Now it starts the chosen way each time the item comes out; the left trigger switches as before.
        -- v6.6.47: that way is the TORCH hold (fl_alt false: beam where the hand points - hand down by your side).
        -- fl_alt true = the RAISED hold: beam turned fl_alt_angle down from the hand, for a hand held up by your head.
        V62.fl_alt = S.fl_start_raised == true
        offh.orig = { parent = attach_parent(m), socket = safe(function() return m:GetAttachSocketName() end),
                      rl = { rl and rl.X or 0, rl and rl.Y or 0, rl and rl.Z or 0 }, rr = { rr and rr.Pitch or 0, rr and rr.Yaw or 0, rr and rr.Roll or 0 } }
        LOG("off-hand item now in your LEFT hand: " .. offh.cls .. (same(m, root) and " (whole item)" or " (its mesh)"))
    end
    local r = offh.root
    if r == nil or not alive(r) then return end
    if not same(attach_parent(r), offh.grip) then
        r:K2_AttachToComponent(offh.grip, G.NONE, 2, 2, 1, false)
        set_rel(r, V62.offhand_rel())
        offh.fixes = offh.fixes + 1
        if offh.fixes <= 3 then LOG("off-hand item re-attached to the left hand (" .. offh.fixes .. ")") end
    end
end
local function enforce_offhand()
    local r = offh.root
    if r == nil or not alive(r) or not alive(offh.actor) or offh.grip == nil then return end
    if not same(attach_parent(r), offh.grip) then return end
    local x, y, z, p, yw, ro = V62.offhand_rel()
    local rl, rr = r.RelativeLocation, r.RelativeRotation
    if rl == nil or rr == nil then return end
    local function da(a, b) return math.abs(((a or 0) - b + 540) % 360 - 180) end
    if math.abs((rl.X or 0) - x) + math.abs((rl.Y or 0) - y) + math.abs((rl.Z or 0) - z) > 0.05
        or da(rr.Pitch, p) + da(rr.Yaw, yw) + da(rr.Roll, ro) > 0.1 then
        set_rel(r, x, y, z, p, yw, ro)
    end
end

---------------------------------------------------------------------------
-- v6.0 STEAM FRAME CONTROLS (+ body gestures)
--   SteamVR layout shipped with the mod (bindings_frame_controller.json) puts the Frame's extra buttons on UEVR's spare
--   actions:  right bumper -> ThumbrestTouchRight   left bumper -> ThumbrestTouchLeft   View -> AButtonTouchLeft
--   (UEVR only uses those for thumbrest D-pad shifting, which v6 switches off). D-pad left/right reach UEVR as D-pad.
--   Here they become the game's own input actions:
--     right bumper = Pick up (G)  - hold = lower weapon (exactly like holding G)
--     left bumper  = Mode toggle (C) - gun light/laser, crowbar pry, knife harvest
--     View         = Journal (J)
--     D-pad left / right = previous / next weapon (mouse wheel)
--   GRIPS = body gestures only (ideas from SurrounDead's holster script and System ReShock - re-written here):
--     grip over your RIGHT shoulder = primary weapon    over your LEFT shoulder = secondary weapon
--     grip at your RIGHT hip        = sidearm           at your LEFT hip         = melee
--     grip next to either EAR       = flashlight on/off
--   Each zone gives a small buzz when your hand enters it. Gripping anywhere else does nothing (no accidental
--   pick-ups or lowered guns when you hold a weapon "for real").
---------------------------------------------------------------------------
local fc = { ok = nil, h = {}, prev = {}, taps = {}, zone = { [0] = nil, [1] = nil }, gripped = { [0] = false, [1] = false },
             logged = {}, src = {},
             hp = Vector3f.new(0, 0, 0), hq = Quaternionf.new(0, 0, 0, 1), cp = Vector3f.new(0, 0, 0), cq = Quaternionf.new(0, 0, 0, 1),
             A = { rbump = "/actions/default/in/ThumbrestTouchRight", lbump = "/actions/default/in/ThumbrestTouchLeft",
                   view = "/actions/default/in/AButtonTouchLeft", grip = "/actions/default/in/Grip",
                   dleft = "/actions/default/in/DPad_Left", dright = "/actions/default/in/DPad_Right",
                   lclick = "/actions/default/in/JoystickClick",           -- v6.2: stick click (left = sprint)
                   lgripl = "/actions/default/in/BButtonTouchLeft",        -- v6.2: LIGHT grip (binding: grip value > 0.3)
                   rgripl = "/actions/default/in/BButtonTouchRight",
                   ybtn = "/actions/default/in/BButtonLeft",               -- v6.3: Y (UEVR face mapping)
                   trig = "/actions/default/in/Trigger" },                 -- v6.3: triggers (left = flashlight hold)
 }

function fc.setup()
    if fc.ok ~= nil then return fc.ok end
    local n = 0
    for k, path in pairs(fc.A) do
        local h = safe(function() return vr.get_action_handle(path) end)
        if h ~= nil and h ~= 0 then fc.h[k] = h; n = n + 1 end
    end
    fc.src[0] = safe(vr.get_left_joystick_source)
    fc.src[1] = safe(vr.get_right_joystick_source)
    fc.ok = n > 0 and fc.src[0] ~= nil and fc.src[1] ~= nil
    LOG("Steam Frame controls: " .. n .. " SteamVR actions found, controller sources " .. tostring(fc.src[0] ~= nil and fc.src[1] ~= nil))
    return fc.ok
end
function fc.down(key, hand)
    local h = fc.h[key]
    if h == nil then return false end
    if hand ~= nil then return safe(function() return vr.is_action_active(h, fc.src[hand]) end) == true end
    return safe(function() return vr.is_action_active(h, fc.src[0]) end) == true or safe(function() return vr.is_action_active(h, fc.src[1]) end) == true
end
function fc.tap(ia, label)
    fc.taps[ia] = 2                                  -- two frames of "pressed", then released: a clean key tap
    if label and not fc.logged[ia] then fc.logged[ia] = true; LOG("Frame control used: " .. label .. " -> " .. ia) end
end
function fc.edge(key, hand)
    local d = fc.down(key, hand)
    local k = key .. tostring(hand)                  -- v6.2: per hand
    local was = fc.prev[k]
    fc.prev[k] = d
    return d and not was
end
-- v6.2: left grip held (light grip from the binding, or the full click if that binding isn't active)
function V62.lgrip_held()                                      -- the OTHER hand's grip (the one that takes a long gun's fore-grip)
    if not fc.setup() then return false end
    if S.left_handed == true then return fc.down("rgripl", 1) or fc.down("rbump", 1) end   -- v6.6.49: the right grip
    return fc.down("lgripl", 0) or fc.down("grip", 0)
end
-- v6.6.49: the two bumpers by what they do. In the Frame layout the right bumper is the "Grip" action of the right
-- controller and the left bumper is "ThumbrestTouchLeft"; left-handed they change jobs.
function V62.gun_bumper()                                      -- tap = pick up, hold = lower / raise the weapon
    if S.left_handed == true then return fc.down("lbump", 0) end
    return fc.down("grip", 1)
end
function V62.off_bumper()                                      -- weapon light / laser, pry, harvest
    if S.left_handed == true then return fc.down("grip", 1) end
    return fc.down("lbump", 0)
end
-- v6.6.49: fire and aim are made by the joytokey plugin from the pad's triggers; a_sf_hand.dll swaps the two for it
-- while this is on. Sent every 2 s while left-handed (the plugin starts "off"); never sent by a right-handed player.
function V62.hand_sync(now)
    local want = S.left_handed == true
    if not want and not V62.hand_used then return end
    if not now and T < (V62.hand_t or 0) then return end
    V62.hand_t, V62.hand_used, V62.hand_raw = T + 2.0, true, nil
    pcall(function() api:dispatch_custom_event("sfhand", want and "left 1" or "left 0") end)
    V62.hand_ok = (V62.hand_raw == (want and "left=1" or "left=0"))
    local state = tostring(want) .. tostring(V62.hand_ok)
    if V62.hand_logged ~= state then
        V62.hand_logged = state
        if want then
            LOG("left-handed: the gun hand is the LEFT controller; triggers swapped by a_sf_hand.dll: " .. (V62.hand_ok and "yes" or "NO ANSWER - the right trigger still fires (is plugins\\a_sf_hand.dll there?)"))
        else
            LOG("right-handed again; triggers back to normal: " .. (V62.hand_ok and "yes" or "no answer from a_sf_hand.dll"))
        end
    end
    if not want and V62.hand_ok then V62.hand_used = false end    -- told, answered: nothing more to send
end
-- v6.6.2: WEAPON CYCLING 1-4. D-pad right / left = the game's own next / previous weapon (instant; the game knows
-- which slots are empty). The game's order runs on into the utility items (slots 5-8): when a press lands on one,
-- we go straight to the first weapon slot (right) or the last one (left) - and remember for the whole session that
-- this weapon is the end of the row, so from then on the jump happens with no utility item in between. Menus and
-- pick-ups don't wipe this; it's only forgotten when a weapon you haven't held yet this session comes out.
V62.SLOTS = { "IA_Slot_Melee", "IA_Slot_SideArm", "IA_Slot_PrimaryWep", "IA_Slot_SecondaryWep" }
V62.wrap, V62.wrap_to, V62.seen = {}, {}, {}
function V62.held(pawn)
    local e = safe(function() return pawn.EquipedItem end)
    if e == nil or not alive(e) then return nil end
    return shortclass(e)
end
function V62.held_addr(pawn)
    local e = safe(function() return pawn.EquipedItem end)
    if e == nil then return nil end
    return addr(e)
end
function V62.is_weapon(c)
    return c ~= nil and (c:sub(1, 4) == "Wep_" or c:sub(1, 9) == "MeleeWep_" or c:sub(1, 5) == "EWep_")
end
function V62.jump(c, pawn, wait)           -- weapon slot keys from the start of the row (remembered slot first)
    local order = c.dir > 0 and { 1, 2, 3, 4 } or { 4, 3, 2, 1 }
    local first = V62.wrap_to[c.dir]
    if first ~= nil then
        local o = { first }
        for _, k in ipairs(order) do if k ~= first then o[#o + 1] = k end end
        order = o
    end
    c.stage, c.order, c.i = "jump", order, 0
    if wait then c.slot, c.until_t = nil, T + wait; return end   -- a utility item just came out: let the game take input
    V62.jump_next(c, pawn)
end
function V62.jump_next(c, pawn)
    c.i = c.i + 1
    local k = c.order[c.i]
    if k == nil then V62.cyc = nil; return end
    c.slot, c.until_t, c.before, c.before_a = k, T + 0.4, V62.held(pawn), V62.held_addr(pawn)   -- v6.6.4: 0.4 s margin
    fc.tap(V62.SLOTS[k])
end
-- v6.6.10: the equipped-item list, read by sf_inv.dll (answers synchronously through on_lua_event)
function V62.inv_read(pawn)
    local gi = safe(function() return pawn["As Game Instance FP"] end)
    local sv = safe(function() return pawn.Save end)                     -- v6.6.12: the player's own save reference first
    local sv2 = gi and safe(function() return gi.SaveSlot_Ref end)
    local ga, sa, sa2 = gi and addr(gi), sv and addr(sv), sv2 and addr(sv2)
    if sa == nil then sa, sa2 = sa2, nil end
    if ga == nil and sa == nil then return nil end
    V62.inv_raw = nil
    pcall(function() api:dispatch_custom_event("sfinv", string.format("read %x %x %x", ga or 0, sa or 0, sa2 or 0)) end)
    return V62.inv_raw
end
-- v6.6.12: slots 1-4 from the save object's PlayerEquipment list (the field named Item_Class... in each entry)
function V62.save_slots(pawn)
    local raw = V62.inv_read(pawn)
    if raw == nil or raw == "" then return nil, "no answer from sf_inv.dll" end
    V62.inv_logs = (V62.inv_logs or 0) + 1
    if V62.inv_logs <= 2 then for line in raw:gmatch("[^\n]+") do LOG("weapon slots raw: " .. line:sub(1, 700)) end end
    local why = "no PlayerEquipment line"
    for line in raw:gmatch("[^\n]+") do
        local name = line:match("^([%w_]+);")
        if name ~= nil and name:sub(1, 15) == "PlayerEquipment" then
            if line:find(";err=") then why = line:sub(1, 120)
            else
                local fl = line:match(";f=([^;]*)") or ""
                local ci, i = nil, 0
                for fld in (fl .. ","):gmatch("([^,]*),") do i = i + 1; if ci == nil and fld:sub(1, 10) == "Item_Class" then ci = i end end
                local elems = {}
                for idx, vals in line:gmatch(";(%d+)=([^;]*)") do elems[tonumber(idx)] = vals end
                local slots = {}
                for k = 1, 4 do
                    local vals = elems[k - 1]
                    if vals ~= nil then
                        local j, pick = 0, nil
                        for v in (vals .. "|"):gmatch("([^|]*)|") do
                            j = j + 1
                            if (ci ~= nil and j == ci) or (ci == nil and pick == nil and V62.is_weapon(v)) then pick = v end
                        end
                        if pick ~= nil and pick ~= "0" and pick ~= "-" and pick ~= "" and pick ~= "None" then slots[k] = V62.base_class(pick) end
                    end
                end
                return slots, name
            end
        end
    end
    return nil, why
end
-- v6.6.12: slots 1-4 as the inventory screen last showed them (second source; may only refresh when it opens)
V62.ITEM_CLASS = "Item_Class_3_2813641E42AA35FC0693029E4EE49F81"
function V62.screen_slots()
    local inv = V62.inv_screen
    if inv == nil or not alive(inv) then
        inv = nil
        local cls = V62.flat_cls and V62.flat_cls.InventoryScreen_C
        if cls == nil then pcall(V62.flat_lookup); cls = V62.flat_cls and V62.flat_cls.InventoryScreen_C end
        if cls == nil then return nil end
        local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end)
        if type(all) == "table" then for _, w in ipairs(all) do if alive(w) and not fullname(w):find("Default__") then inv = w end end end
        V62.inv_screen = inv
        if inv == nil then return nil end
    end
    local slots, any = {}, false
    for k = 1, 4 do
        local c = safe(function()
            local it = inv["ItemSlot_" .. k].ItemCard.Item
            local cl = it[V62.ITEM_CLASS]
            return cl and cl:get_fname():to_string()
        end)
        if c ~= nil and c ~= "None" and c ~= "" then slots[k] = c end
        any = true
    end
    return any and slots or nil
end
function V62.slot_check(slots, held)
    if slots == nil or next(slots) == nil then return false end   -- nothing listed at all: don't trust it
    if held == nil or not V62.is_weapon(held) then return true end
    for k = 1, 4 do if slots[k] == held then return true end end
    return false                                                   -- the gun in your hand isn't listed: stale
end
function V62.base_class(v)                 -- "Wep_X_C_2147480000" -> "Wep_X_C"
    if v == nil then return nil end
    return v:match("^(.-_C)_%d+$") or v
end
function V62.inv_slots(pawn)                -- v6.6.12: save object first, inventory screen second, both checked
    local held = V62.base_class(V62.held(pawn))
    local ss, sname = V62.save_slots(pawn)
    local ws = V62.screen_slots()
    local okS, okW = V62.slot_check(ss, held), V62.slot_check(ws, held)
    local pick, src = nil, nil
    if okS then pick, src = ss, "save game" elseif okW then pick, src = ws, "inventory screen" end
    local function sig(t) if t == nil then return "n/a" end return table.concat({ t[1] or "-", t[2] or "-", t[3] or "-", t[4] or "-" }, " ") end
    local line = "save game [" .. sig(ss) .. "]" .. ((ss ~= nil and not okS) and " STALE" or "") .. " | inventory screen [" .. sig(ws) .. "]"
        .. ((ws ~= nil and not okW) and " STALE" or "") .. " | holding " .. tostring(held) .. " -> using " .. (src or "the older cycling")
    if line ~= V62.slot_line then
        V62.slot_line = line
        V62.sl_n = (V62.sl_n or 0) + 1
        if V62.sl_n <= 30 then LOG("weapon slots: " .. line) end
    end
    if ss == nil and not V62.inv_nolog then V62.inv_nolog = true; LOG("weapon slots: save game list not readable (" .. tostring(sname) .. ")") end
    return pick
end
function V62.exact_cycle(pawn, dir)
    local slots = V62.inv_slots(pawn)
    if slots == nil then return false end
    local held = V62.base_class(V62.held(pawn))
    local cur = nil
    for k = 1, 4 do if slots[k] ~= nil and held ~= nil and slots[k] == held then cur = k end end
    local lp = V62.ex_last                  -- pressed a moment ago and the new weapon isn't in hand yet: count from there
    if lp ~= nil and T - lp.t < 0.6 and slots[lp.k] ~= nil and slots[lp.k] ~= held then cur = lp.k end
    local start = cur or (dir > 0 and 0 or 5)
    for i = 1, 4 do
        local k = ((start - 1 + dir * i) % 4) + 1
        if start == 0 then k = i elseif start == 5 then k = 5 - i end
        if slots[k] ~= nil and k ~= cur then
            fc.tap(V62.SLOTS[k])
            V62.ex_last = { k = k, t = T }
            V62.exn = (V62.exn or 0) + 1
            if V62.exn <= 10 then LOG("weapon cycling (exact): slot " .. k .. " = " .. slots[k] .. (cur and (" (from slot " .. cur .. ")") or "")) end
            return true
        end
    end
    return true                              -- only one weapon (or none): nothing to switch to
end
function V62.cycle_start(pawn, dir)
    if S.exact_cycle ~= false and V62.exact_cycle(pawn, dir) then V62.cyc, V62.cyc_q = nil, nil; return end   -- v6.6.10
    if V62.cyc ~= nil and T < V62.cyc.giveup then V62.cyc_q = dir; return end     -- one press waits its turn
    local from = V62.held(pawn)
    local c = { dir = dir, from = from, giveup = T + 2.5 }
    V62.cyc = c
    if not fc.logged.wc then fc.logged.wc = true; LOG("Frame control used: D-pad " .. (dir > 0 and "right" or "left") .. " (weapons 1-4)") end
    if not V62.is_weapon(from) or V62.wrap[dir .. from] then V62.jump(c, pawn); return end
    c.stage, c.until_t, c.before = "step", T + 0.6, from
    fc.tap(dir > 0 and "IA_Equip_Next" or "IA_Equip_Previous")
end
function V62.cycle_update(pawn)
    local now = V62.held(pawn)
    local c = V62.cyc
    if V62.is_weapon(now) and not V62.seen[now] then          -- a weapon not held before this session: start over
        V62.seen[now] = true
        if next(V62.wrap) ~= nil then
            V62.wrap, V62.wrap_to = {}, {}
            if c ~= nil and c.flagged then V62.wrap[c.dir .. c.from] = true end   -- (what this press just learned stays)
            LOG("weapon cycling: new weapon (" .. now .. ") - row ends forgotten")
        end
    end
    if c == nil then
        if V62.cyc_q ~= nil then local d = V62.cyc_q; V62.cyc_q = nil; V62.cycle_start(pawn, d) end
        return
    end
    if T > c.giveup then V62.cyc = nil; return end
    if c.stage == "step" then
        if now ~= c.before and now ~= nil then
            if V62.is_weapon(now) then V62.cyc = nil; return end   -- the game's next weapon: done
            if c.from ~= nil then V62.wrap[c.dir .. c.from] = true; c.flagged = true end
            V62.wcl = (V62.wcl or 0) + 1
            if V62.wcl <= 6 then LOG("weapon cycling: " .. tostring(c.from) .. " is the " .. (c.dir > 0 and "last" or "first") .. " weapon (next was " .. now .. ") - jumping") end
            V62.jump(c, pawn, 0.12)
        elseif T > c.until_t then V62.cyc = nil end
    elseif c.stage == "jump" then
        -- a weapon came out - not the one we started from (that would only be it re-drawn, or the game still busy)
        if c.slot ~= nil and V62.is_weapon(now) and now ~= c.from and (now ~= c.before or V62.held_addr(pawn) ~= c.before_a) then
            V62.wrap_to[c.dir] = c.slot
            V62.wcn = (V62.wcn or 0) + 1
            if V62.wcn <= 8 then LOG("weapon cycling: slot " .. c.slot .. " = " .. now) end
            V62.cyc = nil
            return
        end
        if T > c.until_t then V62.jump_next(c, pawn) end
    end
end
-- v6.3: GRAPHICS PRESETS for the shimmer test (left grip + View). Values from Epic's cvar docs and the r/Engineini
-- UE5 anti-aliasing guide; Lumen ray clamps are milder than that guide's. Anything a preset doesn't set goes back to
-- the value the game had before we first touched it. One cvar per frame, read first, only written if different.
V62.TSR = { ["r.AntiAliasingMethod"] = 4, ["r.Tonemapper.Sharpen"] = 0.5,
    ["r.TSR.ShadingRejection.Flickering"] = 1, ["r.TSR.ShadingRejection.Flickering.Period"] = 3,
    ["r.TSR.History.SampleCount"] = 16, ["r.Lumen.ScreenProbeGather.MaxRayIntensity"] = 8,
    ["r.Lumen.Reflections.MaxRayIntensity"] = 8, ["r.Lumen.ScreenProbeGather.ShortRangeAO"] = 0,
    ["r.Lumen.ScreenProbeGather.Temporal.MaxFramesAccumulated"] = 16, ["r.Shadow.MaxCSMResolution"] = 4096 }
function V62.tsr(extra)
    local t = {}
    for k, v in pairs(V62.TSR) do t[k] = v end
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
-- internal resolution: r.ScreenPercentage stays 0 ("auto", UEVR's business); the auto rule is switched to manual
V62.PIN = function(pct, hist)
    return V62.tsr({ ["r.ScreenPercentage.Default.Desktop.Mode"] = 0, ["r.ScreenPercentage.Default.VR.Mode"] = 0,
        ["r.ScreenPercentage.Default"] = pct, ["r.TSR.History.ScreenPercentage"] = hist })
end
function V62.merge(a, b) local t = {}; for k, v in pairs(a) do t[k] = v end; for k, v in pairs(b) do t[k] = v end; return t end
-- v6.6.47: FOUR PRESETS (the tester, for the release: "there should just be like three presets like a high medium low ...
-- or maybe four ... pure performance"). What was measured on the way here: 85% resolution with TSR looks
-- the same as 100% to the tester and is about a quarter faster (65 vs 50 fps at the lake) -> Medium, the default. Low is
-- Medium without distance-field shadows, screen-space reflections and ambient occlusion, sun shadows at 2048 (the
-- "90 Hz attempt" of v6.6.26: 5-10 fps; the tester: "feels a lot worse", fine as an option). Performance adds 70% resolution
-- with a plain TSR history, a coarser fog grid and cheaper bloom - not measured as a set.
-- NOT IN A PRESET AGAIN: r.ViewDistanceScale, r.StaticMeshLODDistanceScale, r.Shadow.DistanceScale,
-- foliage.LODDistanceScale, grass.CullDistanceScale. v6.6.45's "farther detail" preset set those five (3.0 / 0.5 / 1.5
-- / 2.5 / 2.0) and the game stopped drawing the moment it was switched on (2026-11-10 10:22:13; no frame for 45 s, no
-- crash report, closed by hand). Which one did it - and whether it was the change itself or the size of the values -
-- is not known: the grass and shadow-distance settings had never been set by the mod before, the other three only at
-- the main menu (user_script.txt) and to smaller values. Every setting below was switched while playing in earlier
-- versions without trouble (the 70% value itself is new; 85 <-> 100 on the same setting is not).
V62.LIGHT = { ["r.DistanceFieldShadowing"] = 0, ["r.SSR.Quality"] = 0, ["r.AmbientOcclusionLevels"] = 0, ["r.Shadow.MaxCSMResolution"] = 2048 }
V62.CHEAP = { ["r.VolumetricFog.GridPixelSize"] = 16, ["r.BloomQuality"] = 4 }
V62.GFX = {
    { name = "High", what = "full resolution - about a quarter slower than Medium, hard to tell apart in the headset", cv = V62.PIN(100, 100) },
    { name = "Medium", what = "the standard look: 85% resolution, sharpened back up", cv = V62.PIN(85, 150) },
    { name = "Low", what = "Medium without soft far shadows, screen reflections and corner shading; smaller sun shadows", cv = V62.merge(V62.PIN(85, 150), V62.LIGHT) },
    { name = "Performance", what = "Low at 70% resolution, with simpler fog and bloom", cv = V62.merge(V62.merge(V62.PIN(70, 100), V62.LIGHT), V62.CHEAP) },
}
if V62.GFX[S.gfx_level] == nil then S.gfx_level = 2 end        -- (a settings file edited by hand)
function V62.gfx_queue(p, why)
    local P = V62.GFX[p] or V62.GFX[2]
    local names = {}
    for _, pr in ipairs(V62.GFX) do for n in pairs(pr.cv) do names[n] = true end end
    V62.gfx_q = {}
    for n in pairs(names) do V62.gfx_q[#V62.gfx_q + 1] = { n = n, v = P.cv[n] } end   -- v = nil: back to the original
    -- v6.5: scalability groups (sg.*) first - each resets a whole group of settings - then the single settings
    table.sort(V62.gfx_q, function(a, b)
        local sa, sb = a.n:sub(1, 3) == "sg.", b.n:sub(1, 3) == "sg."
        if sa ~= sb then return sa end
        return a.n < b.n
    end)
    V62.gfx_p, V62.gfx_set = p, 0
    LOG("graphics preset " .. p .. " (" .. P.name .. ") " .. (why or ""))
    flushlog()                                                 -- v6.6.47: on disk before the first setting changes
end
function V62.gfx_step(pawn)
    local q = V62.gfx_q
    if #q == 0 then return end
    if KSYS == nil then return end
    local it = table.remove(q, 1)
    local have = safe(function() return KSYS:GetConsoleVariableFloatValue(it.n) end)
    if V62.gfx_orig[it.n] == nil and type(have) == "number" then V62.gfx_orig[it.n] = have end
    local want = it.v
    if want == nil then want = V62.gfx_orig[it.n] end
    if want ~= nil and not (type(have) == "number" and math.abs(have - want) < 0.001) then
        if pcall(function() KSYS:ExecuteConsoleCommand(pawn, it.n .. " " .. tostring(want), nil) end) then V62.gfx_set = V62.gfx_set + 1 end
    end
    if #q == 0 then
        local function cv(n) return tostring(safe(function() return KSYS:GetConsoleVariableFloatValue(n) end)) end
        LOG(string.format("graphics preset %d applied (%d settings changed) - ScreenPercentage %s, Default %s, Desktop.Mode %s, VR.Mode %s, AA %s, TSR history %s",
            V62.gfx_p or 0, V62.gfx_set or 0, cv("r.ScreenPercentage"), cv("r.ScreenPercentage.Default"), cv("r.ScreenPercentage.Default.Desktop.Mode"),
            cv("r.ScreenPercentage.Default.VR.Mode"), cv("r.AntiAliasingMethod"), cv("r.TSR.History.ScreenPercentage")))
        if not V62.orig_logged then
            V62.orig_logged = true
            local parts = {}
            for n, v in pairs(V62.gfx_orig) do parts[#parts + 1] = n .. "=" .. tostring(v) end
            table.sort(parts)
            LOG("graphics: the game's own values before any preset: " .. table.concat(parts, ", "))
            local sg = {}                                          -- v6.6.13: the game's own quality levels (0 low .. 3 epic)
            for _, n in ipairs({ "sg.ResolutionQuality", "sg.ViewDistanceQuality", "sg.AntiAliasingQuality", "sg.ShadowQuality",
                                  "sg.GlobalIlluminationQuality", "sg.ReflectionQuality", "sg.PostProcessQuality", "sg.TextureQuality",
                                  "sg.EffectsQuality", "sg.FoliageQuality", "sg.ShadingQuality" }) do
                sg[#sg + 1] = n:sub(4) .. "=" .. tostring(safe(function() return KSYS:GetConsoleVariableFloatValue(n) end))
            end
            LOG("graphics: the game's quality levels: " .. table.concat(sg, ", ") .. " | lumen GI " ..
                tostring(safe(function() return KSYS:GetConsoleVariableFloatValue("r.DynamicGlobalIlluminationMethod") end)) .. ", reflections " ..
                tostring(safe(function() return KSYS:GetConsoleVariableFloatValue("r.ReflectionMethod") end)))
        end
    end
end
-- v6.3: menus - the right stick scrolls the scroll box under the cursor
function V62.menu_scroll(ry, delta)
    if not S.menu_stick_scroll then return end
    if math.abs(ry) < 0.3 then V62.sb_on = false; return end
    if V62.sb_cls == nil then
        V62.sb_cls = {}
        for _, p in ipairs({ "Class /Script/UMG.ScrollBox", "Class /Script/UMG.ListView", "Class /Script/UMG.TileView" }) do
            local c = api:find_uobject(p)
            if c ~= nil then V62.sb_cls[#V62.sb_cls + 1] = c end
        end
        local c = api:find_uobject("Class /Script/UMG.SlateBlueprintLibrary")
        V62.sbl = c and c:get_class_default_object()
    end
    if not V62.sb_on or T > (V62.sb_t or 0) then
        V62.sb_on, V62.sb_t, V62.sb = true, T + 0.5, nil
        local mp = G.Layout and safe(function() return G.Layout:GetMousePositionOnPlatform() end)
        local cands, under = {}, nil
        for _, cls in ipairs(V62.sb_cls) do
            local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(cls, false) end)
            if type(all) == "table" then
                for _, sb in ipairs(all) do
                    if not fullname(sb):find("Default__") and safe(function() return sb:IsVisible() end) == true then
                        local e = safe(function() return sb:GetScrollOffsetOfEnd() end)
                        if e == nil or e > 1 then
                            cands[#cands + 1] = sb
                            if under == nil and mp ~= nil and V62.sbl ~= nil then
                                local geo = safe(function() return sb:GetCachedGeometry() end)
                                if geo ~= nil and safe(function() return V62.sbl:IsUnderLocation(geo, mp) end) == true then under = sb end
                            end
                        end
                    end
                end
            end
        end
        V62.sb = under or ((#cands == 1) and cands[1] or nil)
        V62.sb_logn = (V62.sb_logn or 0) + 1
        if V62.sb_logn <= 4 then
            LOG(string.format("menu scroll: %d scrollable lists, under the cursor: %s, using: %s", #cands,
                under and (fullname(under):match("[%w_]+$") or "?") or "none", V62.sb and (fullname(V62.sb):match("[%w_]+$") or "?") or "none"))
        end
    end
    local sb = V62.sb
    if sb == nil or not alive(sb) then return end
    local o = safe(function() return sb:GetScrollOffset() end) or 0
    local e = safe(function() return sb:GetScrollOffsetOfEnd() end) or 1e9
    local sp = (math.abs(ry) - 0.3) / 0.7
    local step = (ry > 0 and 1 or -1) * sp * sp * delta * ((shortclass(sb) == "ScrollBox") and 2000 or 12)   -- list views scroll in items
    local ok = pcall(function() sb:SetScrollOffset(math.max(0, math.min(e, o - step))) end)
    if not ok and not V62.sb_err then V62.sb_err = true; LOG("menu scroll: this list did not accept a scroll offset") end
end
-- v6.5: find a widget by its object name anywhere under a widget (same walk as the HUD dump)
function V62.find_widget(w, name, n)
    if w == nil or n.c > 500 then return nil end
    n.c = n.c + 1
    if (fullname(w):match("([^%.:]+)$")) == name then return w end
    local cnt = safe(function() return w:GetChildrenCount() end)
    if type(cnt) == "number" then
        for i = 0, math.min(cnt, 60) - 1 do
            local r = V62.find_widget(safe(function() return w:GetChildAt(i) end), name, n)
            if r ~= nil then return r end
        end
    end
    local root = safe(function() return w.WidgetTree.RootWidget end)
    if root ~= nil then return V62.find_widget(root, name, n) end
    return nil
end
-- v6.5: keys through the sf_keys plugin (real scan codes). mode = "hold" (send every frame while held) / "tap" / "up"
function V62.key(mode, vk)
    local ok = pcall(function() api:dispatch_custom_event("sfkey", mode .. " " .. string.format("0x%X", vk)) end)
    if not V62.key_logged then V62.key_logged = true; LOG("keys: sent through the sf_keys plugin (" .. tostring(ok) .. ")") end
end
-- v6.6.12: jump log - how high the feet rose (crouching mid-air shrinks the capsule, so feet = centre - half height)
function V62.feet_z(pawn)
    local loc = pawn:K2_GetActorLocation()
    local hh = safe(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end) or 0
    return (loc.Z or 0) - hh
end
function V62.jump_start(pawn)
    local z = V62.feet_z(pawn)
    V62.jl = { t0 = T, z0 = z, top = z, cj = V62.cj ~= nil, ctop = false,
               jz = safe(function() return pawn.CharacterMovement.JumpZVelocity end),
               gs = safe(function() return pawn.CharacterMovement.GravityScale end) }
end
function V62.jump_track(pawn)
    local jl = V62.jl
    local z = V62.feet_z(pawn)
    if z > jl.top then jl.top = z; jl.ctop = safe(function() return pawn.bIsCrouched end) == true end
    local age = T - jl.t0
    local falling = safe(function() return pawn.CharacterMovement:IsFalling() end)
    if age > 2.0 or (age > 0.3 and falling == false) then
        V62.jl = nil
        V62.jn = (V62.jn or 0) + 1
        if V62.jn <= 25 then
            local function pv(n) return tostring(safe(function() return pawn[n] end)) end
            local function f1(v) return type(v) == "number" and string.format("%.0f", v) or tostring(v) end
            LOG(string.format("jump %d: feet rose %.0f cm%s%s | game jump speed %s cm/s (normal %s), gravity x%s | hunger stack %s, sickness %s, carry %s",
                V62.jn, jl.top - jl.z0, jl.cj and " (crouch-jump)" or "", jl.ctop and ", crouched at the top" or "",
                f1(jl.jz), pv("Normal_JumpVelocity"), tostring(jl.gs), pv("HungerStack"), pv("Sickness"), pv("Inventory_CarryWeight")))
        end
    end
end
-- v6.6.13: SteamVR keyboard (sf_kbd.dll). Shown while a terminal is open, or when a text box gets typing focus after the
-- menu opened (a box that already has focus when the menu opens - a shop search - doesn't pop it up; left stick click does).
V62.KBD_WIDGETS = { Menu_Terminal_Widget_C = true }
V62.TEXT_CLASSES = { "Class /Script/UMG.EditableTextBox", "Class /Script/UMG.EditableText",
                     "Class /Script/UMG.MultiLineEditableTextBox", "Class /Script/UMG.MultiLineEditableText" }
function V62.kbd_lookup()
    V62.kbd_cls = V62.kbd_cls or {}
    if not V62.kbd_cls_done then
        local wb = V62.wbgc or api:find_uobject("Class /Script/UMG.WidgetBlueprintGeneratedClass")
        local all = wb and safe(function() return UEVR_UObjectHook.get_objects_by_class(wb, false) end)
        if type(all) == "table" then
            for _, k in ipairs(all) do
                local n = fullname(k):match("[%w_]+$")
                if n ~= nil and V62.KBD_WIDGETS[n] and V62.kbd_cls[n] == nil then V62.kbd_cls[n] = k; LOG("keyboard: terminal screen found (" .. n .. ")") end
            end
        end
        if next(V62.kbd_cls) ~= nil then V62.kbd_cls_done = true end
    end
    if V62.txt_cls == nil then
        V62.txt_cls = {}
        for _, p in ipairs(V62.TEXT_CLASSES) do local c = api:find_uobject(p); if c ~= nil then V62.txt_cls[#V62.txt_cls + 1] = c end end
    end
end
function V62.kbd_scan()                      -- returns: terminal name or nil, focused text box (object) or nil
    for n, c in pairs(V62.kbd_cls or {}) do
        local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(c, false) end)
        if type(all) == "table" then
            for _, w in ipairs(all) do
                if alive(w) and not fullname(w):find("Default__") and safe(function() return w:IsInViewport() end) == true then return n, nil end
            end
        end
    end
    for _, c in ipairs(V62.txt_cls or {}) do
        local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(c, false) end)
        if type(all) == "table" then
            for _, w in ipairs(all) do
                if alive(w) and not fullname(w):find("Default__") and safe(function() return w:HasKeyboardFocus() end) == true then return nil, w end
            end
        end
    end
    return nil, nil
end
function V62.kbd_send(cmd)
    pcall(function() api:dispatch_custom_event("sfkbd", cmd) end)
end
function V62.kbd_open(why)
    V62.kbd_shown, V62.kbd_why, V62.kbd_wait = true, why, T + 1.0
    V62.kbd_send(string.format("place %d %.0f %.0f %.0f", S.kbd_place and 1 or 0, S.kbd_fwd or 45, S.kbd_down or 55, S.kbd_tilt or 50))   -- v6.6.20
    V62.kbd_send("show 256 Silverfish")
    V62.kbn = (V62.kbn or 0) + 1
    if V62.kbn <= 20 then LOG("keyboard: SteamVR keyboard asked for (" .. why .. ")") end
end
function V62.kbd_update(delta, lclick)
    if not S.kbd_auto then return end
    if not V62.kbd_in_menu then                                  -- a menu just opened
        V62.kbd_in_menu, V62.kbd_t0, V62.kbd_dismissed, V62.kbd_skip, V62.kbd_t = true, T, false, nil, 0
        V62.kbd_manual, V62.kbd_seen, V62.kbd_want = false, false, false
        pcall(V62.kbd_lookup)
    end
    if V62.kbd_wait ~= nil and T > V62.kbd_wait then             -- no answer: plugin missing / not working
        V62.kbd_wait, V62.kbd_shown, V62.kbd_dismissed, V62.kbd_manual = nil, false, true, false
        if not V62.kbd_nolog then V62.kbd_nolog = true; LOG("keyboard: no answer from sf_kbd.dll (not installed yet, or it failed - see UEVR log)") end
    end
    if lclick and not V62.kbd_shown and (V62.kbd_dismissed or V62.kbd_seen) then   -- left stick click: by hand
        V62.kbd_manual, V62.kbd_dismissed, V62.kbd_want = true, false, true
        V62.kbd_open("left stick click")
        return
    end
    V62.kbd_t = (V62.kbd_t or 0) - delta
    if V62.kbd_t > 0 then return end
    V62.kbd_t = 0.25
    local term, box = V62.kbd_scan()
    local ba = box and addr(box)
    if ba ~= nil and V62.kbd_skip == nil and T - V62.kbd_t0 < 0.6 then V62.kbd_skip = ba end   -- focused from the start
    if ba == nil and V62.kbd_skip then V62.kbd_skip = false end                                  -- focus moved off it
    if ba ~= nil then V62.kbd_seen = true end
    if ba ~= nil and ba == V62.kbd_skip then box = nil end
    local why = term or (box ~= nil and (shortclass(box) .. " got typing focus")) or nil
    if why ~= nil then V62.kbd_seen = true end
    V62.kbd_want = why ~= nil or V62.kbd_manual
    if why ~= nil and not V62.kbd_shown and not V62.kbd_dismissed and T > (V62.kbd_next or 0) then
        V62.kbd_open(why)
    elseif why == nil and V62.kbd_shown and not V62.kbd_manual then
        V62.kbd_shown = false
        V62.kbd_send("hide")
    end
end
function V62.kbd_events()
    local q = V62.kbd_q
    if q == nil or #q == 0 then return end
    V62.kbd_q = {}
    for _, d in ipairs(q) do
        if d == "shown" then V62.kbd_wait = nil
        elseif d:sub(1, 4) == "done" then V62.kbd_shown, V62.kbd_manual, V62.kbd_next = false, false, T + 0.5   -- back while still wanted
        elseif d:sub(1, 6) == "closed" then V62.kbd_shown, V62.kbd_manual, V62.kbd_dismissed = false, false, true
        elseif d:sub(1, 3) == "err" then V62.kbd_shown, V62.kbd_manual, V62.kbd_dismissed, V62.kbd_wait = false, false, true, nil end
        V62.kbe = (V62.kbe or 0) + 1
        if V62.kbe <= 30 or d:sub(1, 3) == "err" then LOG("keyboard: " .. d) end
    end
end
-- v6.6.14: THROWS. The game throws along its aim at ThrowVelocity (1000). While the trigger is held with something
-- carried: the aim follows the hand without smoothing, and ThrowVelocity grows with how fast your hand moved in the
-- last 0.15 s (a yank throws harder). Every throw is logged: hand speed, strength, where it flew vs where you pointed.
function V62.hand_peak()
    local h, peak = V62.hand_hist or {}, 0
    for i = 2, #h do
        local p, q = h[i - 1], h[i]
        if T - q[1] <= 0.15 and q[1] > p[1] then
            local d = math.sqrt((q[2] - p[2]) ^ 2 + (q[3] - p[3]) ^ 2 + (q[4] - p[4]) ^ 2) / 100 / (q[1] - p[1])
            if d > peak then peak = d end
        end
    end
    return peak
end
-- v6.6.15: the hand is tracked RELATIVE TO YOUR BODY (walking / running speed no longer counts as throwing speed)
function V62.throw_watch(pawn, firing, held)
    local gh = grip or hold
    local l = gh ~= nil and alive(gh) and safe(function() return gh:K2_GetComponentLocation() end) or nil
    local pl = safe(function() return pawn:K2_GetActorLocation() end)
    if l ~= nil and pl ~= nil then
        local h = V62.hand_hist or {}
        V62.hand_hist = h
        h[#h + 1] = { T, (l.X or 0) - (pl.X or 0), (l.Y or 0) - (pl.Y or 0), (l.Z or 0) - (pl.Z or 0) }
        while #h > 2 and T - h[1][1] > 0.25 do table.remove(h, 1) end
    end
    if held ~= nil then
        V62.tw_held = held
        if firing then
            V62.throw_snap = T + 0.3
            local peak = V62.hand_peak()
            if V62.tw == nil or V62.tw.done then V62.tw = { t = T, peak = 0 } end
            if peak > V62.tw.peak then V62.tw.peak = peak end
            if S.throw_power ~= false then
                if V62.tv0 == nil then V62.tv0 = safe(function() return pawn.ThrowVelocity end) or 1000 end
                -- v6.6.42: the strength follows the hand's own speed (the old 1000 + 300/(m/s) sent a flick 28 m/s)
                local v = math.max(S.throw_speed_min or 450, math.min(S.throw_speed_max or 1500, (V62.tw.peak or 0) * (S.throw_speed_k or 130)))
                if v ~= V62.tw.v then pcall(function() pawn.ThrowVelocity = v end); V62.tw.v = v end
            end
            V62.tw.aim = V62.carry_aim
        end
    elseif V62.tw_held ~= nil then                             -- just let go: look at how it flies a moment later
        V62.tw_rel = { obj = V62.tw_held, t = T + 0.08, tw = (V62.tw ~= nil and not V62.tw.done) and V62.tw or nil }   -- (v6.6.45: a drop has no throw record)
        V62.tw_held = nil
        if V62.tw ~= nil then V62.tw.done = true end
    end
    local r = V62.tw_rel
    if r ~= nil and T >= r.t then
        V62.tw_rel = nil
        local v = nil
        if alive(r.obj) then
            v = safe(function() return r.obj:GetPhysicsLinearVelocity() end)
            if v == nil or (math.abs(v.X or 0) + math.abs(v.Y or 0) + math.abs(v.Z or 0)) < 1 then
                local ow = safe(function() return r.obj:GetOwner() end)
                local v2 = ow and safe(function() return ow:GetVelocity() end)
                if v2 ~= nil then v = v2 end
            end
        end
        local sp = v and math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2 + (v.Z or 0) ^ 2) or 0
        local tw = r.tw or {}
        V62.thn = (V62.thn or 0) + 1
        if V62.thn <= 20 then
            if sp > 50 then
                local fy = math.deg(math.atan(v.Y or 0, v.X or 0))
                local fp = math.deg(math.atan(v.Z or 0, math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2)))
                local hr = gh ~= nil and safe(function() return gh:K2_GetComponentRotation() end) or nil
                local aim = tw.aim or {}
                local function dy(x) if x == nil then return "?" end; return string.format("%+.0f", ((x - fy) + 540) % 360 - 180) end
                LOG(string.format("throw %d: flew %.0f cm/s at %.0f deg up | aim was %s deg from it, hand %s deg | hand speed %.1f m/s (body speed taken out), strength %s",
                    V62.thn, sp, fp, dy(aim[1]), dy(hr and hr.Yaw), tw.peak or 0, tw.v and string.format("%.0f", tw.v) or "game's"))
            else
                LOG(string.format("throw %d: let go (flight speed not readable) | hand speed %.1f m/s, strength %s", V62.thn, tw.peak or 0,
                    tw.v and string.format("%.0f", tw.v) or "game's"))
            end
        end
        if V62.tv0 ~= nil then pcall(function() pawn.ThrowVelocity = V62.tv0 end) end
    end
end
-- v6.6.17: BINOCULARS LIKE A SCOPE. A scene capture at your hand films along where the binoculars point (zoomed by
-- the game's own magnification) into a picture; the picture sits on a small flat panel just above the binoculars,
-- turned to face your eyes. Raise them to your face to look through. Nothing on your view, the game's screens or its
-- input is touched. Panel = an engine plane mesh with the engine's "widget pass-through" material showing the picture.
V62.binoc, V62.bl = {}, {}
function V62.v2(x, y) local v = StructObject.new(G.Vec2); v.X, v.Y = x, y; return v end
function V62.bino_make(pawn)
    local L = V62.bl
    if L.ok and alive(L.cap) and alive(L.panel) and same(L.pawn, pawn) then return true end
    L.ok = false
    local function lib(p) local c = api:find_uobject(p); return c and c:get_class_default_object() end
    local KRL = lib("Class /Script/Engine.KismetRenderingLibrary")
    local KMat = lib("Class /Script/Engine.KismetMaterialLibrary")
    local capc = api:find_uobject("Class /Script/Engine.SceneCaptureComponent2D")
    local smc = api:find_uobject("Class /Script/Engine.StaticMeshComponent")
    local mesh, mname = nil, nil
    for _, p in ipairs({ "StaticMesh /Engine/BasicShapes/Plane.Plane", "StaticMesh /Engine/BasicShapes/Cube.Cube",
                         "StaticMesh /Engine/EngineMeshes/Cube.Cube" }) do
        if mesh == nil then mesh = api:find_uobject(p); if mesh ~= nil then mname = p:match("([%w_]+)$") end end
    end
    local mat, matn = nil, nil
    for _, p in ipairs({ "MaterialInstanceConstant /Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque",
                         "Material /Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque",
                         "MaterialInstanceConstant /Engine/EngineMaterials/Widget3DPassThrough_Masked.Widget3DPassThrough_Masked",
                         "Material /Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough" }) do
        if mat == nil then mat = api:find_uobject(p); if mat ~= nil then matn = p:match("([%w_]+)$") end end
    end
    local miss = {}
    if KRL == nil then miss[#miss + 1] = "rendering library" end
    if KMat == nil then miss[#miss + 1] = "material library" end
    if capc == nil then miss[#miss + 1] = "scene capture" end
    if smc == nil then miss[#miss + 1] = "mesh component" end
    if mesh == nil then miss[#miss + 1] = "a flat engine mesh (Plane/Cube not in this game)" end
    if mat == nil then miss[#miss + 1] = "the pass-through material" end
    if G.LinColor == nil or G.KSL == nil then miss[#miss + 1] = "structs" end
    if #miss > 0 then L.why = table.concat(miss, ", ") .. " missing"; return false end
    local col = StructObject.new(G.LinColor); col.R, col.G, col.B, col.A = 0, 0, 0, 1
    local rt = KRL:CreateRenderTarget2D(pawn, 768, 768, 2, col, false, false)
    if rt == nil then L.why = "no render target"; return false end
    local cap = api:add_component_by_class(pawn, capc, false)
    if cap == nil then L.why = "no scene capture"; return false end
    cap.TextureTarget = rt
    cap.CaptureSource = 2
    cap.bCaptureEveryFrame = false
    pcall(function() cap.bCaptureOnMovement = false end)
    pcall(function() cap.bAlwaysPersistRenderingState = true end)
    pcall(function() cap:HideActorComponents(pawn, true) end)
    local kids = safe(function() return pawn.Children end)
    if type(kids) == "table" then for _, k in ipairs(kids) do pcall(function() cap:HideActorComponents(k, true) end) end end
    local panel = api:add_component_by_class(pawn, smc, false)
    if panel == nil then L.why = "no panel"; return false end
    pcall(function() panel:SetStaticMesh(mesh) end)
    pcall(function() panel:SetCollisionEnabled(0) end)
    pcall(function() panel:SetCastShadow(false) end)
    local mid = KMat:CreateDynamicMaterialInstance(pawn, mat, G.KSL:Conv_StringToName("None"), 0)
    if mid == nil then L.why = "no material instance"; return false end
    pcall(function() mid:SetTextureParameterValue(G.KSL:Conv_StringToName("SlateUI"), rt) end)
    pcall(function() panel:SetMaterial(0, mid) end)
    pcall(function() panel:SetVisibility(false, false) end)
    pcall(function() cap:HideComponent(panel) end)
    L.ok, L.pawn, L.cap, L.rt, L.panel, L.mid, L.flat = true, pawn, cap, rt, panel, mid, mname ~= "Plane"
    L.hit, L.hit2 = StructObject.new(G.Hit), StructObject.new(G.Hit)
    LOG("binoculars: scope-style picture built (" .. tostring(mname) .. " + " .. tostring(matn) .. ")")
    return true
end
function V62.bino_parts(actor)                              -- once: what the binoculars are made of (for the lenses later)
    if V62.bino_parts_done or actor == nil then return end
    V62.bino_parts_done = true
    local out = {}
    local c, k = actor:get_class(), 0
    while c ~= nil and k < 3 do
        local p = c:get_child_properties()
        while p ~= nil and #out < 40 do
            if p:get_class():get_name() == "ObjectProperty" then
                local n = p:get_fname():to_string()
                local v = safe(function() return actor[n] end)
                if v ~= nil and type(v) == "userdata" then
                    local cn = safe(function() return shortclass(v) end) or "?"
                    if cn:find("Component") then out[#out + 1] = n .. "=" .. cn end
                end
            end
            p = p:get_next()
        end
        c, k = c:get_super_struct(), k + 1
    end
    LOG("binoculars: parts: " .. table.concat(out, ", "))
end
function V62.bino_live_on(pawn)
    if not V62.bino_make(pawn) then return false end
    local L, b = V62.bl, V62.binoc
    local mag = safe(function() return pawn.WepMagnification end) or 5
    if type(mag) ~= "number" or mag < 1.5 then mag = 5 end
    L.cap.FOVAngle = math.max(4, math.min(60, 90 / mag))
    L.cap.bCaptureEveryFrame = true
    pcall(function() L.panel:SetVisibility(true, false) end)
    pcall(V62.bino_parts, cur and cur.actor)
    b.n = (b.n or 0) + 1
    if b.n <= 10 then LOG(string.format("binoculars up: picture on the binoculars, %.1fx (field of view %.0f deg)", mag, 90 / mag)) end
    return true
end
function V62.bino_live_off()
    local L, b = V62.bl, V62.binoc
    if L.cap ~= nil and alive(L.cap) then pcall(function() L.cap.bCaptureEveryFrame = false end) end
    if L.panel ~= nil and alive(L.panel) then pcall(function() L.panel:SetVisibility(false, false) end) end
    if (b.n or 0) <= 10 then LOG("binoculars down") end
end
function V62.bino_place(hx, hy, hz, F)                       -- per-eye callback, view 0 (the hand was just moved)
    local L = V62.bl
    if V62.binoc.mode ~= "live" or not L.ok or not alive(L.cap) or not alive(L.panel) then return end
    local l, r = hand_ray()
    if l == nil or r == nil then return end
    local lx, ly, lz = l.X or 0, l.Y or 0, l.Z or 0
    -- the camera: at the hand, along where the binoculars / your hand point
    L.cap:K2_SetWorldLocationAndRotation(mkvec(lx, ly, lz), mkrot(r.Pitch or 0, r.Yaw or 0, 0), false, L.hit, true)
    -- the picture: 7 cm above the hand, 4 cm toward your eyes, facing your eyes
    local ex, ey, ez = hx - lx, hy - ly, hz - lz
    local el = math.sqrt(ex * ex + ey * ey + ez * ez)
    if el < 1 then return end
    ex, ey, ez = ex / el, ey / el, ez / el
    local px, py, pz = lx + ex * 4, ly + ey * 4, lz + 7 + ez * 4
    local zx, zy, zz = hx - px, hy - py, hz - pz                 -- panel normal: toward the eyes
    local zl = math.sqrt(zx * zx + zy * zy + zz * zz)
    if zl < 1 then return end
    zx, zy, zz = zx / zl, zy / zl, zz / zl
    local d = zz                                                 -- "up" on the picture = world up, flattened
    local ux, uy, uz = -zx * d, -zy * d, 1 - zz * d
    local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
    if ul < 0.01 then return end
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    local rx, ry, rz = zy * uz - zz * uy, zz * ux - zx * uz, zx * uy - zy * ux   -- z x up
    local o = (S.bino_orient or 0) % 4
    local ax, ay, az = ux, uy, uz                                -- the panel's X axis
    if o == 1 then ax, ay, az = rx, ry, rz elseif o == 2 then ax, ay, az = -ux, -uy, -uz elseif o == 3 then ax, ay, az = -rx, -ry, -rz end
    local rot = G.KML:MakeRotFromXZ(mkvec(ax, ay, az), mkvec(zx, zy, zz))
    local sz = (S.bino_size or 11) / 100
    local mir = (S.bino_orient or 0) >= 4 and -1 or 1
    L.panel:K2_SetWorldLocationAndRotation(mkvec(px, py, pz), rot, false, L.hit2, true)
    L.panel:SetWorldScale3D(mkvec(sz, sz * mir, L.flat and 0.002 or 1))
end
-- v6.6.25: BINOCULARS = THE GAME'S OWN SCOPE ON THEM. The game's scope actors (e.g. the ACOG child actor on the HMP:
-- a SceneCapture + a lens showing its picture) render correctly in VR. One is spawned as a child actor of the held
-- binoculars (ChildActorComponent on the item's static mesh, SetChildActorClass), at the eye end, enlarged, body
-- meshes hidden; its capture is switched on while the player aims (left trigger) and its FOV set from the game's own
-- WepMagnification. A flat panel (engine Plane + Widget3DPassThrough, SlateUI = the scope's own render target) shows the
-- same picture at the eye end as a second surface. The scope class is learned from any gun that carries one.
V62.bs = {}
function V62.bino_libs()
    G.CAC = G.CAC or api:find_uobject("Class /Script/Engine.ChildActorComponent")
    G.CAP2D = G.CAP2D or api:find_uobject("Class /Script/Engine.SceneCaptureComponent2D")
    G.SMC = G.SMC or api:find_uobject("Class /Script/Engine.StaticMeshComponent")
    return G.CAC ~= nil and G.CAP2D ~= nil and G.SMC ~= nil
end
function V62.scope_learn(actor, label)                        -- a gun in hand: does it carry a scope child actor?
    if actor == nil or not V62.bino_libs() then return end
    local comps = safe(function() return actor:K2_GetComponentsByClass(G.CAC) end)
    if type(comps) ~= "table" then return end
    for _, c in ipairs(comps) do
        local n = safe(function() return c:get_fname():to_string() end) or ""
        local cls = safe(function() return c.ChildActorClass end)
        local cn = cls and (safe(function() return cls:get_fname():to_string() end) or "") or ""
        if cls ~= nil and (n:lower():find("scope", 1, true) or cn:lower():find("scope", 1, true)) then
            local full = safe(function() return cls:get_full_name() end)
            local function score(nm) local l = (nm or ""):lower(); return (l:find("digizoom", 1, true) and 30 or 0) + (l:find("zoom", 1, true) and 10 or 0) + (l:find("acog", 1, true) and 5 or 0) + (l:find("reddot", 1, true) and 1 or 0) end
            if full ~= nil and full ~= "" and S.bino_scope_class ~= full and score(cn) >= score(S.bino_scope_class) then   -- v6.6.26: keep the best
                S.bino_scope_class = full; save_settings()
                V62.bs.cls = nil
                LOG("binoculars: the game's scope " .. cn .. " (on " .. tostring(label) .. ") will be borrowed for the binoculars - remembered")
            end
            return
        end
    end
end
function V62.scope_class()
    local B = V62.bs
    if B.cls ~= nil and safe(function() return UEVR_UObjectHook.exists(B.cls) end) == true then return B.cls end
    B.cls = nil
    if (S.bino_scope_class or "") ~= "" then
        B.cls = api:find_uobject(S.bino_scope_class)
        if B.cls ~= nil then return B.cls end
    end
    if T - (B.scan_t or -100) < 5 then return nil end
    B.scan_t = T
    local bgc = api:find_uobject("Class /Script/Engine.BlueprintGeneratedClass")
    local all = bgc and safe(function() return UEVR_UObjectHook.get_objects_by_class(bgc, false) end)
    if type(all) ~= "table" then return nil end
    local best, bests, names = nil, -1, {}
    for _, c in ipairs(all) do
        local n = safe(function() return c:get_fname():to_string() end) or ""
        local l = n:lower()
        if l:find("scope", 1, true) and n:sub(-2) == "_C" and not l:find("widget", 1, true) and not l:find("anim", 1, true) and not l:find("mesh", 1, true) then
            names[#names + 1] = n
            local sc = (l:find("digizoom", 1, true) and 30 or 0) + (l:find("zoom", 1, true) and 10 or 0) + (l:find("acog", 1, true) and 5 or 0) + (l:find("reddot", 1, true) and 1 or 0)
            if sc > bests then best, bests = c, sc end
        end
    end
    if #names > 0 then LOG("binoculars: scope classes in this game: " .. table.concat(names, ", ")) end
    if best ~= nil then
        S.bino_scope_class = safe(function() return best:get_full_name() end) or ""
        if S.bino_scope_class ~= "" then save_settings() end
        B.cls = best
    end
    return B.cls
end
function V62.bino_destroy()
    local B = V62.bs
    if B.comp ~= nil and obj_ok(B.comp) then pcall(function() B.comp:K2_DestroyComponent(B.comp) end) end
    if B.plane ~= nil and obj_ok(B.plane) then pcall(function() B.plane:K2_DestroyComponent(B.plane) end) end
    B.comp, B.actor, B.cap, B.plane, B.owner, B.was_want = nil, nil, nil, nil, nil, nil
end
function V62.bino_build(pawn)                                 -- returns nil, or why not
    local B = V62.bs
    if not V62.bino_libs() or G.KSL == nil or G.NONE == nil then return "engine parts not ready" end
    local cls = V62.scope_class()
    if cls == nil then return "no scope to borrow yet - hold a gun with a scope once (it is remembered from then on)" end
    local cn = safe(function() return cls:get_fname():to_string() end) or "?"
    local mesh = safe(function() return cur.actor.SM_Item_Binoculars_01 end)
    if mesh == nil or not alive(mesh) then
        local sms = safe(function() return cur.actor:K2_GetComponentsByClass(G.SMC) end)
        mesh = type(sms) == "table" and sms[1] or nil
    end
    if mesh == nil then return "the binoculars have no mesh to mount the scope on" end
    local hit = StructObject.new(G.Hit)
    local sc = S.bino_scope_scale or 2
    if S.bino_lens ~= false then
        local comp = api:add_component_by_class(cur.actor, G.CAC, false)
        if comp == nil then return "could not add the scope holder" end
        comp:K2_AttachToComponent(mesh, G.NONE, 2, 2, 2, false)
        set_rel(comp, S.bino_scope_x or -12, 0, S.bino_scope_z or 6, 0, S.bino_scope_yaw or 0, 0)
        pcall(function() comp:SetRelativeScale3D(mkvec(sc, sc, sc)) end)
        local ok, e = pcall(function() comp:SetChildActorClass(cls) end)
        if not ok then pcall(function() comp:K2_DestroyComponent(comp) end); return "the game refused the scope (" .. tostring(e) .. ")" end
        local actor = safe(function() return comp.ChildActor end)
        if actor == nil then pcall(function() comp:K2_DestroyComponent(comp) end); return "the scope did not appear" end
        B.comp, B.actor, B.owner = comp, actor, cur.actor
        local caps = safe(function() return actor:K2_GetComponentsByClass(G.CAP2D) end)
        B.cap = type(caps) == "table" and caps[1] or nil
        -- v6.6.26: this game's scopes zoom with a post-process effect, not a camera
        G.PPC = G.PPC or api:find_uobject("Class /Script/Engine.PostProcessComponent")
        local pps = G.PPC and safe(function() return actor:K2_GetComponentsByClass(G.PPC) end)
        B.pp = type(pps) == "table" and pps[1] or nil
        B.lense = safe(function() return actor.Lense end)
        B.mid = safe(function() return actor.CrosshairDynamicMat end)
        B.mag_ok = type(safe(function() return actor.Magnification end)) == "number"
        if B.mid ~= nil and not B.mid_logged then                 -- its zoom effect's values, once (which ones to drive)
            B.mid_logged = true
            local out = {}
            local sp = safe(function() return B.mid.ScalarParameterValues end)
            if type(sp) == "table" then for _, e in ipairs(sp) do
                local nm = safe(function() return e.ParameterInfo.Name:to_string() end) or "?"
                out[#out + 1] = nm .. "=" .. tostring(safe(function() return e.ParameterValue end))
            end end
            LOG("binoculars: the scope's zoom effect values: " .. (#out > 0 and table.concat(out, ", ") or "not readable"))
        end
        -- the lens where the eyepieces are: shift the mount so the Lense part lands on the target
        if B.lense ~= nil and G.KML ~= nil then
            pcall(function()
                local lw = B.lense:K2_GetComponentLocation()
                local mt = mesh:K2_GetComponentToWorld()
                local lr = G.KML:InverseTransformLocation(mt, lw)
                local cr = comp.RelativeLocation
                local tx, tz = S.bino_scope_x or -17, S.bino_scope_z or 6
                set_rel(comp, (cr.X or 0) + tx - (lr.X or 0), (cr.Y or 0) + 0 - (lr.Y or 0), (cr.Z or 0) + tz - (lr.Z or 0), 0, S.bino_scope_yaw or 0, 0)
            end)
        end
        if S.bino_scope_body ~= true then                       -- lens only
            local sms = safe(function() return actor:K2_GetComponentsByClass(G.SMC) end) or {}
            local keep = {}
            for _, m in ipairs(sms) do
                local n = (safe(function() return m:get_fname():to_string() end) or ""):lower()
                if n:find("lens", 1, true) or n:find("glass", 1, true) or n:find("ret", 1, true) or n:find("screen", 1, true) or n:find("optic", 1, true) or same(m, B.lense) then keep[#keep + 1] = m end
            end
            if #keep > 0 and #keep < #sms then
                for _, m in ipairs(sms) do
                    local k = false
                    for _, l in ipairs(keep) do if same(l, m) then k = true end end
                    if not k then pcall(function() m:SetVisibility(false, false) end) end
                end
                B.body_hidden = #sms - #keep
            end
        end
    end
    if S.bino_plane ~= false then
        local rt = B.cap and safe(function() return B.cap.TextureTarget end) or nil
        if rt == nil then
            if not B.nort then B.nort = true; LOG("binoculars: the borrowed scope has no picture texture - the flat picture is not possible") end
        else
            local function lib(p) local c = api:find_uobject(p); return c and c:get_class_default_object() end
            local KMat = lib("Class /Script/Engine.KismetMaterialLibrary")
            local pm = api:find_uobject("StaticMesh /Engine/BasicShapes/Plane.Plane")
            local mat = api:find_uobject("MaterialInstanceConstant /Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque")
                or api:find_uobject("Material /Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough")
            if KMat ~= nil and pm ~= nil and mat ~= nil then
                local panel = api:add_component_by_class(cur.actor, G.SMC, false)
                if panel ~= nil then
                    pcall(function() panel:SetStaticMesh(pm) end)
                    pcall(function() panel:SetCollisionEnabled(0) end)
                    pcall(function() panel:SetCastShadow(false) end)
                    local mid = KMat:CreateDynamicMaterialInstance(pawn, mat, G.NONE, 0)
                    if mid ~= nil then
                        pcall(function() mid:SetTextureParameterValue(G.KSL:Conv_StringToName("SlateUI"), rt) end)
                        pcall(function() panel:SetMaterial(0, mid) end)
                    end
                    panel:K2_AttachToComponent(mesh, G.NONE, 2, 2, 2, false)
                    local o = (S.bino_orient or 0) % 4
                    set_rel(panel, S.bino_plane_x or -17.5, 0, S.bino_plane_z or 6, 90, 0, 90 * o)
                    local sz = (S.bino_size or 11) / 100
                    pcall(function() panel:SetRelativeScale3D(mkvec(sz, (S.bino_orient or 0) >= 4 and -sz or sz, 1)) end)
                    pcall(function() panel:SetVisibility(false, false) end)
                    if B.cap then pcall(function() B.cap:HideComponent(panel) end) end
                    B.plane, B.mid = panel, mid
                end
            else
                if not B.noplane then B.noplane = true; LOG("binoculars: flat picture not possible (engine plane / material missing)") end
            end
        end
    end
    LOG(string.format("binoculars: the game's %s is on the binoculars%s%s%s", cn,
        B.cap and " with its camera" or (B.pp and " with its zoom effect" or " (NO camera and NO zoom effect found on it)"),
        B.body_hidden and (", body hidden (" .. B.body_hidden .. " parts)") or "",
        B.plane and ", plus a flat picture of the same view" or ""))
    return nil
end
function V62.bino_scope_update(pawn, is_bino, want)
    local B, b = V62.bs, V62.binoc
    if not is_bino then
        if B.comp ~= nil or B.plane ~= nil then V62.bino_destroy() end
        V62.binoc_on = false
        return
    end
    if (B.comp == nil and B.plane == nil) or (B.comp ~= nil and not obj_ok(B.comp)) or not same(B.owner, cur.actor) then
        if T - (B.try_t or -100) < 2.0 then return end
        B.try_t = T
        V62.bino_destroy()
        local why = V62.bino_build(pawn)
        if why ~= nil then
            B.fails = (B.fails or 0) + 1
            if B.fails <= 6 and why ~= B.last_why then B.last_why = why; LOG("binoculars: " .. why) end
            return
        end
    end
    if want ~= B.was_want then
        local was = B.was_want
        B.was_want = want
        if want then
            local mag = (S.bino_zoom or 0) > 0 and S.bino_zoom or (safe(function() return pawn.WepMagnification end) or 5)
            if type(mag) ~= "number" or mag < 1.5 then mag = 5 end
            B.fov = math.max(4, math.min(60, 90 / mag))
            if B.plane ~= nil and obj_ok(B.plane) then pcall(function() B.plane:SetVisibility(true, false) end) end
            b.n = (b.n or 0) + 1
            B.mag = mag
            if b.n <= 10 then LOG(string.format("binoculars up: looking through the borrowed scope, %.1fx%s", mag, (B.cap or B.pp) and "" or " - no camera and no zoom effect!")) end
        else
            if B.plane ~= nil and obj_ok(B.plane) then pcall(function() B.plane:SetVisibility(false, false) end) end
            if was == true and (b.n or 0) <= 10 then LOG("binoculars down") end
        end
    end
    V62.binoc_on = want
    b.mode = "scope"
    V62.bino_flags()
end
function V62.bino_flags()                                     -- every tick, also after the game's own tick (post tick)
    local B = V62.bs
    local w = B.was_want == true
    local cap = B.cap
    if cap ~= nil and obj_ok(cap) then
        pcall(function()
            if cap.bCaptureEveryFrame ~= w then cap.bCaptureEveryFrame = w end
            if cap.bCaptureOnMovement ~= w then cap.bCaptureOnMovement = w end
            if w and B.fov ~= nil and math.abs((cap.FOVAngle or 0) - B.fov) > 0.01 then cap.FOVAngle = B.fov end
        end)
    end
    if B.actor == nil or not obj_ok(B.actor) then return end
    -- v6.6.27: keep the binoculars visible while aiming (the game hides them) and the scope's body hidden (its script
    -- re-shows it); the lens follows the aim state
    pcall(function()
        if cur ~= nil and alive(cur.actor) then
            local hidden = cur.actor.bHidden
            if hidden == true then cur.actor:SetActorHiddenInGame(false); B.reshown = (B.reshown or 0) + 1 end
            local bm = cur.actor.SM_Item_Binoculars_01
            if bm ~= nil and bm:IsVisible() ~= true then bm:SetVisibility(true, false); B.reshown = (B.reshown or 0) + 1 end
            if B.reshown ~= nil and not B.reshown_logged and B.reshown >= 1 then B.reshown_logged = true; LOG("binoculars: the game hides the binoculars while you aim - kept visible") end
        end
        if B.actor.bHidden == true then B.actor:SetActorHiddenInGame(false) end
        if S.bino_scope_body ~= true then
            local sm = B.actor.Scope_Mesh
            if sm ~= nil and sm:IsVisible() == true then sm:SetVisibility(false, false); B.rehid = (B.rehid or 0) + 1 end
            if B.rehid ~= nil and not B.rehid_logged and B.rehid >= 2 then B.rehid_logged = true; LOG("binoculars: the scope's script keeps showing its body - hidden every frame") end
        end
    end)
    if S.bino_pp_drive == false then return end
    -- v6.6.26: the post-process zoom: on while aiming, from any distance; magnification = the binoculars'
    pcall(function()
        if B.pp ~= nil and obj_ok(B.pp) then
            if B.pp.bEnabled ~= w then B.pp.bEnabled = w end
            if B.pp.bUnbound ~= w then B.pp.bUnbound = w end
            if w and (B.pp.BlendWeight or 1) < 0.99 then B.pp.BlendWeight = 1.0 end
        end
        if B.lense ~= nil and obj_ok(B.lense) and B.lense:IsVisible() ~= w then B.lense:SetVisibility(w, false) end
        if w and B.mag_ok and B.mag ~= nil and math.abs((B.actor.Magnification or 0) - B.mag) > 0.01 then B.actor.Magnification = B.mag end
        if w and B.mag ~= nil and B.mid ~= nil and obj_ok(B.mid) and T >= (B.mid_t or 0) then
            B.mid_t = T + 0.5
            local sp = B.mid.ScalarParameterValues
            if type(sp) == "table" then for _, e in ipairs(sp) do
                local nm = e.ParameterInfo.Name:to_string()
                local l = nm:lower()
                if (l:find("mag", 1, true) or l:find("zoom", 1, true)) and math.abs((e.ParameterValue or 0) - B.mag) > 0.01 then
                    B.mid:SetScalarParameterValue(e.ParameterInfo.Name, B.mag)
                    B.midn = (B.midn or 0) + 1
                    if B.midn <= 3 then LOG("binoculars: zoom effect value " .. nm .. " set to " .. tostring(B.mag)) end
                end
            end end
        end
    end)
end
function V62.binoc_update(pawn, delta)
    local b = V62.binoc
    if not S.binoculars_2d then return end
    local is_bino = cur ~= nil and cur.cls:find("Binocular") ~= nil
    local want = is_bino and not menu_mode and lvl.ready and safe(function() return pawn.Aiming end) == true   -- v6.6.15: aiming only
    if want then b.on_t = (b.on_t or 0) + delta else b.on_t = 0 end
    if menu_mode and V62.binoc_on then
        if b.mode == "scope" then V62.binoc_on = false; return end   -- v6.6.25: the scope stays, the menu takes the view
        if b.mode == "live" then V62.bino_live_off() end
        V62.binoc_on, b.flip_t = false, T
        LOG("binoculars: a menu opened - the menu takes over the view")
        return
    end
    if (S.binocular_mode or 1) == 0 then return end              -- v6.6.17: off - binoculars as the game has them
    if (S.binocular_mode or 1) == 1 then                         -- v6.6.25: the game's scope on the binoculars
        guarded("binoscope", V62.bino_scope_update, pawn, is_bino, want)
        return
    end
    if (S.binocular_mode or 1) == 1 and not b.live_failed then
        if not V62.binoc_on and want and b.on_t > 0.12 then
            if V62.bino_live_on(pawn) then V62.binoc_on, b.mode = true, "live"
            else b.live_failed = true; LOG("binoculars: picture on the binoculars not possible (" .. tostring(V62.bl.why) .. ") - binoculars left as the game has them") end
        elseif V62.binoc_on and b.mode == "live" and not want then
            V62.bino_live_off(); V62.binoc_on = false
        end
        return                                                   -- v6.6.17: never falls back to the flat view by itself
    end
    -- the flat view (v6.6.14): UEVR's 2D screen, head-locked; flips at least 1 s apart (v4.22 crash rule)
    local since = T - math.max(last_menu_flip or -100, b.flip_t or -100)
    if not V62.binoc_on and want and b.on_t > 0.3 and since > 1.0 then
        V62.binoc_on, b.mode, b.flip_t, last_menu_flip = true, "flat", T, T
        b.saved = { follow = getmod("UI_FollowView"), dist = getmod("UI_Distance"), size = getmod("UI_Size"),
                    x = getmod("UI_X_Offset"), y = getmod("UI_Y_Offset") }
        setmod("UI_FollowView", "true"); setmod("UI_Distance", "0.55"); setmod("UI_Size", "1.25")
        setmod("UI_X_Offset", "0.000"); setmod("UI_Y_Offset", "0.000")
        setmod("VR_2DScreenMode", "true")
        b.n = (b.n or 0) + 1
        if b.n <= 10 then LOG("binoculars up: the game's flat binocular view") end
    elseif V62.binoc_on and b.mode == "flat" and not want and since > 1.0 then
        V62.binoc_on, b.flip_t, last_menu_flip = false, T, T
        setmod("VR_2DScreenMode", "false")
        local sv = b.saved or {}
        setmod("UI_FollowView", (sv.follow ~= nil and sv.follow ~= "") and sv.follow or "false")
        if sv.dist ~= nil and sv.dist ~= "" then setmod("UI_Distance", sv.dist) end
        if sv.size ~= nil and sv.size ~= "" then setmod("UI_Size", sv.size) end
        if sv.x ~= nil and sv.x ~= "" then setmod("UI_X_Offset", sv.x) end
        if sv.y ~= nil and sv.y ~= "" then setmod("UI_Y_Offset", sv.y) end
        if (b.n or 0) <= 10 then LOG("binoculars down: back to VR") end
    end
end
-- v6.6.14/15: whole-view FADE (sf_kbd.dll -> SteamVR compositor). Starts the moment the game adds a black screen (its
-- loading screen or its fade-to-black screen - both hidden), or when the game moves the camera away from you (bed);
-- ends 0.4 s after none of that is going on. The plugin itself undoes a black fade that isn't renewed within 25 s.
V62.BLACK = { LoadingScreen_Widget_C = true, FadeToBlack_Widget_C = true }
V62.blk = {}
function V62.fade(on, why)
    if not S.transition_fade then return end
    if on then
        if not V62.faded then
            V62.faded, V62.fade_t0, V62.fade_sent = true, T, T
            pcall(function() api:dispatch_custom_event("sfkbd", "fade 0.15 1") end)
            V62.fdn = (V62.fdn or 0) + 1
            if V62.fdn <= 20 then LOG("fade: view fading to black (" .. tostring(why) .. ")") end
        elseif T - (V62.fade_sent or 0) > 5 then
            V62.fade_sent = T
            pcall(function() api:dispatch_custom_event("sfkbd", "fade 0 1") end)   -- still going: keep it black
        end
    elseif V62.faded then
        V62.faded = false
        pcall(function() api:dispatch_custom_event("sfkbd", "fade 0.6 0") end)
        if (V62.fdn or 0) <= 20 then LOG(string.format("fade: view fading back in (%.1f s black)", T - (V62.fade_t0 or T))) end
        V62.mc = { t = T, max = 0, n = 0, feats = {}, what = "after the fade-in" }   -- v6.6.18: watch the next 4 s for stutters
    end
end
function V62.fade_update(delta)
    if not S.transition_fade then return end
    -- v6.6.18: black until your hands have been yours for a moment (the tester: ~1/4 s without hands after the fade-in);
    -- with no player body at all (main menu) only the loading screen holds it
    local hold = lvl.loading or (V62.lv_pawn ~= nil and (not lvl.free or not lvl.ready
        or (lvl.ready_t ~= nil and T - lvl.ready_t < (S.fade_hands_wait or 0.5))))
    for k, w in pairs(V62.blk) do
        if alive(w) and safe(function() return w:IsInViewport() end) == true then
            hold = true
            if S.hide_loading_box then pcall(function() w:SetRenderOpacity(0.0) end) end
        else V62.blk[k] = nil end
    end
    if S.camera_away_fade ~= false and lvl.free and view.ok == false and V62.view_away_t ~= nil and T - V62.view_away_t > 0.05 then
        -- v6.6.16: only for sleeping (the sleep screen was up in the last 30 s, or the camera is on a bed / sleep thing)
        local vt = safe(function() return api:get_player_controller(0):GetViewTarget() end)
        local vn = vt and shortclass(vt) or "?"
        local sleepy = (V62.sleep_t ~= nil and T - V62.sleep_t < 30) or vn:lower():find("bed") ~= nil or vn:lower():find("sleep") ~= nil
        if sleepy then
            hold = true
            if not V62.faded then V62.fade(true, "sleeping - the game moved the camera to " .. vn) end
        elseif V62.away_logged ~= V62.view_away_t then
            V62.away_logged = V62.view_away_t
            V62.awn = (V62.awn or 0) + 1
            if V62.awn <= 15 then LOG("camera: the game moved the camera to " .. vn .. " - not faded (not sleeping)") end
        end
    end
    if hold then
        V62.fade_clear = nil
        if V62.faded then V62.fade(true) end                   -- renews the plugin's 25 s safety
    elseif V62.faded then
        V62.fade_clear = V62.fade_clear or T
        if T - V62.fade_clear > 0.4 then V62.fade(false) end
    end
    if V62.faded and not lvl.loading and T - (V62.fade_t0 or T) > 60 then V62.fade(false) end   -- safety
end
-- v6.6.43: THE HUD ON THE LOADING SCREEN. The game adds a fresh HUD to the screen at the start of every level load; the
-- flat game covers it with the loading screen's black box, which the mod makes see-through (the view is faded to black
-- instead) - so the HUD showed on the loading screen until the mod took it onto its VR panel at level-ready. Hidden
-- (render opacity 0, re-checked 4x a second in case the game's own fade-in sets it back) from the moment it is added
-- until it sits on the panel; shown again after 40 s whatever happens.
function V62.hud_unhide(why)                                   -- every hidden HUD shown again
    local hs = V62.hh
    if hs == nil then return end
    V62.hh = nil
    for _, h in ipairs(hs) do
        if obj_ok(h.w) then pcall(function() h.w:SetRenderOpacity(1.0) end) end
    end
    if why ~= nil and why:find("safety", 1, true) and (V62.hun or 0) < 3 then V62.hun = (V62.hun or 0) + 1; LOG("HUD: shown again (" .. why .. ")") end
end
function V62.hud_hide(w)
    if S.hud_hide_loading == false or not S.wrist_hud then return end
    -- only around a load: before the level is ready, while the loading screen is up or while the view is faded to black
    if lvl ~= nil and lvl.ready and not lvl.loading and not V62.faded then return end
    local hs = V62.hh or {}
    for _, h in ipairs(hs) do if same(h.w, w) then return end end
    if #hs >= 4 then return end                                 -- (a load makes one or two)
    if not pcall(function() w:SetRenderOpacity(0.0) end) then return end
    hs[#hs + 1] = { w = w, t = T, chk = T }
    V62.hh = hs
    V62.hhn = (V62.hhn or 0) + 1
    if V62.hhn <= 2 then LOG("HUD: hidden while the level loads (it used to show on the loading screen) - back as soon as it is on its VR panel") end
end
function V62.hud_hide_tick()                                   -- game tick, only while a HUD is hidden
    local hs = V62.hh
    if hs == nil then return end
    if S.hud_hide_loading == false or not S.wrist_hud then V62.hud_unhide("switched off"); return end
    local newest = 0
    for i = #hs, 1, -1 do
        local h = hs[i]
        if not obj_ok(h.w) then table.remove(hs, i)
        else
            if h.t > newest then newest = h.t end
            if T - h.chk > 0.25 then                            -- the game's own fade-in may set it back
                h.chk = T
                local o = safe(function() return h.w:GetRenderOpacity() end)
                if type(o) == "number" and o > 0.01 then pcall(function() h.w:SetRenderOpacity(0.0) end) end
            end
        end
    end
    if #hs == 0 then V62.hh = nil; return end
    if T - newest > 40 then V62.hud_unhide("safety: 40 s without reaching its VR panel") end
end
-- v6.6.43: HINT TEXTS. Which screens count as hints / prompts, and reading their texts through sf_txt.dll (UEVR's Lua
-- cannot read the engine's text values). V62.txt_read(widget) -> { { name = <property>, text = <text> }, ... } or nil.
V62.HINT_WORDS = { "tutorial", "hint", "tip", "prompt", "keybind", "control", "input", "allert", "alert", "notif", "popup", "message" }
function V62.hint_like(lc)
    for _, wd in ipairs(V62.HINT_WORDS) do if lc:find(wd, 1, true) then return true end end
    return false
end
function V62.txt_read(w)
    local a = w and addr(w)
    if a == nil then return nil end
    V62.txt_raw = nil
    pcall(function() api:dispatch_custom_event("sftxt", string.format("texts %x", a)) end)
    local raw = V62.txt_raw
    if type(raw) ~= "string" then return nil end
    if raw:sub(1, 5) ~= "texts" then V62.txt_err = raw; return nil end
    local out = {}
    for name, text in raw:gmatch("\31([^\30]*)\30([^\31]*)") do out[#out + 1] = { name = name, text = text } end
    return out
end
function V62.txt_set(w, text)                                  -- -> true when the plugin set it (TextBlock / RichTextBlock)
    local a = w and addr(w)
    if a == nil or type(text) ~= "string" or text == "" then return false end
    V62.txt_raw = nil
    pcall(function() api:dispatch_custom_event("sftxt", string.format("set %x %s", a, (text:gsub("\n", "\\n")))) end)
    return V62.txt_raw == "set ok"
end
-- v6.6.48: THE TRADE SCREEN, read for a one-click "add the money this trade needs" (the game's add-money slider is
-- fiddly with a VR pointer). Everything here runs in the game tick, never inside the hook, and only reads.
-- Once per session: the screen's make-up without the item cards (v6.6.45's listing ran out of lines inside them), and
-- the names of the screen's own variables and functions. While the screen is open: its number / on-off variables and
-- its sliders, written whenever one changes - that shows which is the money offered and which the value still missing.
function V62.barter_tree(w, depth, n)
    if w == nil or n.c >= 400 then return end
    local cn = shortclass(w)
    if cn == "ItemCard_C" then n.cards = (n.cards or 0) + 1; return end
    n.c = n.c + 1
    local name = fullname(w):match("([^%.:]+)$") or "?"
    local extra = ""
    if cn == "Slider" or cn == "SpinBox" then
        n.sliders[#n.sliders + 1] = { name, w }
        extra = string.format(" value=%s min=%s max=%s step=%s", tostring(safe(function() return w:GetValue() end)),
            tostring(safe(function() return w.MinValue end)), tostring(safe(function() return w.MaxValue end)), tostring(safe(function() return w.StepSize end)))
    end
    if not n.quiet then LOG(string.rep("  ", depth + 1) .. cn .. " '" .. name .. "' vis=" .. tostring(safe(function() return w:GetVisibility() end)) .. extra) end
    local cnt = safe(function() return w:GetChildrenCount() end)
    if type(cnt) == "number" then
        for i = 0, math.min(cnt, 60) - 1 do V62.barter_tree(safe(function() return w:GetChildAt(i) end), depth + 1, n) end
    end
    local root = safe(function() return w.WidgetTree.RootWidget end)
    if root ~= nil then V62.barter_tree(root, depth + 1, n) end
end
function V62.class_list(w)                                     -- the screen's own class and its parents, up to the engine's widget class
    local c = safe(function() return w:get_class() end)
    V62.bprops = {}
    for level = 1, 4 do
        if c == nil then break end
        local cname = safe(function() return c:get_fname():to_string() end) or "?"
        if cname == "UserWidget" or cname == "Widget" or cname == "Visual" or cname == "Object" then break end
        local props, funcs = {}, {}
        local f, guard = safe(function() return c:get_child_properties() end), 0
        while f ~= nil and guard < 400 do
            guard = guard + 1
            local nm = safe(function() return f:get_fname():to_string() end)
            local ty = safe(function() return f:get_class():get_fname():to_string() end)
            if nm ~= nil then
                props[#props + 1] = nm .. ":" .. tostring(ty)
                V62.bprops[#V62.bprops + 1] = { nm, ty }
            end
            local cur_f = f
            f = safe(function() return cur_f:get_next() end)
        end
        local u = safe(function() return c:get_children() end)
        guard = 0
        while u ~= nil and guard < 400 do
            guard = guard + 1
            local nm = safe(function() return u:get_fname():to_string() end)
            if nm ~= nil then funcs[#funcs + 1] = nm end
            local cur_u = u
            u = safe(function() return cur_u:get_next() end)
        end
        LOG("trade screen: class " .. cname .. " has " .. #props .. " variables and " .. #funcs .. " functions")
        local function chunks(label, list)
            local line = ""
            for _, x in ipairs(list) do
                if #line + #x > 900 then LOG("   " .. label .. ": " .. line); line = "" end
                line = line .. (line == "" and "" or ", ") .. x
            end
            if line ~= "" then LOG("   " .. label .. ": " .. line) end
        end
        chunks("variables", props); chunks("functions", funcs)
        local cur_c = c
        c = safe(function() return cur_c:get_super() end)
    end
end
-- v6.6.51: "ADD MONEY" WITHOUT THE FIDDLING. The game's Add Money is a sliding scale under the cursor: the amount
-- follows the cursor left / right and a click takes it - hard to stop on the right spot with a VR pointer. From the
-- fifth playtest's log: the screen's TradeBalance follows the slider live (0 .. 1, your share of the deal), and the
-- trader's two marks on the bar are MinBalance (the least he takes) and IdealBalance.
-- So: when IsAddingMoney turns true, the script takes the cursor for about a second, slides it to the first spot where
-- the balance reaches the mark, and holds it there (a buzz). Your click takes the amount - through the game's own
-- slider and the game's own click, so it can never offer more than you have, and nothing is written into the game.
-- Move your hand away and the cursor is yours again. Not enough money for the mark: a long buzz, the cursor is yours.
-- The search: steps of 2.5% of the screen until the balance crosses the mark, then halving down to one pixel. Every
-- spot is given a few frames before its answer is read (the game answers a cursor move a frame or two later), and
-- both ends are checked again before it holds.
function V62.money_say(text)
    V62.mny_lines = (V62.mny_lines or 0) + 1
    if V62.mny_lines <= 60 then LOG("trade: Add Money - " .. text) end
end
function V62.money_step(m)                                     -- one coarse step; false = the edge of the screen
    local x = math.max(1, math.min(m.vw - 2, m.x + m.dir * m.step))
    if x == m.x then return false end
    m.x, m.f, m.n = x, 0, m.n + 1
    return true
end
function V62.money_hold(m, B, tg, note)
    m.ph, m.hx0, m.hy0 = "hold", V62.hand_px or m.x0, V62.hand_py or m.y
    haptic(1, 0.08, 0.6)
    local w = m.w
    local s1, coef = safe(function() return w.ValueSurplus end), safe(function() return w.CashValueCoef end)
    local cash = "?"
    if type(s1) == "number" and type(m.s_idle) == "number" and type(coef) == "number" and coef > 0 then
        cash = string.format("%.0f", (tonumber(m.c_idle) or 0) + (s1 - m.s_idle) / coef)
    end
    V62.money_say(string.format("the slider was run to the amount: about %s cash, balance %.3f (the trader's least %s, his ideal %s; going for %s)%s | %d spots tried, %d frames, %.1f s | trade button enabled: %s | click to take it, move your hand away to slide yourself",
        cash, B, tostring(safe(function() return string.format("%.3f", w.MinBalance) end)), tostring(safe(function() return string.format("%.3f", w.IdealBalance) end)),
        (S.trade_money_ideal == true) and "the ideal" or "the least", note or "", m.n, m.fr, T - m.t0,
        tostring(safe(function() return w.Button_Confirm:GetIsEnabled() end))))
end
function V62.money_cursor(pc)                                  -- from the menu pointer, every frame; nil = your hand has the cursor
    local m = V62.mny
    if m == nil or m.ph == "free" then return nil end
    if m.ph == "linger" then                                   -- just taken: the cursor stays put while your trigger comes back up
        if T > m.til then V62.mny = nil; return nil end
        return m.x, m.y
    end
    local w = m.w
    if not alive(w) then V62.mny = nil; return nil end         -- (the screen is gone)
    local B = safe(function() return w.TradeBalance end)
    local tg = safe(function() return (S.trade_money_ideal == true) and w.IdealBalance or w.MinBalance end)
    if type(B) ~= "number" or type(tg) ~= "number" or tg <= 0 or tg >= 1 then
        m.ph = "free"; V62.money_say("the trade screen's balance cannot be read - the slider stays with your hand")
        return nil
    end
    local ok = B >= tg + 0.0005
    m.f, m.fr = m.f + 1, m.fr + 1
    if B > (m.bb or 0) then m.bb = B end                       -- the best balance the slider has shown so far
    if m.ph == "hold" then
        local hx, hy = V62.hand_px, V62.hand_py
        if hx ~= nil and (math.abs(hx - m.hx0) > 0.15 * m.vw or math.abs(hy - m.hy0) > 0.2 * m.vh) then
            m.ph = "free"; V62.money_say("you moved your hand away - the slider is yours")
            return nil
        end
        return m.x, m.y
    end
    if m.fr > 700 then
        m.ph = "free"; V62.money_say("no answer after 700 frames - the slider is yours")
        return nil
    end
    if m.ph == "start" then
        if m.x == nil then                                     -- where you clicked
            local vw, vh = viewport_size(pc)
            if V62.hand_px == nil or type(vw) ~= "number" or vw < 100 or type(vh) ~= "number" or vh < 100 then m.ph = "free"; return nil end
            m.vw, m.vh = vw, vh
            m.x0 = math.max(1, math.min(vw - 2, math.floor(V62.hand_px + 0.5)))
            m.y = math.max(1, math.min(vh - 2, math.floor(V62.hand_py + 0.5)))
            m.x, m.step, m.f = m.x0, math.max(8, math.floor(vw * 0.025)), 0
        elseif m.f >= 5 then                                   -- the pop-up has settled on that spot
            m.b0, m.ph = B, "scan"
            if ok then m.dir, m.want, m.okx = -1, false, m.x0  -- enough already: left, to where it stops being enough
            else m.dir, m.want = 1, true end                   -- not enough: right, to where it is
            if not V62.money_step(m) then m.f = 3 end          -- (already at the edge: decided on the next frame)
        end
        return m.x, m.y
    end
    if m.ph == "scan" then
        if m.f < 3 then return m.x, m.y end
        if ok == m.want then
            if m.want and m.dir == -1 then                     -- second pass, a spot with enough: on to its left end
                m.want, m.f, m.okx = false, 0, math.min(m.vw - 2, m.x + m.step)
                return m.x, m.y
            end
            if m.want then m.lo, m.hi = math.max(m.x - 2 * m.step, m.pass2 and 1 or m.x0), m.x
            else m.lo, m.hi = m.x, math.min(m.x + 2 * m.step, m.okx or (m.vw - 2)) end
            m.lo = math.max(1, m.lo)
            m.ph, m.chk, m.x, m.f, m.n = "bisect", "lo", m.lo, 0, m.n + 1      -- the lower end first: is it really not enough there?
            return m.x, m.y
        end
        if not V62.money_step(m) then                          -- the edge of the screen
            if m.want and m.dir == 1 and not m.pass2 then      -- nothing to the right: look left of where you clicked
                m.pass2, m.dir, m.x, m.f = true, -1, m.x0, 0
                if not V62.money_step(m) then m.f = 3 end
            elseif m.want then                                 -- nowhere on the slider: all your money is not enough
                m.ph = "free"; haptic(1, 0.3, 0.8)
                V62.money_say(string.format("not enough money on the slider for this trade: the best balance it gave was %.3f, the trader wants %.3f - the slider is yours", m.bb or B, tg))
                return nil
            else                                               -- enough all the way to the left: the least the slider gives
                V62.money_hold(m, B, tg, " - enough even at the slider's left end")
            end
        end
        return m.x, m.y
    end
    if m.ph == "bisect" then
        if m.f < 5 then return m.x, m.y end
        if m.chk == "lo" then
            if ok then                                         -- enough there too: the search moves left
                if m.lo <= 1 then V62.money_hold(m, B, tg, " - enough even at the slider's left end"); return m.x, m.y end
                m.hi, m.lo = m.lo, math.max(1, m.lo - 2 * m.step)
                m.x, m.f, m.n = m.lo, 0, m.n + 1
                return m.x, m.y
            end
            m.chk = nil
        elseif ok then m.hi = m.x else m.lo = m.x end
        if m.hi - m.lo > 1 then m.x, m.f, m.n = math.floor((m.lo + m.hi) / 2), 0, m.n + 1
        else m.ph, m.x, m.f, m.tries, m.n = "verify", m.hi, 0, 0, m.n + 1 end
        return m.x, m.y
    end
    if m.ph == "verify" then                                   -- on the spot found: is it enough, seen a second time?
        if m.f < 6 then return m.x, m.y end
        if ok then V62.money_hold(m, B, tg)
        elseif m.tries < 2 * m.step and m.x < m.vw - 2 then m.tries, m.x, m.f, m.n = m.tries + 1, m.x + 1, 2, m.n + 1   -- a pixel to the right
        else
            m.ph = "free"; V62.money_say("could not settle on an amount - the slider is yours")
            return nil
        end
        return m.x, m.y
    end
    m.ph = "free"
    return nil
end
function V62.money_watch(b)                                    -- game tick, every frame while the trade screen is open
    local adding = safe(function() return b.w.IsAddingMoney end) == true
    if adding and not b.adding then                            -- Add Money was just clicked
        V62.mny = nil
        if S.trade_money == true then
            V62.mny = { ph = "start", f = 0, fr = 0, n = 0, w = b.w, t0 = T, s_idle = b.s_idle, c_idle = b.c_idle }
        end
        if not V62.pop_seen then                               -- once a session: the pop-up's own variables and functions
            V62.pop_seen = true
            local pop = safe(function() return b.w.AddMoneyPopup end)
            if pop ~= nil then
                local keep = V62.bprops
                pcall(V62.class_list, pop)
                V62.pprops, V62.bprops = V62.bprops, keep
            end
        end
    elseif not adding and b.adding then                        -- taken (your click) or cancelled
        local m = V62.mny
        if m ~= nil then
            V62.money_say(string.format("pop-up closed (%s): cash offered now %s, balance %s",
                m.ph == "hold" and "while the cursor was held on the amount" or ("search was at: " .. tostring(m.ph)),
                tostring(safe(function() return b.w.PlayerCashOffer end)), tostring(safe(function() return string.format("%.3f", b.w.TradeBalance) end))))
            if m.ph == "hold" then m.ph, m.til = "linger", T + 0.25 else V62.mny = nil end
        end
    end
    if not adding then                                         -- what the deal is worth without the pop-up (for the cash figure in the log)
        b.s_idle = safe(function() return b.w.ValueSurplus end)
        b.c_idle = safe(function() return b.w.PlayerCashOffer end)
    end
    b.adding = adding
end
function V62.barter_watch()                                    -- game tick; the listing about once a second while the screen is open
    local b = V62.bq
    if b == nil then return end
    if alive(b.w) then guarded("money", V62.money_watch, b) else V62.mny = nil end   -- v6.6.51: every frame
    if T < b.t then return end
    if not alive(b.w) or safe(function() return b.w:IsInViewport() end) ~= true then
        if b.last ~= nil then LOG("trade screen closed") end
        V62.bq = nil
        if V62.mny ~= nil and V62.mny.ph ~= "linger" then V62.mny = nil end
        return
    end
    b.t = T + 1.0
    if not V62.barter_seen then
        V62.barter_seen = true
        LOG("trade screen " .. tostring(b.cn) .. ", its make-up (item cards left out):")
        local n = { c = 0, sliders = {} }
        pcall(V62.barter_tree, b.w, 0, n)
        LOG(string.format("trade screen: %d parts listed, %d item cards left out, %d sliders", n.c, n.cards or 0, #n.sliders))
        pcall(V62.class_list, b.w)
    end
    if b.sl == nil or T >= (b.sl_t or 0) then                  -- sliders come and go with the screen's pages: looked for every 5 s
        local n = { c = 0, sliders = {}, quiet = true }
        pcall(V62.barter_tree, b.w, 0, n)
        b.sl, b.sl_t = n.sliders, T + 5.0
    end
    local snap = {}
    for _, p in ipairs(V62.bprops or {}) do
        local nm, ty = p[1], p[2]
        if ty == "IntProperty" or ty == "DoubleProperty" or ty == "FloatProperty" or ty == "BoolProperty" or ty == "ByteProperty" then
            local v = safe(function() return b.w[nm] end)
            if type(v) == "number" then snap[nm] = string.format("%.2f", v) elseif type(v) == "boolean" then snap[nm] = tostring(v) end
        end
    end
    for _, sl in ipairs(b.sl or {}) do
        if alive(sl[2]) then snap["slider " .. sl[1]] = string.format("%.2f", safe(function() return sl[2]:GetValue() end) or -1) end
    end
    if b.adding and V62.pprops ~= nil then                     -- v6.6.51: the money pop-up's own numbers while it is open
        local pop = safe(function() return b.w.AddMoneyPopup end)
        if pop ~= nil then
            for _, p in ipairs(V62.pprops) do
                local nm, ty = p[1], p[2]
                if ty == "IntProperty" or ty == "DoubleProperty" or ty == "FloatProperty" or ty == "BoolProperty" or ty == "ByteProperty" then
                    local v = safe(function() return pop[nm] end)
                    if type(v) == "number" then snap["pop-up " .. nm] = string.format("%.2f", v) elseif type(v) == "boolean" then snap["pop-up " .. nm] = tostring(v) end
                end
            end
            local pct = safe(function() return pop.ProgressBar_22.Percent end)
            if type(pct) == "number" then snap["pop-up bar"] = string.format("%.3f", pct) end
        end
    end
    local ch = {}
    for k, v in pairs(snap) do if b.last == nil or b.last[k] ~= v then ch[#ch + 1] = k .. "=" .. v end end
    table.sort(ch)
    if #ch > 0 and (V62.barter_lines or 0) < 120 then
        V62.barter_lines = (V62.barter_lines or 0) + 1
        LOG(("trade screen values" .. (b.last == nil and ": " or " changed: ") .. table.concat(ch, ", ")):sub(1, 1600))
    end
    b.last = snap
end
function V62.hint_poll()                                       -- game tick
    local q = V62.hq
    if q == nil or #q == 0 then return end
    for i = #q, 1, -1 do
        local e = q[i]
        if T >= e.t then
            table.remove(q, i)
            if alive(e.w) then
                local n = { c = 0, found = {}, quiet = true }
                pcall(dump_widget, e.w, 0, n)
                local parts, any = {}, false
                local function add(label, w)
                    local ts = V62.txt_read(w)
                    if ts == nil then return end
                    any = true
                    for _, t in ipairs(ts) do
                        if t.text ~= "" and not t.name:find("ToolTip", 1, true) and not t.name:find("Accessib", 1, true) and #parts < 40 then
                            parts[#parts + 1] = label .. "." .. t.name .. '="' .. t.text:sub(1, 400) .. '"'
                        end
                    end
                end
                add("screen", e.w)
                local names = {}
                for nm, wdg in pairs(n.found) do
                    if not same(wdg, e.w) and (safe(function() return shortclass(wdg) end) or ""):find("Text", 1, true) then names[#names + 1] = nm end
                end
                table.sort(names)
                for k = 1, math.min(#names, 30) do add(names[k], n.found[names[k]]) end
                if not any then
                    if not V62.hint_noplug then
                        V62.hint_noplug = true
                        LOG("hints: the texts could not be read (sf_txt.dll " .. (V62.txt_err and ("answered: " .. tostring(V62.txt_err)) or "gave no answer") .. ")")
                    end
                else
                    local line = table.concat(parts, " | ")
                    V62.hint_txt_seen = V62.hint_txt_seen or {}
                    local key = e.cn .. "|" .. line
                    if not V62.hint_txt_seen[key] then
                        V62.hint_txt_seen[key] = true
                        if line ~= "" or e.pass == 2 then
                            V62.hint_total = (V62.hint_total or 0) + 1
                            LOG("hint text [" .. e.cn .. "]: " .. (line ~= "" and line or "(no text in it)"))
                        end
                    end
                    if e.pass == 1 then q[#q + 1] = { w = e.w, cn = e.cn, t = T + 1.5, pass = 2 } end   -- texts are often set a moment after the screen appears
                end
            end
        end
    end
end
function V62.on_widget_added(f, obj, locals, result)
    local okc, cn = pcall(function() return obj:get_class():get_fname():to_string() end)
    if not okc or cn == nil then return end
    V62.wseen = V62.wseen or {}
    if not V62.wseen[cn] then
        V62.wseen[cn] = true
        V62.wsn = (V62.wsn or 0) + 1
        if V62.wsn <= 60 then LOG("screen added by the game: " .. cn) end
    end
    if cn == "SleepScreen_C" then V62.sleep_t = T end          -- v6.6.16: sleeping (the camera-away fade is for this)
    if cn == "HUD_Widget_C" then pcall(V62.hud_hide, obj) end   -- v6.6.43: not on the loading screen
    if cn == "BarterScreen_C" then V62.bq = { w = obj, cn = cn, t = T + 1.5 } end   -- v6.6.45 / v6.6.48: looked at from the tick (V62.barter_watch)
    -- v6.6.41: tutorial / button hints: their make-up, once per class (first 8)
    -- v6.6.43: the texts themselves cannot be read by Lua (FText) - every such screen is queued and read through sf_txt.dll
    -- a moment later (V62.hint_poll), each time one appears
    local lc = cn:lower()
    if V62.hint_like(lc) then
        if (V62.hint_n or 0) < 8 then
            V62.hint_seen = V62.hint_seen or {}
            if not V62.hint_seen[cn] then
                V62.hint_seen[cn] = true
                V62.hint_n = (V62.hint_n or 0) + 1
                LOG("hint screen " .. cn .. ":")
                pcall(dump_widget, obj, 0, { c = 0, found = {} })
            end
        end
        if S.hint_log ~= false and (V62.hint_total or 0) < 120 then
            V62.hq = V62.hq or {}
            if #V62.hq < 8 then V62.hq[#V62.hq + 1] = { w = obj, cn = cn, t = T + 0.3, pass = 1 } end
        end
    end
    if cn == "MainMenu_Widget_C" and V62.faded then V62.fade(false); LOG("fade: the main menu is up - view back") end   -- v6.6.18
    if cn == "Bino_Widget_C" and (S.binocular_mode or 1) ~= 2 and S.bino_hide_overlay ~= false then pcall(function() obj:SetRenderOpacity(0.0) end) end   -- v6.6.25/28
    if cn == "Bino_Widget_C" and not V62.bino_wd then                                  -- v6.6.20: research, once
        V62.bino_wd = true
        LOG("binoculars: the game's binocular screen:")
        pcall(dump_widget, obj, 0, { c = 0, found = {} })
    end
    if V62.BLACK[cn] then
        if S.hide_loading_box then pcall(function() obj:SetRenderOpacity(0.0) end) end
        local k = addr(obj)
        if k ~= nil then V62.blk[k] = obj end
        V62.fade(true, cn)
    end
end
function V62.hook_loading()
    if V62.hooked ~= nil or not S.transition_fade then return end
    V62.hooked = false
    local uw = G.UserWidget or api:find_uobject("Class /Script/UMG.UserWidget")
    local n, why = 0, {}
    for _, fname in ipairs({ "AddToViewport", "AddToPlayerScreen" }) do
        local fn = uw and safe(function() return uw:find_function(fname) end)       -- v6.6.15: by the class (the
        if fn == nil then fn = api:find_uobject("Function /Script/UMG.UserWidget:" .. fname) end   -- name has a ':')
        if fn == nil then fn = api:find_uobject("Function /Script/UMG.UserWidget." .. fname) end
        if fn == nil then why[#why + 1] = fname .. " not found"
        else
            local ok, e = pcall(function() fn:hook_ptr(V62.on_widget_added, nil) end)
            if ok then n = n + 1 else why[#why + 1] = fname .. ": " .. tostring(e) end
        end
    end
    V62.hooked = n > 0
    LOG("screen watch: " .. (n > 0 and ("watching " .. n .. " ways the game shows its screens") or "could not watch the game's screens")
        .. (#why > 0 and (" (" .. table.concat(why, "; ") .. ")") or ""))
end
-- v6.6.18: AUDIO FROM YOUR HEAD. The game's ears (its audio listener) sit on its camera, and with a gun the camera
-- points where the right-hand pointer points (that is how aiming works) - so sounds turned with your gun hand, not your
-- head. A small point on your body now follows the headset every frame (moved in the per-eye callback, view 0) and the
-- game's own "listen from here instead" switch (PlayerController.SetAudioListenerOverride) points at it.
V62.au = {}
function V62.audio_off(why)
    local A = V62.au
    if A.on and obj_ok(A.pc) then pcall(function() A.pc:ClearAudioListenerOverride() end) end
    if A.on and why ~= nil then LOG("audio: back to the game's own listener (" .. why .. ")") end
    A.on = false
end
function V62.audio_update(pc, pawn)
    local A = V62.au
    if S.audio_head == false then if A.on then V62.audio_off("switched off in the panel") end; return end
    if pc == nil or pawn == nil or A.fail then return end
    if A.on and obj_ok(A.comp) and same(A.pc, pc) and same(A.pawn, pawn) then
        if not A.checked and T - (A.t0 or T) > 6 then
            A.checked = true
            local l = safe(function() return A.comp:K2_GetComponentLocation() end)
            local r = safe(function() return A.comp:K2_GetComponentRotation() end)
            local c = safe(function() return pc:GetControlRotation() end)
            LOG(string.format("audio check: listener moved %d times in 6 s, at %.0f %.0f %.0f facing yaw %.0f pitch %.0f (game camera/aim yaw %.0f)",
                A.n or 0, l and l.X or 0, l and l.Y or 0, l and l.Z or 0, r and r.Yaw or 0, r and r.Pitch or 0, c and c.Yaw or 0))
        end
        return
    end
    if pc.SetAudioListenerOverride == nil then A.fail = true; LOG("audio: the game has no listener switch - sound left as it is"); return end
    local comp = A.comp
    if not (obj_ok(comp) and same(A.pawn, pawn)) then
        comp = api:add_component_by_class(pawn, G.SceneClass, false)
        if comp == nil then A.fail = true; LOG("audio: could not make the head point - sound left as it is"); return end
    end
    local hd = track.head
    if hd ~= nil then pcall(function() comp:K2_SetWorldLocationAndRotation(mkvec(hd[1], hd[2], hd[3]), mkrot(0, math.deg(math.atan(hd[5], hd[4])), 0), false, StructObject.new(G.Hit), true) end) end
    local ok, e = pcall(function() pc:SetAudioListenerOverride(comp, mkvec(0, 0, 0), mkrot(0, 0, 0)) end)
    if not ok then A.fail = true; LOG("audio: the game refused the head listener (" .. tostring(e) .. ") - sound left as it is"); return end
    A.comp, A.pc, A.pawn, A.on, A.t0, A.n, A.checked = comp, pc, pawn, true, T, 0, false
    A.ons = (A.ons or 0) + 1
    if A.ons <= 8 then LOG("audio: the game now hears from your head (sound directions follow the headset, not the gun hand)") end
end
function V62.audio_place(hx, hy, hz, p, y, r)               -- per-eye callback, view 0: head centre + head rotation
    local A = V62.au
    if not A.on or not obj_ok(A.comp) then return end
    A.v = A.v or StructObject.new(G.Vec)
    A.r = A.r or StructObject.new(G.Rot)
    A.hit = A.hit or StructObject.new(G.Hit)
    A.v.X, A.v.Y, A.v.Z = hx, hy, hz
    A.r.Pitch, A.r.Yaw, A.r.Roll = p, y, r
    A.comp:K2_SetWorldLocationAndRotation(A.v, A.r, false, A.hit, true)
    A.n = (A.n or 0) + 1
end
-- v6.6.15: VR RECOIL. Each shot (the gun's Ammo goes down, or its ShotCount up) kicks the gun in your hand - muzzle
-- up and a little back, from the gun's own Recoil_Lift / Recoil_MuzzleFlip / Recoil_Liniar, back over its recovery
-- time - and buzzes the controller(s). Visual only: the aim keeps using the gun's resting position.
function V62.rest_muzzle(gh)
    local rk = V62.rk
    if rk == nil or rk.rest == nil or gh == nil or not alive(gh) then return nil end
    local gT = gh:K2_GetComponentToWorld()
    local l = G.KML:TransformLocation(gT, mkvec(rk.rest[1], rk.rest[2], rk.rest[3]))
    local r = G.KML:TransformRotation(gT, mkrot(rk.rest[4], rk.rest[5], rk.rest[6]))
    return l, r
end
-- v6.6.18: how far into the kick the gun is (0 = rest, 1 = full): a quick ease-out punch (35 ms), then a smooth
-- glide back (starts and ends slowly - no flick, no snap at the end). A shot during the glide starts from where the gun is.
function V62.rk_amount(rk)
    if rk == nil or rk.t0 == nil then return 0 end
    local age, up, f0 = T - rk.t0, 0.035, rk.f0 or 0
    if age < up then return f0 + (1 - f0) * math.sin(age / up * math.pi * 0.5) end
    local u = (age - up) / (rk.dur or 0.25)
    if u >= 1 then return 0 end
    return 0.5 * (1 + math.cos(u * math.pi))
end
-- THE GUN STAYS IN YOUR HAND WHEN IT IS DRAWN (per-eye callback: after the game's update, before drawing).
-- pass 0, first eye (v6.6.19): the game's own recoil / sway / draw moves the gun during its update; enforce_gun puts it
--   back only after the frame, so each shot showed the kick. Put back here too. What was undone is logged per burst.
-- pass 1, second eye (v6.6.43): anything that moves it after the first pass wins the picture - UEVR's own saved "attach
--   to controller" did exactly that to the Rusty Old Pistol (UEVR applies attachments in its second-eye pass). Checked
--   again; a move found here is reported by V62.uevr_attach_watch and switches the per-frame removal on.
-- Plain reads; only when the gun is not where it belongs is anything set.
function V62.gun_hold(pass)
    if S.gun_hold_still == false or fit ~= nil or cur == nil or not obj_ok(cur.mesh) then return end
    if pass == 1 and S.gun_hold_both == false then return end
    if S.recoil_visual == true and V62.rk ~= nil and V62.rk.t0 ~= nil then return end     -- our own (optional) kick is shown
    -- v6.6.45: a "place in the hand" only exists for a part that hangs on our hand point (during a swap the game has
    -- the new weapon on its own holder for a moment - update_gun takes it in the next tick)
    if not same(attach_parent(cur.mesh), grip or hold) then return end
    if pass == 1 and V62.gh0 ~= V62.fno then return end         -- v6.6.45: the first pass did not look at it in THIS frame
    local g = gun_want()
    if g == nil then return end
    local dl, dr = gun_off(g)
    if pass == 0 then V62.gh0 = V62.fno end
    if dl == nil or (dl <= 0.05 and dr <= 0.05) then
        if pass == 1 then V62.ua.run = 0 end
        return
    end
    gun_put(g)
    if pass == 0 then
        local e = V62.gs
        if e == nil or T - e.t > 0.5 then e = { t0 = T, t = T, cm = 0, deg = 0, n = 0, cls = cur.cls }; V62.gs = e end
        e.t, e.n = T, e.n + 1
        if dl > e.cm then e.cm = dl end
        if dr > e.deg then e.deg = dr end
    else
        local A = V62.ua
        A.moved = (A.moved or 0) + 1
        if dl > (A.cm or 0) then A.cm = dl end
        if dr > (A.deg or 0) then A.deg = dr end
        A.cls = cur.cls
        -- v6.6.45: an attachment moves the part in EVERY frame - only 5 frames in a row count (a one-off is just put back)
        A.run = (A.last == V62.fno - 1) and (A.run or 0) + 1 or 1
        A.last = V62.fno
        if S.uevr_attach_guard ~= false and A.run >= 5 then A.on = true end   -- from now on taken off before every frame (first pass)
    end
end
-- v6.6.43: UEVR'S OWN ATTACHMENT vs THE MOD (game tick, twice a second while something is held). UEVR can attach any
-- part to a controller itself (UObjectHook) and save that in the profile (uobjecthook\*.json); a saved attachment is
-- re-created every tick. One for the part the mod holds fights the mod: the base profile had one for the Rusty Old
-- Pistol's Wep_Skeli. Found either by asking UEVR for the part's attachment state, or by V62.gun_hold seeing the part
-- moved between the eye passes. Once found (V62.ua.on) it is removed in the first eye pass of every frame.
function V62.uevr_attach_watch()
    local A = V62.ua
    if S.uevr_attach_guard == false then A.on = false; return end
    if cur == nil or T < (A.t or 0) or not obj_ok(cur.mesh) then return end
    A.t = T + 0.5
    -- (the Lua binding of this one function takes an unused first argument)
    local st = safe(function() return UEVR_UObjectHook.get_motion_controller_state(nil, cur.mesh) end)
    if st ~= nil then A.state_seen = (A.state_seen or 0) + 1; A.cls = A.cls or cur.cls; A.on = true end
    if A.on and not A.logged and ((A.moved or 0) > 0 or (A.state_seen or 0) > 0) then
        A.logged = true
        local moved = (A.moved or 0) > 0 and string.format("; it had moved the gun %.0f cm / %.0f deg away from your hand between the two eye passes (put back)", A.cm or 0, A.deg or 0) or ""
        if (A.state_seen or 0) > 0 then
            LOG(string.format("UEVR's own 'attach to controller' is set for the held part of %s (confirmed by UEVR; a saved attachment in the profile's uobjecthook folder) - the mod places guns itself, so it is now taken off before every frame%s",
                tostring(A.cls or cur.cls), moved))
        else
            LOG(string.format("the held part of %s is moved away between the two eye passes in every frame - UEVR's own 'attach to controller' does that (UEVR did not confirm one) - any attachment is now taken off before every frame%s",
                tostring(A.cls or cur.cls), moved))
        end
    end
    if (A.moved or 0) > (A.moved_rep or 0) and T - (A.rep_t or -1000) > 120 then
        A.rep_t = T
        LOG(string.format("gun: found moved between the two eye passes %d %stimes (worst %.0f cm) - put back each time%s", (A.moved or 0) - (A.moved_rep or 0),
            A.logged and "more " or "", A.cm or 0, A.on and "" or " (not in every frame: no attachment suspected)"))
        A.moved_rep = A.moved
    end
end
function V62.gun_still_log()                                  -- game tick: each burst logged once
    local e = V62.gs
    if e == nil or e.logged or T - e.t < 0.5 then return end
    e.logged = true
    local shot = V62.last_shot ~= nil and math.abs(V62.last_shot - e.t0) < 0.4
    if not shot then V62.gsx = (V62.gsx or 0) + 1; if V62.gsx > 4 then return end else V62.gsy = (V62.gsy or 0) + 1; if V62.gsy > 12 then return end end
    LOG(string.format("gun held still: the game moved %s up to %.1f cm / %.1f deg over %d frames (%s) - put back before drawing",
        e.cls, e.cm, e.deg, e.n, shot and "a shot - the game's own recoil" or "no shot"))
end
function V62.recoil_apply()
    if S.vr_recoil == false or cur == nil or not alive(cur.mesh) or not alive(cur.actor) or cur.cls:sub(1, 4) ~= "Wep_" or fit ~= nil then
        V62.rk = nil; return
    end
    local am = safe(function() return cur.actor.Ammo end)
    local sc = safe(function() return cur.actor.ShotCount end)
    local rk = V62.rk
    local ak = addr(cur.actor)
    if rk == nil or rk.actor ~= ak then V62.rk = { actor = ak, ammo = am, shots = sc }; return end
    local fired = (type(am) == "number" and type(rk.ammo) == "number" and am < rk.ammo)
        or (type(sc) == "number" and type(rk.shots) == "number" and sc > rk.shots)
    rk.ammo, rk.shots = am, sc
    local gh = grip or hold
    local mz = V62.muzzle()
    if gh == nil or not alive(gh) or mz == nil then return end
    if fired and V62.watch.low ~= true then
        local lift = math.abs(safe(function() return cur.actor.Recoil_Lift end) or 3) + 0.5 * math.abs(safe(function() return cur.actor.Recoil_MuzzleFlip end) or 0)
        local back = math.abs(safe(function() return cur.actor.Recoil_Liniar end) or 5)
        local rec = safe(function() return cur.actor.Anim_Recoil_RecoveryTime end) or 0.25
        local k = (twohand.on and 0.5 or 1.0) * (S.recoil_scale or 0.6)
        rk.f0 = V62.rk_amount(rk)                                  -- v6.6.18: from where the gun is now
        rk.t0 = T
        rk.lift = math.min(10, lift * k)
        rk.rise = rk.lift * math.max(0, math.min(1.5, S.recoil_rise or 0.2))   -- v6.6.18: muzzle tip (moves the sight off target)
        rk.up = math.min(1.5, rk.lift * 0.8)                       -- v6.6.18: the whole gun lifts instead (cm) - sight stays on target
        rk.back = math.min(6, back * 0.4 * k)
        rk.dur = math.max(0.2, math.min(0.45, (type(rec) == "number" and rec or 0.25) * 1.2))
        haptic(1, 0.035, 0.8)
        if twohand.on then haptic(0, 0.03, 0.5) end
        rk.n = (rk.n or 0) + 1
        V62.last_shot = T                                          -- v6.6.19 (for the "gun held still" log)
        if rk.n <= 3 then
            if S.recoil_visual == true then LOG(string.format("VR recoil: %s punches %.1f cm back and %.1f cm up, muzzle tips %.2f deg, glides back in %.2f s", cur.cls, rk.back, rk.up, rk.rise, rk.dur))
            else LOG("VR recoil: " .. cur.cls .. " fired - controller buzz only, the gun stays locked to your hand") end
        end
    end
    if S.recoil_visual ~= true then rk.t0, rk.f0 = nil, nil; return end   -- v6.6.19: no visual kick
    if rk.t0 == nil then return end
    if T - rk.t0 >= 0.035 + (rk.dur or 0.25) then rk.t0, rk.f0 = nil, nil; return end   -- settled (the glide ends at rest: no snap)
    local f = V62.rk_amount(rk)
    -- the resting pose (enforce_gun just put it back): remember where the muzzle sits in the hand, for the aim
    local gT = gh:K2_GetComponentToWorld()
    local ml0, mr0 = mz:K2_GetComponentLocation(), mz:K2_GetComponentRotation()
    local rl = G.KML:InverseTransformLocation(gT, ml0)
    local rr = G.KML:InverseTransformRotation(gT, mr0)
    if rl ~= nil and rr ~= nil then rk.rest = { rl.X or 0, rl.Y or 0, rl.Z or 0, rr.Pitch or 0, rr.Yaw or 0, rr.Roll or 0 } end
    local F, R, UpA = rot_axes(mr0.Pitch or 0, mr0.Yaw or 0, mr0.Roll or 0)
    local th = -math.rad((rk.rise or 0) * f)                   -- about the barrel's right axis: muzzle up
    local c, sn = math.cos(th), math.sin(th)
    local function rod(v)
        local kx, ky, kz = R[2] * v[3] - R[3] * v[2], R[3] * v[1] - R[1] * v[3], R[1] * v[2] - R[2] * v[1]
        local d = R[1] * v[1] + R[2] * v[2] + R[3] * v[3]
        return { v[1] * c + kx * sn + R[1] * d * (1 - c), v[2] * c + ky * sn + R[2] * d * (1 - c), v[3] * c + kz * sn + R[3] * d * (1 - c) }
    end
    local ml, mrot = cur.mesh:K2_GetComponentLocation(), cur.mesh:K2_GetComponentRotation()
    local g = gh:K2_GetComponentLocation()
    local X, _, Z = rot_axes(mrot.Pitch or 0, mrot.Yaw or 0, mrot.Roll or 0)
    local off = rod({ (ml.X or 0) - (g.X or 0), (ml.Y or 0) - (g.Y or 0), (ml.Z or 0) - (g.Z or 0) })
    local X2, Z2 = rod(X), rod(Z)
    local bk, upc = rk.back * f, (rk.up or 0) * f
    local nl = mkvec((g.X or 0) + off[1] - F[1] * bk + UpA[1] * upc, (g.Y or 0) + off[2] - F[2] * bk + UpA[2] * upc,
                     (g.Z or 0) + off[3] - F[3] * bk + UpA[3] * upc)
    local nr = G.KML:MakeRotFromXZ(mkvec(X2[1], X2[2], X2[3]), mkvec(Z2[1], Z2[2], Z2[3]))
    rk.hit = rk.hit or StructObject.new(G.Hit)
    if nr ~= nil then pcall(function() cur.mesh:K2_SetWorldLocationAndRotation(nl, nr, false, rk.hit, true) end) end
end
-- v6.6.12: lower / raise the weapon by setting the game's own state (the player's flag + the saved copy)
function V62.lower_toggle(pawn, why)
    local was = safe(function() return pawn.WepLowered end) == true
    local want = not was
    local ok = pcall(function() pawn.WepLowered = want end)
    pcall(function() local sv = pawn.Save; if sv ~= nil then sv.PlayerWeaponLowered = want end end)
    haptic(1, 0.04, want and 0.3 or 0.7)
    V62.low_chk = { t = T + 0.4, want = want }
    V62.lwn = (V62.lwn or 0) + 1
    if V62.lwn <= 12 then LOG("weapon " .. (want and "LOWERED" or "raised") .. " (" .. why .. ", set directly: " .. tostring(ok) .. ")") end
end
-- v6.2: game state watch - lowered weapon (shown in the hand), sprint, held slot - logged when it changes
function V62.watch_pawn(pawn, delta)
    local w = V62.watch
    local low = safe(function() return pawn.WepLowered end) == true
    local aside = safe(function() return pawn.Wep_HeldAside end) == true
    local spr = safe(function() return pawn.Sprinting end) == true
    local slot = safe(function() return pawn.Equiped_InvSlot end)
    if low ~= w.low then w.low = low; LOG("game: weapon lowered = " .. tostring(low)) end
    if aside ~= w.aside then
        w.aside = aside
        if (w.na or 0) < 10 then w.na = (w.na or 0) + 1; LOG("game: weapon held aside (near a wall) = " .. tostring(aside)) end
    end
    -- v6.6.45/46: in the flat game the gun swings aside when the game blocks it (too close to a wall: it will not fire, a
    -- scope shows nothing). The mod keeps it in your hand, so nothing showed it. Two short ticks in the gun hand - only
    -- when you PULL THE TRIGGER while it is blocked (v6.6.46; being blocked alone happens all the time while walking).
    local pull = false
    if aside and cur ~= nil and S.blocked_buzz ~= false and not menu_mode and lvl.ready and cur.cls:sub(1, 4) == "Wep_" then
        V62.trig_h = V62.trig_h or safe(function() return vr.get_action_handle("/actions/default/in/Trigger") end)
        pull = V62.trig_h ~= nil and safe(function()
            return vr.is_action_active(V62.trig_h, (S.left_handed == true) and vr.get_left_joystick_source() or vr.get_right_joystick_source()) end) == true   -- (v6.6.49: the gun hand)
    end
    if pull and not w.bp then
        V62.bz = { n = 3, t = T }                                 -- v6.6.47: three (was two), longer and at full strength
        if not V62.bz_logged then V62.bz_logged = true; LOG("trigger pulled while the game has the gun blocked (too close to something): three ticks in your gun hand") end
    end
    w.bp = pull
    if V62.bz ~= nil and T >= V62.bz.t then
        haptic(1, 0.045, 1.0)
        V62.bz.n, V62.bz.t = V62.bz.n - 1, T + 0.11
        if V62.bz.n <= 0 then V62.bz = nil end
    end
    if spr ~= w.spr then w.spr = spr; if (w.ns or 0) < 20 then w.ns = (w.ns or 0) + 1; LOG("game: sprinting = " .. tostring(spr)) end end
    if slot ~= w.slot then
        w.slot = slot
        if (w.nslot or 0) < 30 then w.nslot = (w.nslot or 0) + 1; LOG("game: held slot " .. tostring(slot) .. " = " .. tostring(V62.held(pawn))) end
    end
    -- v6.3: buzz count for the graphics preset
    if V62.pulses > 0 and T >= (V62.pulse_t or 0) then V62.pulses = V62.pulses - 1; V62.pulse_t = T + 0.22; haptic((S.left_handed == true) and 1 or 0, 0.06, 0.8) end   -- (always the LEFT controller)
    -- v6.3: the fire-mode notice in the HUD is tiny in VR - draw it 2.5x (once per HUD widget)
    if wrist ~= nil and wrist.hud ~= nil and T >= quiet_until and G.Vec2 ~= nil then
        local a = addr(wrist.hud)
        if a ~= nil and V62.hud_done ~= a then
            V62.hud_done = a
            local n = safe(function() return wrist.hud.SelectFire_Notif end)
            if n == nil and G.KSL ~= nil then   -- v6.4: not a widget variable - look it up by name
                n = safe(function() return wrist.hud:GetWidgetFromName(G.KSL:Conv_StringToName("SelectFire_Notif")) end)
            end
            if n == nil then n = V62.find_widget(wrist.hud, "SelectFire_Notif", { c = 0 }) end   -- v6.5: walk the tree
            if n == nil then LOG("fire-mode notice: widget not found in the HUD") end
            if n ~= nil then
                local sc = StructObject.new(G.Vec2); sc.X, sc.Y = 3.0, 3.0
                local pv = StructObject.new(G.Vec2); pv.X, pv.Y = 0.5, 0.5
                local ok = pcall(function() n:SetRenderTransformPivot(pv); n:SetRenderScale(sc) end)
                LOG("fire-mode notice drawn bigger: " .. tostring(ok))
            end
        end
    end
    local target = (S.show_lowered and low and cur ~= nil) and 1 or 0
    local step = math.min(1, (delta or 0.011) * 6)
    if V62.low < target then V62.low = math.min(target, V62.low + step) elseif V62.low > target then V62.low = math.max(target, V62.low - step) end
end
-- v6.1: the only body move left - LEFT hand on your chest (below the chin, in front of the body) + grip = flashlight
function fc.zone_of(hand)
    if hand ~= 0 or not S.chest_flashlight then return nil end
    vr.get_pose(vr.get_hmd_index(), fc.hp, fc.hq)
    vr.get_pose(vr.get_left_controller_index(), fc.cp, fc.cq)
    local fx, fy, fz = qv(fc.hq, 0, 0, -1)
    local l = math.sqrt(fx * fx + fz * fz)
    if l < 0.2 then return nil end                  -- looking straight up/down: no zone
    fx, fz = fx / l, fz / l
    local rx, rz = -fz, fx
    local dx, dy, dz = X(fc.cp) - X(fc.hp), Y(fc.cp) - Y(fc.hp), Z(fc.cp) - Z(fc.hp)
    local f, r, u = dx * fx + dz * fz, dx * rx + dz * rz, dy
    if u < -0.18 and u > -0.55 and f > -0.05 and f < 0.32 and math.abs(r) < 0.20 then return "chest" end
    return nil
end

local function update_frame_controls(pawn, delta)
    if not S.frame_controls then fc.taps = {}; return end
    if not fc.setup() then return end
    local function send_taps()
        for ia, n in pairs(fc.taps) do
            IAX.send(ia, 1)
            if n <= 1 then fc.taps[ia] = nil else fc.taps[ia] = n - 1 end
        end
    end
    -- View = journal, also while a menu is open (so it closes the journal too)
    -- v6.3: LEFT GRIP + View = next graphics preset, 1-4 buzzes
    if fc.edge("view", 0) then
        if fc.down("grip", 0) and not menu_mode then
            -- v6.6.47: every press = the next of the four presets, buzzes = its number. (The double press that started
            -- the performance probe is gone - it is how you skip a preset now. The probe: a button in the panel;
            -- while it runs, this press only stops it.)
            if V62.pp ~= nil then V62.probe_abort("stopped by hand")
            else
                S.gfx_level = (S.gfx_level or 2) % #V62.GFX + 1
                save_settings()
                V62.gfx_queue(S.gfx_level, "(left grip + View)")
                V62.pulses, V62.pulse_t = S.gfx_level, T
            end
        else
            fc.tap("IA_Journal", "View button")
        end
    end
    guarded("keyboard", V62.kbd_events)                       -- v6.6.13
    if not menu_mode and V62.kbd_in_menu then                    -- menu closed: keyboard away
        V62.kbd_in_menu = false
        if V62.kbd_shown then V62.kbd_shown = false; pcall(function() api:dispatch_custom_event("sfkbd", "hide") end) end
    end
    if menu_mode then
        local le = fc.edge("lclick", 0)
        guarded("keyboard", V62.kbd_update, delta, le)            -- v6.6.13: SteamVR keyboard for terminals / text boxes
        -- v6.5: SHIFT in menus (shift-click): left stick click or left grip held
        if S.menu_shift and not V62.kbd_want and (fc.down("lclick", 0) or fc.down("grip", 0)) then
            V62.key("hold", 0xA0)
            if not fc.logged.mshift then fc.logged.mshift = true; LOG("Frame control used: Shift held in a menu (shift-click)") end
        end
        V62.cyc, V62.cyc_q = nil, nil                        -- v6.6.2: what cycling learned stays
        send_taps(); return
    end
    -- v6.3: left stick click = SPRINT. IA_Sprint alone never started one, so after 0.4 s without the game's Sprinting
    -- flag (stick forward) its own W (IA_MoveForward) is held as well - most games only sprint while W is down
    -- v6.5: SPRINT = the game's real Left Shift (sf_keys plugin) while the left stick is clicked - the game's own
    -- hold / toggle setting then works as on a keyboard. W (the game's forward action) is held too while the stick is forward.
    local sp = V62.spr
    -- v6.6.8: a click of the left stick = sprint until you stop moving (stick back to the middle ~0.4 s) or click again
    local ldown = fc.down("lclick", 0)
    if ldown and not sp.was then
        if S.sprint_toggle ~= false then sp.latch = not sp.latch; sp.stop_t = 0 end
    end
    sp.was = ldown
    if sp.latch then
        -- v6.6.12: ends when you stop pushing FORWARD (not only when the stick is centred) for 0.2 s
        if (V62.ly or 0) < 0.35 then sp.stop_t = (sp.stop_t or 0) + delta else sp.stop_t = 0 end
        if sp.stop_t > (S.sprint_stop_delay or 0.2) then sp.latch = false end
    end
    if ldown or sp.latch then
        if not sp.on then
            sp.on, sp.t, sp.measured = true, 0, false; sp.n = (sp.n or 0) + 1
            if sp.n <= 8 then LOG("left stick click pressed (" .. sp.n .. ")") end
            if sp.n <= 4 then
                local okc, can = pcall(function() return pawn:Check_CanSprint() end)
                local function pv(n) return tostring(safe(function() return pawn[n] end)) end
                LOG(string.format("sprint check: Check_CanSprint -> %s %s | carry %s (penalty %s-%s, max %s) | crouched %s, in water %s",
                    tostring(okc), tostring(can), pv("Inventory_CarryWeight"), pv("MinPenaltyWeight"), pv("MaxPenaltyWeight"), pv("MaxHoldWeight"),
                    pv("bIsCrouched"), pv("InWater")))
            end
        end
        sp.t = sp.t + delta
        if S.sprint_key then V62.key("hold", 0xA0) end
        if S.sprint_inject then IAX.send("IA_Sprint", 1) end
        if S.sprint_w and (V62.ly or 0) > 0.4 then IAX.send("IA_MoveForward", 1); V62.wfwd = T end
        if sp.t > 1.0 and not sp.measured then                 -- v6.6.8: measured WHILE sprinting
            sp.measured = true
            sp.reps = (sp.reps or 0) + 1
            if sp.reps <= 20 then
                local v = safe(function() return pawn:GetVelocity() end)
                local function pv(n) return tostring(safe(function() return pawn[n] end)) end
                local spr = safe(function() return pawn.Sprinting end)
                LOG(string.format("sprint (1 s in): Sprinting=%s, speed %.0f cm/s (walk 650 / sprint 1100, game max now %s), stick fwd %.2f | hunger stack %s, sickness %s, speed mod %s, carry %s, crouched %s",
                    tostring(spr), v and math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2) or -1,
                    tostring(safe(function() return pawn.CharacterMovement.MaxWalkSpeed end)), V62.ly or 0,
                    pv("HungerStack"), pv("Sickness"), pv("MovementSpeedMod"), pv("Inventory_CarryWeight"), pv("bIsCrouched")))
            end
        end
    elseif sp.on then
        sp.on = false
        if S.sprint_key then V62.key("up", 0xA0) end
        sp.cancel_at = T + 0.15                                     -- v6.6.12: still sprinting then -> CancelSprint
    end
    if sp.cancel_at ~= nil and not sp.on and T > sp.cancel_at then
        sp.cancel_at = nil
        if S.sprint_cancel ~= false and safe(function() return pawn.Sprinting end) == true then
            local ok, e = pcall(function() pawn:CancelSprint() end)
            local now = safe(function() return pawn.Sprinting end)
            if (not ok or now == true) and S.sprint_key then V62.key("tap", 0xA0) end   -- (a toggle-style sprint: Shift again)
            V62.scn = (V62.scn or 0) + 1
            if V62.scn <= 10 then
                LOG("sprint: still sprinting after Shift was let go - game's CancelSprint " .. (ok and "called" or ("failed: " .. tostring(e)))
                    .. ", sprinting now " .. tostring(now) .. ((not ok or now == true) and " (Shift tapped once more)" or ""))
            end
        end
    end
    -- v6.5: CROUCH-JUMP - right grip held + Y: you jump (Y is Space as always), the script crouches a split second
    -- later and keeps you crouched until you land. If the game's crouch is a toggle, it is switched back afterwards.
    local yedge = fc.edge("ybtn", 1)
    if yedge and V62.jl == nil then guarded("jumplog", V62.jump_start, pawn) end   -- v6.6.12: jump height log
    if V62.jl ~= nil then guarded("jumplog", V62.jump_track, pawn) end
    local cj_grip                                               -- the GUN hand's grip (v6.6.49: left-handed = the left grip)
    if S.left_handed == true then cj_grip = fc.down("lgripl", 0) or fc.down("grip", 0) else cj_grip = fc.down("rgripl", 1) or fc.down("rbump", 1) end
    if S.crouch_jump and yedge and cj_grip then
        V62.cj = { t0 = T, was = safe(function() return pawn.bIsCrouched end) == true }
        if not fc.logged.cjm then fc.logged.cjm = true; LOG("Frame control used: gun-hand grip + Y -> crouch-jump") end
    end
    local cj = V62.cj
    if cj ~= nil then
        local age = T - cj.t0
        local falling = safe(function() return pawn.CharacterMovement:IsFalling() end)
        if age > 1.4 or (age > 0.35 and falling == false) then
            V62.cj = nil
            V62.cj_check = { t = T + 0.3, was = cj.was }
        elseif age >= (S.cj_delay or 0.12) then
            IAX.send("IA_Crouch", 1)
        end
    end
    local cc = V62.cj_check
    if cc ~= nil and T > cc.t then
        V62.cj_check = nil
        if not cc.was and safe(function() return pawn.bIsCrouched end) == true then
            fc.tap("IA_Crouch")
            if not fc.logged.cjt then fc.logged.cjt = true; LOG("crouch-jump: the game's crouch is a toggle - stood back up after landing") end
        end
    end
    -- v6.4: right grip (full squeeze) = crouch while held (crouch-jump = squeeze + Y). "rbump" = the right grip action.
    if S.right_grip_crouch and fc.down("rbump", 1) then
        IAX.send("IA_Crouch", 1)
        if not fc.logged.rgc then fc.logged.rgc = true; LOG("Frame control used: right grip -> crouch") end
    end
    -- v6.3: hold Y = crouch-jump (Y is still Space through joytokey; held, it adds crouch - not in water / on ladders)
    if S.hold_jump_crouch then
        if fc.down("ybtn", 1) then
            V62.yt = (V62.yt or 0) + delta
            if V62.yt > 0.2 and safe(function() return pawn.InWater end) ~= true and safe(function() return pawn.OnLadder end) ~= true then
                IAX.send("IA_Crouch", 1)
                if not fc.logged.cj then fc.logged.cj = true; LOG("Frame control used: hold Y -> crouch-jump") end
            end
        else V62.yt = 0 end
    end
    -- v6.3: left trigger with the off-hand flashlight: TORCH hold <-> RAISED hold
    local lt = fc.edge("trig", (S.left_handed == true) and 1 or 0)   -- the OTHER hand's trigger (v6.6.49)
    if lt and S.flashlight_modes and offh.actor ~= nil then
        V62.fl_alt = not V62.fl_alt
        haptic(0, 0.03, 0.5)
        LOG("off-hand flashlight: " .. (V62.fl_alt and ("RAISED hold (beam " .. tostring(S.fl_alt_angle) .. " deg from where the hand points - for a hand held up)")
            or "TORCH hold (beam where your hand points)"))
    end
    -- v6.2: right grip, full click = quick melee - only once we've seen that a light squeeze and a full squeeze are
    -- different (the binding's thresholds work); otherwise every light grip of the controller would melee
    if not V62.stages_ok and ((fc.down("lgripl", 0) and not fc.down("grip", 0)) or (fc.down("rgripl", 1) and not fc.down("rbump", 1))) then
        V62.stages_ok = true; LOG("grips: light and full squeeze are separate (SteamVR thresholds active) - quick melee on")
    end
    if fc.edge("rbump", 1) and S.quick_melee then             -- v6.3: "rbump" action = the right GRIP now (binding swap)
        if V62.stages_ok then fc.tap("IA_QuickMelee", "right grip (quick melee)")
        elseif not V62.qm_logged then V62.qm_logged = true; LOG("quick melee waits: a light and a full grip squeeze look the same so far (binding thresholds not active?)") end
    end
    -- held keys (sent every frame while held, exactly like holding the key)
    -- v6.3: the right BUMPER is the Grip action now -> pad RB -> joytokey -> the real G key (hold = the game's own hold)
    if S.lower_direct then                                      -- v6.6.12: tap = G on release, hold = lower / raise
        if V62.gun_bumper() then
            V62.rbt = (V62.rbt or 0) + delta
            if V62.rbt >= (S.lower_hold or 0.45) and not V62.rb_done then
                V62.rb_done = true
                V62.lower_toggle(pawn, "right bumper held")
            end
            if not fc.logged.pick then fc.logged.pick = true; LOG("Frame control used: gun-hand bumper (tap = pick up, hold = lower / raise the weapon)") end
        else
            if (V62.rbt or 0) > 0 and not V62.rb_done then V62.key("tap", 0x47) end
            V62.rbt, V62.rb_done = 0, false
        end
    elseif V62.gun_bumper() then
        V62.key("hold", 0x47)                                   -- v6.6.8: the real G key (hold = the game's lower weapon)
        V62.g_on = true
        if not fc.logged.pick then fc.logged.pick = true; LOG("Frame control used: right bumper -> G key (pick up, hold = the game's lower weapon)") end
    end
    if not S.lower_direct and not V62.gun_bumper() then
        V62.rbt, V62.rb_done = 0, false
        if V62.g_on then V62.g_on = false; V62.key("up", 0x47) end
    end
    if V62.low_chk ~= nil and T > V62.low_chk.t then
        local now = safe(function() return pawn.WepLowered end) == true
        if now ~= V62.low_chk.want then
            V62.lwb = (V62.lwb or 0) + 1
            if V62.lwb <= 6 then LOG("weapon lowered/raised: the game set it back to " .. tostring(now) .. " within 0.4 s") end
        end
        V62.low_chk = nil
    end
    if V62.off_bumper() then
        IAX.send("IA_ModeToggle", 1)
        if not fc.logged.mode then fc.logged.mode = true; LOG("Frame control used: other-hand bumper -> mode toggle (C)") end
    end
    -- D-pad left / right = previous / next weapon - unless the left grip is held (then joytokey sends utility slots 7 / 8)
    local lgrip = fc.down("grip", 0)
    local dl, dr = fc.edge("dleft", 0), fc.edge("dright", 0)
    if not lgrip then
        if S.weapons_only_dpad then                         -- v6.2: weapons only
            if dl then V62.cycle_start(pawn, -1) end
            if dr then V62.cycle_start(pawn, 1) end
        else
            if dl then fc.tap("IA_Equip_Previous", "D-pad left") end
            if dr then fc.tap("IA_Equip_Next", "D-pad right") end
        end
    end
    V62.cycle_update(pawn)
    -- chest flashlight (left hand only, not while it holds a long gun's fore-grip)
    local z = fc.zone_of(0)
    if z ~= fc.zone[0] then
        fc.zone[0] = z
        if z ~= nil and S.zone_haptics then haptic(0, 0.02, 0.25) end
    end
    if lgrip and not fc.gripped[0] and z == "chest" and not twohand.on then
        fc.tap("IA_FlashLight", "chest grip (flashlight)")
        haptic(0, 0.05, 0.7)
    end
    fc.gripped[0] = lgrip
    send_taps()
end

---------------------------------------------------------------------------
local pad = { lx = 0, ly = 0, rx = 0, ry = 0 }
local function on_pad(retval, user_index, state)
    local g = state.Gamepad
    -- v4.12: the sticks are read straight from UEVR every frame (below); these reads are only a fallback
    pad.xlx, pad.xly, pad.xrx, pad.xry = g.sThumbLX, g.sThumbLY, g.sThumbRX, g.sThumbRY
    local l3 = ((g.wButtons or 0) & 0x0040) ~= 0                  -- v6.4: L3 bit as UEVR hands it to the game
    if l3 ~= pad.l3 then pad.l3 = l3; pad.l3n = (pad.l3n or 0) + 1; if pad.l3n <= 8 then LOG("pad: left stick click " .. (l3 and "down" or "up") .. " (as the game sees it)") end end
    pad.age = 0
    if not pad.seen then pad.seen = true; LOG("the game is reading the controller") end
    track.pad_seen = true
    if pad.lost then pad.lost = false; LOG("controller input reaching the game again") end
end
V62.reg("on_xinput_get_state", function(retval, user_index, state) guarded("pad", on_pad, retval, user_index, state) end)

-- v4.6: when the game isn't reading the controller (see log), read the sticks straight from UEVR instead
-- (v6: axis_l/axis_r/axis_ok now pad.axl/pad.axr/pad.axok)
local function read_sticks_from_uevr()
    if pad.axok == false then return false end
    if pad.axok == nil then
        local ok, err = pcall(function()
            pad.axl = UEVR_Vector2f.new()
            pad.axr = UEVR_Vector2f.new()
            vr.get_joystick_axis(vr.get_left_joystick_source(), pad.axl)
            vr.get_joystick_axis(vr.get_right_joystick_source(), pad.axr)
        end)
        pad.axok = ok
        LOG(ok and "sticks: reading them straight from UEVR (walking/turning no longer need the game's controller reads)"
            or ("sticks: could not read them from UEVR: " .. tostring(err)))
        if not ok then return false end
    end
    vr.get_joystick_axis(vr.get_left_joystick_source(), pad.axl)
    vr.get_joystick_axis(vr.get_right_joystick_source(), pad.axr)
    pad.lx, pad.ly = (pad.axl.x or 0) * 32767, (pad.axl.y or 0) * 32767
    pad.rx, pad.ry = (pad.axr.x or 0) * 32767, (pad.axr.y or 0) * 32767
    return true
end

---------------------------------------------------------------------------
-- 6: VR body - bullets follow the gun barrel while a trigger is held, otherwise the game aims where your right hand
--    points (4c). The picture is rendered from the body direction + your head (view override in the per-eye hook).
--    Body yaw is ours: right stick turns it. Left stick walks relative to your head (on ladders: the game's Move).
---------------------------------------------------------------------------
local body = nil       -- { pawn, yaw, orig = {...} }
track.snap_armed = true
local H4 = {}; H4.p, H4.q, H4.r = Vector3f.new(0, 0, 0), Quaternionf.new(0, 0, 0, 1), Quaternionf.new(0, 0, 0, 1)

local function qmul(a, b)
    return { w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
             x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w }
end

local function head_angles()
    -- head yaw/pitch relative to the recentred forward (degrees, UE convention: yaw + = right, pitch + = up)
    vr.get_pose(vr.get_hmd_index(), H4.p, H4.q)
    vr.get_rotation_offset(H4.r)
    local q = qmul({ x = X(H4.r), y = Y(H4.r), z = Z(H4.r), w = W(H4.r) }, { x = X(H4.q), y = Y(H4.q), z = Z(H4.q), w = W(H4.q) })
    local f = qrot(q, v3(0, 0, -1))
    return math.deg(math.atan(f.x, -f.z)), math.deg(math.asin(math.max(-1, math.min(1, f.y))))
end

-- v5.5: put the VR menu panel world-locked straight in front of your head without moving the world.
local MP = {}; MP.p, MP.q, MP.r = Vector3f.new(0, 0, 0), Quaternionf.new(0, 0, 0, 1), Quaternionf.new(0, 0, 0, 1)
place_menu_front = function()
    local h = 0
    pcall(function()
        vr.get_pose(vr.get_hmd_index(), MP.p, MP.q)
        vr.get_rotation_offset(MP.r)
        local q = qmul({ x = X(MP.r), y = Y(MP.r), z = Z(MP.r), w = W(MP.r) }, { x = X(MP.q), y = Y(MP.q), z = Z(MP.q), w = W(MP.q) })
        local f = qrot(q, v3(0, 0, -1))
        h = math.deg(math.atan(f.x, -f.z))          -- head yaw from UEVR's current forward (same maths as walking)
    end)
    if menu_shift.ro == nil then
        local r0 = Quaternionf.new(0, 0, 0, 1); pcall(vr.get_rotation_offset, r0); menu_shift.ro = r0
    end
    pcall(vr.recenter_view)                         -- UEVR's forward := where you look (yaw only)
    if view.ok and math.abs(h) > 0.01 then         -- turn our body view back by the same angle: world does not move
        view.yaw = view.yaw + h
        menu_shift.yaw = menu_shift.yaw + h
    end
    -- panel centre = origin - back*dist + right*x + up*y (UEVR OverlayComponent); solve for "in front of the head"
    local ro, so = Quaternionf.new(0, 0, 0, 1), Vector3f.new(0, 0, 0)
    pcall(vr.get_rotation_offset, ro); pcall(vr.get_standing_origin, so)
    pcall(vr.get_pose, vr.get_hmd_index(), MP.p, MP.q)
    local fq = qconj({ x = X(ro), y = Y(ro), z = Z(ro), w = W(ro) })
    local ax, ay, az = qrot(fq, v3(1, 0, 0)), qrot(fq, v3(0, 1, 0)), qrot(fq, v3(0, 0, 1))
    local d = v3(X(MP.p) - X(so), Y(MP.p) - Y(so), Z(MP.p) - Z(so))
    local xo, yo, dist = dot(d, ax), dot(d, ay) + S.menu_height, S.menu_distance - dot(d, az)
    setmod("UI_X_Offset", string.format("%.3f", xo))
    setmod("UI_Y_Offset", string.format("%.3f", yo))
    setmod("UI_Distance", string.format("%.3f", dist))
    LOG(string.format("menu placed in front of you (world-locked): turned %.0f deg, offset %.2f %.2f, distance %.2f m", h, xo, yo, dist))
end

local function setup_body(pawn)
    local spring = safe(function() return pawn.SpringArm_Cam end)
    local cam = safe(function() return pawn.Camera end)
    local cm = safe(function() return pawn.CharacterMovement end)
    local o = {
        yaw_ctrl = safe(function() return pawn.bUseControllerRotationYaw end),
        spring = spring and safe(function() return spring.bUsePawnControlRotation end),
        cam = cam and safe(function() return cam.bUsePawnControlRotation end),
        orient = cm and safe(function() return cm.bOrientRotationToMovement end),
        desired = cm and safe(function() return cm.bUseControllerDesiredRotation end),
    }
    pawn.bUseControllerRotationYaw = false
    -- v4.9: the camera keeps following the aim direction (your head, or the barrel while you shoot) - the game looks
    -- along it for interaction. 4.4-4.8 froze it to the body, so Y / RB picked whatever was straight ahead of your body.
    if spring ~= nil then pcall(function() spring.bUsePawnControlRotation = true end) end
    if cm ~= nil then
        pcall(function() cm.bOrientRotationToMovement = false end)
        pcall(function() cm.bUseControllerDesiredRotation = false end)
    end
    local r = pawn:K2_GetActorRotation()
    body = { pawn = pawn, yaw = r.Yaw or 0, orig = o, spring = spring, cam = cam, cm = cm, moved_logged = false, arm_t = 0 }
    view.yaw, view.arm, view.ok = body.yaw, nil, false
    LOG(string.format("VR body on (was: pawn yaw-from-control=%s, springarm=%s, camera=%s, orient-to-move=%s)",
        tostring(o.yaw_ctrl), tostring(o.spring), tostring(o.cam), tostring(o.orient)))
end

local function release_body()
    view.ok = false
    if body == nil then return end
    local b = body
    body = nil
    if alive(b.pawn) then
        pcall(function() b.pawn.bUseControllerRotationYaw = (b.orig.yaw_ctrl ~= false) end)
        if b.spring ~= nil and b.orig.spring ~= nil then pcall(function() b.spring.bUsePawnControlRotation = b.orig.spring end) end
        if b.cam ~= nil and b.orig.cam ~= nil then pcall(function() b.cam.bUsePawnControlRotation = b.orig.cam end) end
        if b.cm ~= nil and b.orig.orient ~= nil then pcall(function() b.cm.bOrientRotationToMovement = b.orig.orient end) end
        if b.cm ~= nil and b.orig.desired ~= nil then pcall(function() b.cm.bUseControllerDesiredRotation = b.orig.desired end) end
    end
    LOG("VR body off")
end

local function update_body(pawn, delta)
    if not S.vr_body then
        if body ~= nil then release_body(); setmod("VR_AimMethod", (ORIG and ORIG.aim ~= "" and ORIG.aim ~= "0") and ORIG.aim or "2") end
        return
    end
    if V62.aim_kick == nil and getmod("VR_AimMethod") ~= "0" then setmod("VR_AimMethod", "0") end
    if body == nil or not same(body.pawn, pawn) then setup_body(pawn) end
    -- v4.9: is the picture coming from our body's camera? (cut-scenes / other cameras are left alone)
    local pc0 = api:get_player_controller(0)
    TRACE("GetViewTarget")
    local vt = pc0 and safe(function() return pc0:GetViewTarget() end)
    view.ok = vt ~= nil and same(vt, pawn)
    if not view.ok then V62.view_away_t = V62.view_away_t or T else V62.view_away_t = nil end   -- v6.6.15
    if view.ok ~= body.view_logged then
        body.view_logged = view.ok
        LOG("view from body direction (camera follows your head for the game): " .. tostring(view.ok)
            .. ((not view.ok and vt ~= nil) and (" - the game's camera is on " .. shortclass(vt)) or ""))
    end
    -- camera offset from its pivot, in camera space (0 for a plain first-person camera) - keeps the eyes still when the
    -- camera tilts with your head
    -- v6.6.51: measured ONLY WHILE YOU STAND STILL, taken over only when two measurements 0.3 s apart agree, and a
    -- change is eased in. Up to v6.6.50 it was measured every 2 s no matter what: while you walk the game's camera sits
    -- a little off its pivot, that momentary offset went into the view, and the first measurement after you stopped
    -- took it out again in one frame - the small "reset" a moment after every stop (in the recording of the fifth
    -- playtest every one of those jumps sits on the same 2.007 s clock: this timer).
    body.arm_t = (body.arm_t or 0) - delta
    if body.arm_t <= 0 and alive(body.cam) and alive(body.spring) then
        body.arm_t = 2.0
        TRACE("camera pivot measure")
        local cl = safe(function() return body.cam:K2_GetComponentLocation() end)
        local cr = safe(function() return body.cam:K2_GetComponentRotation() end)
        local sl = safe(function() return body.spring:K2_GetComponentLocation() end)
        if cl ~= nil and cr ~= nil and sl ~= nil then
            local F, Rt, U = rot_axes(cr.Pitch or 0, cr.Yaw or 0, cr.Roll or 0)
            local dx, dy, dz = (cl.X or 0) - (sl.X or 0), (cl.Y or 0) - (sl.Y or 0), (cl.Z or 0) - (sl.Z or 0)
            local a = { dx * F[1] + dy * F[2] + dz * F[3], dx * Rt[1] + dy * Rt[2] + dz * Rt[3], dx * U[1] + dy * U[2] + dz * U[3] }
            local len = math.sqrt(a[1] ^ 2 + a[2] ^ 2 + a[3] ^ 2)
            local vel = safe(function() return pawn:GetVelocity() end)
            local spd = vel and math.sqrt((vel.X or 0) ^ 2 + (vel.Y or 0) ^ 2 + (vel.Z or 0) ^ 2) or 999
            if spd > 3 then                                    -- moving: looked at, never used
                body.arm_prev = nil
                if len > 0.5 and len < 200 and len > (V62.pv_max or 0) + 1.0 and (V62.pv_n or 0) < 6 then
                    V62.pv_max, V62.pv_n = len, (V62.pv_n or 0) + 1
                    LOG(string.format("camera pivot: while you move the game's camera sits %.1f cm off its pivot (%.1f %.1f %.1f) - left out of the view (until build 6.6.50 this was the small jump after stopping)",
                        len, a[1], a[2], a[3]))
                end
            else
                local p = body.arm_prev
                body.arm_prev = a
                if p ~= nil and math.abs(a[1] - p[1]) + math.abs(a[2] - p[2]) + math.abs(a[3] - p[3]) < 0.3 then
                    local goal, g0 = (len > 0.5 and len < 200) and a or nil, body.arm_goal
                    local same_goal = (goal == nil and g0 == nil) or (goal ~= nil and g0 ~= nil
                        and math.abs(goal[1] - g0[1]) + math.abs(goal[2] - g0[2]) + math.abs(goal[3] - g0[3]) < 0.3)
                    if not same_goal then
                        body.arm_goal = goal
                        V62.pv_c = (V62.pv_c or 0) + 1
                        if V62.pv_c <= 20 then
                            LOG(string.format("camera pivot offset, standing still: %.1f %.1f %.1f cm (%s) - change %d this session, eased in",
                                a[1], a[2], a[3], goal and "compensated" or "none needed", V62.pv_c))
                        end
                    end
                else
                    body.arm_t = 0.3                           -- looked at again in a moment: two that agree are needed
                end
            end
            if not body.arm_logged then
                body.arm_logged = true
                LOG(string.format("camera pivot offset %.1f %.1f %.1f cm at the first look (%s)", a[1], a[2], a[3], spd > 3 and "moving - not used" or "standing"))
            end
        end
    end
    do                                                         -- v6.6.51: the offset in use moves toward the measured one, never in one step
        local g, c = body.arm_goal, view.arm
        if g ~= nil or c ~= nil then
            local k = math.min(1, delta * 3)
            c = c or { 0, 0, 0 }
            c[1] = c[1] + ((g and g[1] or 0) - c[1]) * k
            c[2] = c[2] + ((g and g[2] or 0) - c[2]) * k
            c[3] = c[3] + ((g and g[3] or 0) - c[3]) * k
            if g == nil and math.abs(c[1]) + math.abs(c[2]) + math.abs(c[3]) < 0.02 then c = nil end
            view.arm = c
        end
    end
    if menu_mode then return end

    -- turning (right stick)
    local rx = (pad.rx or 0) / 32767
    if S.snap_turn then
        if math.abs(rx) > 0.6 and track.snap_armed then body.yaw = body.yaw + (rx > 0 and S.snap_angle or -S.snap_angle); track.snap_armed = false end
        if math.abs(rx) < 0.3 then track.snap_armed = true end
    elseif math.abs(rx) > 0.2 then
        local r = (math.abs(rx) - 0.2) / 0.8
        body.yaw = body.yaw + (rx > 0 and 1 or -1) * r * r * S.turn_speed * delta
    end
    body.yaw = (body.yaw + 180) % 360 - 180
    TRACE("K2_SetActorRotation")
    -- v6.1: while carrying, the body faces your hand (set once, below) - turning it to the view here as well made the
    -- carried object jump between two places every frame (the violent shaking)
    if not body.carrying then pawn:K2_SetActorRotation(mkrot(0, body.yaw, 0), false) end
    view.yaw = body.yaw

    -- walking relative to where you look (left stick, analog)
    body.wreq = nil
    V62.ly = (pad.ly or 0) / 32767
    local hy, hpch = head_angles()
    local lx, ly = (pad.lx or 0) / 32767, (pad.ly or 0) / 32767
    local mag = math.sqrt(lx * lx + ly * ly)
    local on_ladder = safe(function() return pawn.OnLadder end) == true
    if on_ladder ~= body.ladder then body.ladder = on_ladder; LOG("on a ladder / chain: " .. tostring(on_ladder)) end
    if on_ladder then
        if mag > S.move_deadzone then inject_move(lx, ly) end
    elseif mag > S.move_deadzone and S.game_walk and body.walk ~= "direct" and not track.walk_direct then
        -- v6.1: through the game's own Move action, so the game's sprint / footsteps / hunger see the walking.
        -- The game turns Move (x = right, y = forward) into a world direction with its own basis; that basis is measured
        -- after every tick (walk_measure) and corrected here, so walking stays where you LOOK.
        -- v6.2: sent at the end of this function (V62.walk_send), once this frame's control rotation is set
        local m = math.min(1, (mag - S.move_deadzone) / (1 - S.move_deadzone))
        body.wreq = { want = body.yaw + hy + math.deg(math.atan(lx, ly)), m = m }
    elseif mag > S.move_deadzone then
        local scale = math.min(1, (mag - S.move_deadzone) / (1 - S.move_deadzone)) / mag
        local wy = math.rad(body.yaw + hy)
        local fx, fy = math.cos(wy), math.sin(wy)
        local rxv, ryv = -fy, fx
        TRACE("AddMovementInput")
        pawn:AddMovementInput(mkvec(fx * ly * scale + rxv * lx * scale, fy * ly * scale + ryv * lx * scale, 0), 1.0, false)
        body.push = (body.push or 0) + delta
        if body.push > 1.5 and not body.moved_logged then
            body.moved_logged = true
            local v = safe(function() return pawn:GetVelocity() end)
            local sp = v and math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2) or -1
            LOG(string.format("analog walking check: stick %.2f %.2f, speed %.0f cm/s %s", lx, ly, sp, sp > 20 and "(works)" or "(NOT MOVING - please report this)"))
        end
    else
        body.push = 0
    end

    -- aim: the game's control rotation follows the gun barrel (or your head when no gun is out)
    local pc = api:get_player_controller(0)
    if pc == nil then return end
    -- v4.8: the game uses this same direction for "what am I looking at" (Y interact, RB pick up). So it only follows
    -- the gun while a trigger is held (fire / aim down sights) and for a moment after; otherwise it follows your head.
    body.trig_h = body.trig_h or safe(function() return vr.get_action_handle("/actions/default/in/Trigger") end)
    local firing = false
    if body.trig_h ~= nil then
        firing = safe(function() return vr.is_action_active(body.trig_h, vr.get_right_joystick_source())
            or vr.is_action_active(body.trig_h, vr.get_left_joystick_source()) end) == true
    end
    if firing then body.fire_t = 0.5 else body.fire_t = math.max(0, (body.fire_t or 0) - delta) end
    local aim, src = nil, "hand pointer"
    local muzzle_aim = cur ~= nil and alive(cur.mesh) and body.fire_t > 0 and cur.cls:find("Binocular") == nil   -- v6.6.15
    -- v6.6.14: firing keeps the game's eye ray on the barrel's aiming point (no jump to the barrel's own direction when
    -- the trigger is pulled: that jump shifted the gun on every shot, and the game's ray starts at your eyes - left/up)
    if muzzle_aim and S.fire_aim_pointer ~= false and T >= quiet_until and hudp.P ~= nil and not V62.binoc_on then
        muzzle_aim = false
        if not V62.fap_logged then V62.fap_logged = true; LOG("aim while firing: the game's eye ray goes through the barrel's aiming point (v6.6.14)") end
    end
    if muzzle_aim then
        -- a barrel arrow only counts if it rides on the gun mesh we move (otherwise it points wherever the game left it)
        for _, n in ipairs({ "Arrow_Muzzle", "Arrow_Aim", "Arrow_SightZero" }) do
            local a = safe(function() return cur.actor[n] end)
            if a ~= nil and same(attach_parent(a), cur.mesh) then
                aim = safe(function() return a:K2_GetComponentRotation() end); src = n
                if aim ~= nil then break end
            end
        end
        local gh = grip or hold
        if aim == nil and alive(gh) then aim = safe(function() return gh:K2_GetComponentRotation() end); src = "hand" end
    end
    TRACE("SetControlRotation")
    if aim ~= nil then
        body.carrying = false
        report_ctrl_jump(aim.Yaw or 0, src)
        pc:SetControlRotation(mkrot(aim.Pitch or 0, aim.Yaw or 0, 0))
        body.cy, body.cp = aim.Yaw or 0, aim.Pitch or 0
    else
        -- v4.10: Y / RB act on what your RIGHT HAND points at (head as fallback)
        local pp, py = nil, nil
        local headaim = V62.binoc_on and V62.binoc.mode == "flat"                          -- v6.6.17: only the flat view
        -- v6.6.40: the sprint holds the game's own forward key, which moves along the game's look - so while it is held
        -- the look follows your head, not the hand pointer (else a sprint drifts toward the gun)
        local sprint_w = S.sprint_head ~= false and T - (V62.wfwd or -10) < 0.05
        if sprint_w and not V62.sprint_head_logged then V62.sprint_head_logged = true; LOG("sprint: the game's forward key moves along its look direction, which followed your gun hand - while sprinting the look follows your head now") end
        -- v6.6.45: two-handed the pointer is the right hand's - but while a trigger is held (and 0.5 s after) the game's
        -- aim goes through the BARREL's point, so shots land where the barrel points
        local barrel = hudp.PB ~= nil and (body.fire_t or 0) > 0
        if T >= quiet_until and not headaim and not sprint_w then pp, py = pointer_rotation(pawn, barrel) end
        if pp ~= nil and barrel then src = "barrel (trigger held, two-handed)" end
        if pp == nil then pp, py = hpch, body.yaw + hy + menu_shift.yaw; src = headaim and "head (binoculars)" or (sprint_w and "head (sprinting)" or "head") end
        -- v6.1: carrying - smooth the direction (hand tremor 110 cm out made the physics handle oscillate)
        local held_now = held_object(pawn)
        body.carrying = held_now ~= nil
        if body.carrying then
            -- v6.6.14: smoothing only against hand tremor - a quick turn of the hand (a throw) is followed at once
            local gap = math.abs(((py - (body.cyaw or py)) + 540) % 360 - 180) + math.abs(pp - (body.cpitch or pp))
            local rate = 10 + math.min(60, gap * 6)
            if V62.throw_snap ~= nil and T < V62.throw_snap then rate = 1000 end
            local k = 1 - math.exp(-delta * rate)
            if body.cyaw == nil then body.cyaw, body.cpitch = py, pp end
            body.cyaw = body.cyaw + (((py - body.cyaw) + 540) % 360 - 180) * k
            body.cpitch = body.cpitch + (pp - body.cpitch) * k
            py, pp = body.cyaw, body.cpitch
            V62.carry_aim = { py, pp }
        else
            body.cyaw, body.cpitch = nil, nil
        end
        guarded("throw", V62.throw_watch, pawn, firing, held_now)
        report_ctrl_jump(py, src)
        pc:SetControlRotation(mkrot(pp, py, 0))
        body.cy, body.cp = py, pp
        -- v4.12: carrying something: the game holds it in front of the BODY's facing (only up/down followed your hand).
        -- Turn the body - not your view, which is drawn from our own yaw - toward where your hand points.
        if body.carrying then
            pawn:K2_SetActorRotation(mkrot(0, py, 0), false)
            if not body.carry_logged then body.carry_logged = true; LOG("carrying: body faces your hand so the object follows left/right too") end
        end
    end
    if body.aim_src ~= src then body.aim_src = src; LOG("aim source: " .. src) end
    V62.walk_send(body, delta)
end

-- (v4.20: the window-size code of v4.16-v4.19 is gone - the game enforces its own 1920x1080 window.)

---------------------------------------------------------------------------
-- 5: recentre + height on level load
---------------------------------------------------------------------------
local recenter_at, last_pc = nil, nil
-- v6.6.43: YOUR STANDING HEIGHT. The height reset maps "where the headset is right now" to the game's eye height. Done
-- while you are bent down (the v6.6.32 session: 1.24 m instead of 1.77 m, at level-ready) it leaves you that much too
-- tall as soon as you straighten up - "put up into the air". The headset's height is sampled twice a second (0.9-2.3 m:
-- on a head, not on a desk). Standing height = the 90th percentile of the last 5 minutes (needs 10 s of samples).
-- A reset uses it instead of the current height only when the head is 10-90 cm below it AND was upright (within 8 cm of
-- it) at some point in the last 20 s - a momentary bend, not a change of posture. Sitting down to play (low for more than
-- 20 s) and standing up from a seat (higher than before) are left alone, as is everything in the first seconds.
function V62.stand_ref()                                       -- -> metres; nil = not known yet
    local H = V62.sh
    if H.n < 20 then return nil end
    local srt = {}
    for k = 1, H.n do srt[k] = H.buf[k] end
    table.sort(srt)
    return srt[math.max(1, math.floor(H.n * 0.9))]
end
function V62.stand_recent_max(secs)                            -- the highest the head was in the last <secs> seconds
    local H = V62.sh
    local mx = nil
    for k = 0, math.min(H.n, math.floor(secs * 2)) - 1 do
        local y = H.buf[(H.i - 1 - k) % 600 + 1]
        if y ~= nil and (mx == nil or y > mx) then mx = y end
    end
    return mx
end
function V62.stand_sample()                                    -- game tick
    local H = V62.sh
    if T < H.t then return end
    H.t = T + 0.5
    if not pcall(vr.get_pose, vr.get_hmd_index(), H.p, H.q) then return end
    local y = Y(H.p)
    if type(y) ~= "number" or y < 0.9 or y > 2.3 then return end
    H.i = H.i % 600 + 1
    H.buf[H.i] = y
    if H.n < 600 then H.n = H.n + 1 end
end
local function reset_height(manual)
    vr.get_pose(vr.get_hmd_index(), to, tr)
    pcall(vr.recenter_view)
    local origin, note = to, ""
    if manual == true then
        V62.sh.n, V62.sh.i = 0, 0                               -- the height you chose: learn the standing height afresh from here
    elseif S.height_stand ~= false then
        local ref, y = V62.stand_ref(), Y(to)
        if ref ~= nil and type(y) == "number" then
            local d = ref - y
            local recent = V62.stand_recent_max(20)
            if d > 0.10 and d < 0.90 and recent ~= nil and recent >= ref - 0.08 then
                origin = Vector3f.new(X(to), ref, Z(to))
                note = string.format(" - your head was %d cm below your standing height (%.2f m) and upright a moment before: the standing height was used, so straightening up no longer lifts you off the ground",
                    math.floor(d * 100 + 0.5), ref)
            end
        end
    end
    pcall(vr.set_standing_origin, origin)
    LOG(string.format("recentred, height reset (head at %.2f, %.2f, %.2f)%s", X(to), Y(to), Z(to), note))
    if menu_mode and not menu_flat_now then       -- v5.5: a level-start reset while a VR menu is up
        menu_shift.yaw, menu_shift.ro = 0, nil
        pcall(place_menu_front)
    end
    saved_view = nil                                -- never "restore" a flat-menu view from before the reset
end
local function update_recenter(delta)
    local pc = api:get_player_controller(0)
    if not same(pc, last_pc) then
        -- v6.0: only the very first controller (main menu) triggers a recentre here; level loads recentre once the
        -- level is READY (update_world), never in the middle of the load
        if last_pc == nil and pc ~= nil and S.auto_recenter and not lvl.first_rc then lvl.first_rc = true; recenter_at = 1.5 end
        last_pc = pc
    end
    if recenter_at ~= nil then
        recenter_at = recenter_at - delta
        if recenter_at <= 0 then recenter_at = nil; reset_height() end
    end
end

---------------------------------------------------------------------------
-- level / pawn changes
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- v5.0: VR RENDER TWEAKS (borrowed from what the well-known UEVR profiles do). Flat-screen post effects that hurt in
-- VR: motion blur (smear), chromatic aberration (colour fringes), depth of field (blurry weapon), lens flares, and the
-- tonemapper's vignette + film grain (the dark aiming vignette that blocks the view). They are console variables,
-- applied about a second after each level load (the game may reset some on load). They only change shader paths -
-- no render-target reallocation. Anti-aliasing is left to the game's own setting (set FXAA in-game): forcing it
-- from here could fight that setting and cause exactly the render-target churn we avoid.
---------------------------------------------------------------------------
local RENDER_TWEAKS = {
    "r.MotionBlurQuality 0",
    "r.SceneColorFringeQuality 0",
    "r.DepthOfFieldQuality 0",
    "r.LensFlareQuality 0",
    "r.Tonemapper.Quality 0",
    -- v5.2: CLARITY. In one-eye-per-frame VR, temporal AA (TSR/TAA) smears detail between eyes = the "blurry/low-res"
    -- look. Force FXAA (non-temporal), render the scene at full 100% (no upscaling), and add a light sharpen. These
    -- are shader-path cvars only - no render-target reallocation. They line up with the in-game FXAA setting.
    -- v6.0: r.AntiAliasingMethod / r.ScreenPercentage removed (game setting / UEVR-managed - fighting them reallocates
    -- render targets). Set FXAA in the game's own graphics settings.
    -- v6.3: r.Tonemapper.Sharpen is now set by the graphics preset (V62.GFX)
    -- v5.3: DISTANCE detail ("this game is all about spotting things in the distance"). Hold higher LODs further
    -- out, draw further, and keep textures at full mip. Conservative values; a 5080 has the headroom.
    "r.ViewDistanceScale 1.5",
    -- v6.2: eased (more distant detail = more shimmer once the tester's view showed it); TAA is now on in the game
    "r.StaticMeshLODDistanceScale 0.8",
    "r.SkeletalMeshLODBias 0",
    "foliage.LODDistanceScale 1.0",
    -- v6.0: r.MipMapLODBias removed - changing it at runtime races the render threads (Epic UE-369233).
}
local tweaks_due, tweaks_logged = nil, false   -- v6.0: progress kept in lvl.tw_i / lvl.tw_set
-- v6.0: ONE cvar per frame, and only when the game has changed it from our value (read first). The same values are in
-- user_script.txt, which UEVR runs once at the main menu - so normally this finds nothing to do.
local function step_render_tweaks(pawn)
    if not S.vr_render_tweaks then tweaks_due = nil; return end
    if KSYS == nil then local c = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"); KSYS = c and c:get_class_default_object() end
    if KSYS == nil then tweaks_due = nil; LOG("render tweaks: console library not found"); return end
    lvl.tw_i = lvl.tw_i or 1
    local cmd = RENDER_TWEAKS[lvl.tw_i]
    if cmd == nil then
        tweaks_due, lvl.tw_i = nil, nil
        if not tweaks_logged or (lvl.tw_set or 0) > 0 then
            tweaks_logged = true
            LOG(string.format("VR render tweaks checked: %d of %d needed re-applying after the level load", lvl.tw_set or 0, #RENDER_TWEAKS))
        end
        lvl.tw_set = 0
        return
    end
    lvl.tw_i = lvl.tw_i + 1
    local name, want = cmd:match("^(%S+)%s+(%S+)$")
    want = tonumber(want)
    if name == nil or want == nil then return end
    local P = V62.GFX[S.gfx_level or 2]                          -- v6.6.45: the active graphics preset has the say over what it sets
    if P ~= nil and P.cv[name] ~= nil then return end
    local have = safe(function() return KSYS:GetConsoleVariableFloatValue(name) end)
    if type(have) == "number" and math.abs(have - want) < 0.001 then return end
    if pcall(function() KSYS:ExecuteConsoleCommand(pawn, cmd, nil) end) then lvl.tw_set = (lvl.tw_set or 0) + 1 end
end

---------------------------------------------------------------------------
-- v6.0 LEVEL LIFECYCLE. The game shows LoadingScreen_Widget (created by its GameInstance) for the whole level load,
-- spawns the new body ~1 s in while the old world is still being torn down, and only then fades in. v5.5 started the
-- per-eye hooks, moved the HUD widget, recentred and set cvars right in that window - and every session since froze
-- or crashed there. Now: nothing touches the world until the loading screen is gone AND the body has been stable for
-- S.level_settle seconds (pattern from uevrlib's level-change detection).
---------------------------------------------------------------------------
lvl = { ready = false, free = false, calm_since = nil, scan_t = 0, loading = false, lw = nil, pawn = nil, just_ready = false, busy_logged = 0 }
local LV = { cls = nil }
function V62.hide_loading(w)                -- v6.6.12: the loading screen's black box made see-through
    if not S.hide_loading_box then return end
    local a = addr(w)
    local ok = pcall(function() w:SetRenderOpacity(0.0) end)    -- v6.6.14: every time (its fade-in sets it back)
    if a == nil or V62.lw_hidden == a then return end
    V62.lw_hidden = a
    V62.lwh = (V62.lwh or 0) + 1
    if V62.lwh <= 4 then LOG("loading screen: black box made see-through (" .. tostring(ok) .. ")") end
end
function LV.loading_widget_up(delta)
    -- the cached widget first (cheap), a class scan at most 4x a second otherwise
    local w = lvl.lw
    if w ~= nil and obj_ok(w) and safe(function() return w:IsInViewport() end) == true then V62.hide_loading(w); return true end
    lvl.scan_t = lvl.scan_t - delta
    if lvl.scan_t > 0 then return false end
    lvl.scan_t = 0.25
    if LV.cls == nil then
        LV.cls = api:find_uobject("WidgetBlueprintGeneratedClass /Game/Classes/GUI/LoadingScreen_Widget.LoadingScreen_Widget_C") or false
        LOG("loading-screen detector: " .. (LV.cls and "ready" or "class not found yet"))
    end
    if not LV.cls then LV.cls = nil; return false end
    local all = safe(function() return UEVR_UObjectHook.get_objects_by_class(LV.cls, false) end)
    if type(all) ~= "table" then return false end
    for _, o in ipairs(all) do
        if obj_ok(o) and not fullname(o):find("Default__") and safe(function() return o:IsInViewport() end) == true then
            lvl.lw = o
            V62.hide_loading(o)
            return true
        end
    end
    return false
end
function LV.update(pc, pawn, delta)
    lvl.loading = LV.loading_widget_up(delta)
    V62.lv_pawn = pawn                                                   -- v6.6.18 (fade: no body = main menu)
    if V62.hooked == nil then pcall(V62.hook_loading) end              -- v6.6.14
    if lvl.loading then V62.fade(true, "loading screen seen") end
    guarded("fade", V62.fade_update, delta)                              -- v6.6.15
    local why = nil
    if pawn == nil then why = "no player body"
    elseif not same(pawn, lvl.pawn) then lvl.pawn = pawn; why = "new player body"
    elseif lvl.loading then why = "loading screen" end
    if why ~= nil then
        if lvl.ready or lvl.calm_since ~= nil then
            lvl.busy_logged = lvl.busy_logged + 1
            if lvl.busy_logged <= 40 then LOG("level busy (" .. why .. ") - VR hands/HUD/body wait until it settles") end
        end
        lvl.ready, lvl.free, lvl.calm_since = false, false, nil
        return
    end
    if lvl.ready then return end
    lvl.calm_since = lvl.calm_since or T
    if not lvl.free and T - lvl.calm_since >= 0.3 then
        lvl.free, lvl.just_free = true, true
        LOG(string.format("loading screen gone - walking/turning on (gun, HUD and hands follow in %.1f s)", S.level_settle or 1.5))
    end
    if T - lvl.calm_since >= (S.level_settle or 1.5) then
        lvl.ready, lvl.just_ready, lvl.ready_t = true, true, T
        LOG(string.format("level ready (%.1f s after the loading screen) - VR features on [controller Loading=%s Paused=%s]",
            T - lvl.calm_since, tostring(safe(function() return pc.Loading end)), tostring(safe(function() return pc.Paused end))))
    end
end

-- v6.6.21: PERFORMANCE PROBE. One effect at a time is switched off for 5 s, measured, and put back. The number that
-- counts is GPU time per frame = (game's GPU 3D busy %) x (frame time) - it still shows a saving when the frame rate is
-- already at the 90 cap. A baseline is re-measured every 4 effects (the scene may change). Nothing is kept.
V62.PROBE = {
    { "virtual shadow maps -> classic shadows", "r.Shadow.Virtual.Enable", 0 },
    { "sun shadow resolution 1024", "r.Shadow.MaxCSMResolution", 1024 },
    { "shadows drawn 60% as far", "r.Shadow.DistanceScale", 0.6 },
    { "volumetric fog off", "r.VolumetricFog", 0 },
    { "screen-space reflections off", "r.SSR.Quality", 0 },
    { "ambient occlusion off", "r.AmbientOcclusionLevels", 0 },
    { "distance-field shadows off", "r.DistanceFieldShadowing", 0 },
    { "bloom off", "r.BloomQuality", 0 },
    { "TSR history 150% -> 100%", "r.TSR.History.ScreenPercentage", 100 },
    { "view distance 60%", "r.ViewDistanceScale", 0.6 },
    { "internal resolution 85% -> 75% (for comparison)", "r.ScreenPercentage.Default", 75 },
}
local function pp_set(n, v)
    if v == nil then return end
    local pawn = api:get_local_pawn(0)
    pcall(function() KSYS:ExecuteConsoleCommand(pawn, n .. " " .. tostring(v), nil) end)
end
function V62.probe_measure()                                  -- also starts sf_perf's next window
    V62.perf_raw = nil
    pcall(function() api:dispatch_custom_event("sfperf", "report") end)
    local pf = V62.perf_raw
    if pf == nil then return nil end
    local fps, g = tonumber(pf:match("fps=([^;]+)")), tonumber(pf:match("gpu_game=([^;]+)"))
    if fps == nil or g == nil or fps <= 1 or g < 0 then return nil end
    return fps, g, g / 100 * 1000 / fps, pf:match("gpu_top=([^;]+)")
end
function V62.probe_restore()
    local pp = V62.pp
    if pp ~= nil and pp.cur ~= nil then pp_set(pp.cur[2], pp.orig[pp.cur[2]]); pp.cur = nil end
end
function V62.probe_abort(why)
    if V62.pp == nil then return end
    V62.probe_restore()
    V62.pp = nil
    LOG("PERFORMANCE PROBE stopped (" .. tostring(why) .. ") - every setting is back as it was")
    haptic(0, 0.05, 0.4)
end
function V62.probe_start(why)
    if V62.pp ~= nil then return end
    if KSYS == nil then LOG("PERFORMANCE PROBE: console not ready yet"); return end
    local pp = { phase = "wait", t = T + 3.0, res = {}, orig = {}, base = {}, list = {}, k = 1 }   -- (list[1] = the first baseline)
    local cur = {}
    for i, c in ipairs(V62.PROBE) do
        local v = safe(function() return KSYS:GetConsoleVariableFloatValue(c[2]) end)
        pp.orig[c[2]] = v
        cur[#cur + 1] = c[2] .. "=" .. tostring(v)
        if (i - 1) % 4 == 0 then pp.list[#pp.list + 1] = false end   -- baseline before every 4 effects
        pp.list[#pp.list + 1] = c
    end
    pp.list[#pp.list + 1] = false
    V62.pp = pp
    LOG("PERFORMANCE PROBE started (" .. tostring(why) .. ") - stand still and look at one busy spot for about 1.5 minutes")
    LOG("probe: the game's values now: " .. table.concat(cur, ", "))
    haptic(0, 0.12, 0.9); haptic(1, 0.12, 0.9)
end
function V62.probe_step(pawn, delta)
    local pp = V62.pp
    if pp == nil then return end
    if menu_mode or not lvl.ready then V62.probe_abort("a menu opened or the level changed"); return end
    if T >= (pp.tick or 0) then pp.tick = T + 3.0; haptic(0, 0.02, 0.35) end   -- v6.6.24: "still running"
    local hd = track.head
    local yaw = hd and math.deg(math.atan(hd[5], hd[4])) or 0
    if pp.phase == "measure" then
        if math.abs((pad.lx or 0) / 32767) + math.abs((pad.ly or 0) / 32767) + math.abs((pad.rx or 0) / 32767) > 0.35 then pp.moved = true end
        if pp.y0 ~= nil and math.abs(((yaw - pp.y0) + 540) % 360 - 180) > 25 then pp.moved = true end
    end
    if T < pp.t then return end
    if pp.phase == "wait" then
        V62.probe_measure()
        pp.phase, pp.t, pp.moved, pp.y0 = "measure", T + 4.0, false, yaw
        return
    end
    local fps, g, ms, top = V62.probe_measure()
    local c = pp.cur
    pp.last_base = (c == nil)
    if c == nil then
        if fps ~= nil then
            pp.base[#pp.base + 1] = { fps = fps, ms = ms, moved = pp.moved }
            LOG(string.format("probe: as it is now: %.1f fps, GPU %.0f%% busy = %.2f ms per frame%s | other GPU users: %s",
                fps, g, ms, pp.moved and " (you moved)" or "", tostring(top)))
        end
    else
        V62.probe_restore()
        local b = pp.base[#pp.base]
        if fps ~= nil and b ~= nil then
            local r = { label = c[1], save = b.ms - ms, dfps = fps - b.fps, moved = pp.moved or b.moved }
            pp.res[#pp.res + 1] = r
            LOG(string.format("probe: %s: %.1f fps, %.2f ms -> saves %.2f ms per frame (%+.1f fps)%s", c[1], fps, ms, r.save, r.dfps,
                r.moved and " (you moved - unreliable)" or ""))
        end
    end
    -- next item (an effect already off is skipped)
    while true do
        pp.k = pp.k + 1
        local nx = pp.list[pp.k]
        if nx == nil then
            table.sort(pp.res, function(a, b2) return a.save > b2.save end)
            local out = {}
            for i, r in ipairs(pp.res) do
                if i > 10 then break end
                out[#out + 1] = string.format("%s %.2f ms%s", r.label, r.save, r.moved and "?" or "")
            end
            local b0 = pp.base[1]
            LOG(string.format("PERFORMANCE PROBE done - at %.1f fps (%.2f ms GPU per frame; 90 Hz needs under ~10 ms). Biggest savings first: %s",
                b0 and b0.fps or 0, b0 and b0.ms or 0, table.concat(out, " | ")))
            V62.pp = nil
            haptic(0, 0.8, 1.0); haptic(1, 0.8, 1.0)
            return
        end
        if nx == false and not pp.last_base then pp.phase, pp.t = "wait", T + 1.5; return end
        if nx ~= false then
        local v = pp.orig[nx[2]]
        if type(v) == "number" and math.abs(v - nx[3]) < 0.001 then
            LOG("probe: " .. nx[1] .. ": already like that in this game - skipped")
        else
            pp.cur = nx
            pp_set(nx[2], nx[3])
            pp.phase, pp.t = "wait", T + 1.5
            return
        end
        end
    end
end
-- v6.6.26: HELMET LIGHT. A light the game attaches to its camera (which points where you aim) is moved onto the
-- head point (the component the audio listener uses, moved to the headset every frame).
V62.hl = { t = 0, done = {} }
function V62.head_light(pawn)
    if S.head_light == false or T < V62.hl.t or body == nil or not alive(body.cam) then return end
    V62.hl.t = T + 0.5
    local hp = V62.au.comp
    if hp == nil or not obj_ok(hp) then return end
    local comps = safe(function() return pawn:K2_GetComponentsByClass(G.SceneClass) end)
    if type(comps) ~= "table" then return end
    for _, c in ipairs(comps) do
        local ca = addr(c)
        if ca ~= nil and not V62.hl.done[ca] and same(safe(function() return c.AttachParent end), body.cam) then
            local cn = safe(function() return shortclass(c) end) or ""
            local n = safe(function() return c:get_fname():to_string() end) or ""
            local l = (cn .. " " .. n):lower()
            if l:find("light", 1, true) or l:find("lamp", 1, true) or l:find("torch", 1, true) or l:find("childactor", 1, true) then
                V62.hl.done[ca] = true
                local rl, rr = safe(function() return c.RelativeLocation end), safe(function() return c.RelativeRotation end)
                local ok = pcall(function() c:K2_AttachToComponent(hp, G.NONE, 2, 2, 2, false) end)
                if ok and rl ~= nil and rr ~= nil then pcall(set_rel, c, rl.X or 0, rl.Y or 0, rl.Z or 0, rr.Pitch or 0, rr.Yaw or 0, rr.Roll or 0) end
                V62.hl.n = (V62.hl.n or 0) + 1
                if V62.hl.n <= 10 then LOG("helmet light: " .. n .. " (" .. cn .. ") was on the game's camera (points where you aim) - now on your head" .. (ok and "" or " (attach failed)")) end
            end
        end
    end
end
-- MATERIAL VALUES (sf_mat.dll). UEVR's Lua cannot read arrays of structs; the plugin reads an object's array
-- properties by name (a material instance's ScalarParameterValues / VectorParameterValues ...). Read-only.
function V62.mat_read(obj, props)                             -- -> { Prop = { {name=, value=}, ... } } or nil
    local a = obj and addr(obj)
    if a == nil then return nil end
    V62.mat_raw = nil
    pcall(function() api:dispatch_custom_event("sfmat", string.format("read %x %s", a, props)) end)
    local raw = V62.mat_raw
    if raw == nil or raw == "" then return nil end
    local out = {}
    for line in raw:gmatch("[^\n]+") do
        local pname = line:match("^([%w_]+);")
        if pname ~= nil then
            local list = {}
            out[pname] = list
            if not line:find(";err=", 1, true) then
                local fields = {}
                local fl = line:match(";f=([^;]*)")
                if fl ~= nil then for fd in fl:gmatch("[^,]+") do local nm = fd:match("^([^:]+):"); fields[#fields + 1] = nm or "?" end end
                for idx, vals in line:gmatch(";(%d+)=([^;]*)") do
                    local vv, k = {}, 0
                    for v in (vals .. "|"):gmatch("([^|]*)|") do k = k + 1; vv[fields[k] or ("#" .. k)] = v end
                    local name = vv["ParameterInfo.Name"] or vv["ParameterName"] or vv["Name"] or ("#" .. idx)
                    local value
                    if vv["ParameterValue"] ~= nil then value = vv["ParameterValue"]
                    elseif vv["ParameterValue.R"] ~= nil then value = (vv["ParameterValue.R"] or "?") .. " " .. (vv["ParameterValue.G"] or "?") .. " " .. (vv["ParameterValue.B"] or "?") .. " " .. (vv["ParameterValue.A"] or "?")
                    elseif vv["DefaultValue"] ~= nil then value = vv["DefaultValue"]
                    elseif vv["DefaultValue.R"] ~= nil then value = (vv["DefaultValue.R"] or "?") .. " " .. (vv["DefaultValue.G"] or "?") .. " " .. (vv["DefaultValue.B"] or "?") .. " " .. (vv["DefaultValue.A"] or "?")
                    else
                        local parts = {}
                        for kk, v2 in pairs(vv) do if kk ~= "ParameterInfo.Name" and kk ~= "ParameterName" then parts[#parts + 1] = kk .. "=" .. v2 end end
                        table.sort(parts); value = table.concat(parts, "/")
                    end
                    list[#list + 1] = { name = name, value = value }
                end
            else
                list.err = line:match(";err=([^;]*)") or "?"
            end
        end
    end
    return out
end
-- v6.6.38: SIGHT FIX. The sight's post-process material carries the sight's "Right" and "Down" world axes, written by the
-- sight during the game's update from the (recoil-kicked) pose. After the gun is put back in the hand before drawing
-- (view 0), those two vectors are rewritten from the real axes of the part the sight measures. Which part and which
-- axes: learned at rest per gun class by matching the material's vectors against the parts' axes (as drawn); if no part
-- matches within 0.8 deg nothing is written and the log says so. SetVectorParameterValue is not hooked by the mod.
V62.sf = { map = {}, n = 0, shots = 0 }
V62.SF_AX = { "forward", "back", "right", "left", "up", "down" }
local function sf_axes(comp)                                   -- the six unit axes of a component, world space
    local r = safe(function() return comp:K2_GetComponentRotation() end)
    if r == nil then return nil end
    local F, R, U = rot_axes(r.Pitch or 0, r.Yaw or 0, r.Roll or 0)
    return { F, { -F[1], -F[2], -F[3] }, R, { -R[1], -R[2], -R[3] }, U, { -U[1], -U[2], -U[3] } }
end
local function sf_parts(a, cac)
    local parts = {}
    local function add(nm, c) if c ~= nil and alive(c) then parts[#parts + 1] = { nm = nm, c = c } end end
    add("Arrow_SightRef", safe(function() return a.Arrow_SightRef end))
    add("Scope_Mesh", safe(function() return a.Scope_Mesh end))
    add("Lense", safe(function() return a.Lense end))
    add("sight root", safe(function() return a.RootComponent end))
    add("sight mount", cac)
    if cur ~= nil then add("gun mesh", cur.mesh) end
    return parts
end
function V62.sight_fix()                                       -- first eye pass, after V62.gun_hold
    if S.sight_fix == false or cur == nil or not obj_ok(cur.actor) or cur.cls:sub(1, 4) ~= "Wep_" or not lvl.ready then return end
    local X = V62.sf
    if not V62.bino_libs() then return end                        -- the component classes (G.CAC) must be known
    if X.actor ~= cur.actor or (X.mid == nil and T > (X.retry or 0)) then
        X.actor, X.mid, X.a, X.cac, X.part, X.cal_t, X.shot, X.retry = cur.actor, nil, nil, nil, nil, T + 1.0, nil, T + 2.0
        local comps = safe(function() return cur.actor:K2_GetComponentsByClass(G.CAC) end)
        if type(comps) == "table" then
            for _, c in ipairs(comps) do
                local nme = (safe(function() return c:get_fname():to_string() end) or ""):lower()
                if nme:find("scope", 1, true) or nme:find("sight", 1, true) then
                    local a = safe(function() return c.ChildActor end)
                    local mid = a and safe(function() return a.CrosshairDynamicMat end)
                    if mid ~= nil then X.mid, X.a, X.cac, X.lens, X.imp_logged = mid, a, c, safe(function() return a.Lense end), false; break end
                end
            end
        end
        if X.mid == nil then return end
        -- a mapping learned before for this gun class: resolve its part on this actor
        local m = X.map[cur.cls]
        if m ~= nil then
            for _, p in ipairs(sf_parts(X.a, X.cac)) do if p.nm == m.part then X.part, X.ri, X.di = p.c, m.ri, m.di end end
        end
        return
    end
    if X.mid == nil or not alive(X.mid) then return end
    if X.part == nil then
        -- learn: at rest, the material's own Right / Down vs the parts' axes (as drawn, i.e. after the gun was put back)
        if T < (X.cal_t or 0) or T - (V62.last_shot or -10) < 1.5 then return end
        X.cal_t = T + 2.0
        local lists = V62.mat_read(X.mid, "VectorParameterValues")
        local mr, md = nil, nil
        if lists ~= nil then
            for _, e in ipairs(lists.VectorParameterValues or {}) do
                local x, y, z = e.value:match("^(%S+) (%S+) (%S+)")
                if x ~= nil then
                    if e.name == "Right" then mr = { tonumber(x), tonumber(y), tonumber(z) } elseif e.name == "Down" then md = { tonumber(x), tonumber(y), tonumber(z) } end
                end
            end
        end
        if mr == nil or md == nil then
            X.nomat = (X.nomat or 0) + 1
            if X.nomat == 2 then LOG("red dot: " .. cur.cls .. "'s sight material has no Right / Down vectors to read - nothing to correct here") end
            return
        end
        local best = { d = -2 }
        for _, p in ipairs(sf_parts(X.a, X.cac)) do
            local ax = sf_axes(p.c)
            if ax ~= nil then
                local br, bd = { d = -2 }, { d = -2 }
                for i = 1, 6 do
                    local v = ax[i]
                    local dr = v[1] * mr[1] + v[2] * mr[2] + v[3] * mr[3]
                    local dd = v[1] * md[1] + v[2] * md[2] + v[3] * md[3]
                    if dr > br.d then br = { d = dr, i = i } end
                    if dd > bd.d then bd = { d = dd, i = i } end
                end
                local score = math.min(br.d, bd.d)
                if score > best.d then best = { d = score, part = p, ri = br.i, di = bd.i } end
            end
        end
        X.tries = (X.tries or 0) + 1
        if best.d > 0.9999 then                                    -- within ~0.8 deg on both axes
            X.part, X.ri, X.di = best.part.c, best.ri, best.di
            X.map[cur.cls] = { part = best.part.nm, ri = best.ri, di = best.di }
            LOG(string.format("red dot: %s's crosshair is placed from %s's %s (Right) and %s (Down) - from now on set from the gun as drawn, every frame",
                cur.cls, best.part.nm, V62.SF_AX[best.ri], V62.SF_AX[best.di]))
        elseif X.tries <= 3 then
            LOG(string.format("red dot: %s's crosshair vectors match no part yet (best %s, %.3f) - looking again", cur.cls, best.part and best.part.nm or "?", best.d))
        end
        return
    end
    if not alive(X.part) then X.part = nil; return end
    local ax = sf_axes(X.part)
    if ax == nil then return end
    local r, d = ax[X.ri], ax[X.di]
    -- v6.6.39: the dot marks where the SHOT lands: the direction from the optic to the point where the barrel line hits
    -- (hudp.P, the pointer's aim point; nothing hit -> 50 m). The sight's own roll is kept (its right axis, made square).
    if S.sight_impact ~= false then
        local optic = (X.lens ~= nil and alive(X.lens)) and X.lens or X.part
        local Sl = safe(function() return optic:K2_GetComponentLocation() end)
        local mz = V62.muzzle()
        local ml = mz and safe(function() return mz:K2_GetComponentLocation() end)
        local mr = mz and safe(function() return mz:K2_GetComponentRotation() end)
        if Sl ~= nil and ml ~= nil and mr ~= nil then
            local Fm = rot_axes(mr.Pitch or 0, mr.Yaw or 0, 0)
            local P, tm = hudp.PB or hudp.P, 5000                 -- (v6.6.45: PB = the barrel's point when the pointer is the hand's)
            if P ~= nil then
                tm = (P[1] - (ml.X or 0)) * Fm[1] + (P[2] - (ml.Y or 0)) * Fm[2] + (P[3] - (ml.Z or 0)) * Fm[3]
                if tm < 50 then tm = 50 elseif tm > 20000 then tm = 20000 end
            end
            local tx, ty, tz = (ml.X or 0) + Fm[1] * tm - (Sl.X or 0), (ml.Y or 0) + Fm[2] * tm - (Sl.Y or 0), (ml.Z or 0) + Fm[3] * tm - (Sl.Z or 0)
            local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
            if tl > 1 then
                local F = { tx / tl, ty / tl, tz / tl }
                local trim = math.rad(S.sight_trim_deg or 0)
                if trim ~= 0 then                                  -- manual trim: tip the direction about the sight's right axis
                    local ct, st = math.cos(trim), math.sin(trim)
                    local up = { -d[1], -d[2], -d[3] }
                    F = { F[1] * ct + up[1] * st, F[2] * ct + up[2] * st, F[3] * ct + up[3] * st }
                    local fl = math.sqrt(F[1] ^ 2 + F[2] ^ 2 + F[3] ^ 2); F = { F[1] / fl, F[2] / fl, F[3] / fl }
                end
                local k = r[1] * F[1] + r[2] * F[2] + r[3] * F[3]
                local rx, ry, rz = r[1] - k * F[1], r[2] - k * F[2], r[3] - k * F[3]
                local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
                if rl > 0.5 then
                    r = { rx / rl, ry / rl, rz / rl }
                    d = { r[2] * F[3] - r[3] * F[2], r[3] * F[1] - r[1] * F[3], r[1] * F[2] - r[2] * F[1] }   -- Down = Right x Forward (UE)
                    if not X.imp_logged then
                        X.imp_logged = true
                        -- the optic's height over the barrel line, for the record
                        local hx, hy, hz = (Sl.X or 0) - (ml.X or 0), (Sl.Y or 0) - (ml.Y or 0), (Sl.Z or 0) - (ml.Z or 0)
                        local along = hx * Fm[1] + hy * Fm[2] + hz * Fm[3]
                        local h = math.sqrt(math.max(0, hx * hx + hy * hy + hz * hz - along * along))
                        LOG(string.format("red dot: %s's optic sits %.1f cm off the barrel line - the dot now points where the barrel line hits (%.1f m away right now), so the shot lands on the dot",
                            cur.cls, h, tm / 100))
                    end
                end
            end
        end
    end
    local since = T - (V62.last_shot or -10)
    if since < 1.0 and X.shots < 3 then                        -- the first shots: how far off the game had it (for the log)
        if X.shot == nil then X.shots = X.shots + 1; X.shot = { max = 0, f = 0 } end
        if X.shot.f <= 12 then
            local lists = V62.mat_read(X.mid, "VectorParameterValues")
            if lists ~= nil then
                for _, e in ipairs(lists.VectorParameterValues or {}) do
                    if e.name == "Down" then
                        local x, y, z = e.value:match("^(%S+) (%S+) (%S+)")
                        if x ~= nil then
                            local dot = (tonumber(x) or 0) * d[1] + (tonumber(y) or 0) * d[2] + (tonumber(z) or 0) * d[3]
                            local ang = math.deg(math.acos(math.max(-1, math.min(1, dot))))
                            if ang > X.shot.max then X.shot.max = ang end
                        end
                    end
                end
            end
        end
        X.shot.f = X.shot.f + 1
    elseif X.shot ~= nil then
        LOG(string.format("red dot: %s - during that shot the game had the crosshair up to %.2f deg off the gun; it was set from the gun as drawn instead", cur.cls, X.shot.max))
        X.shot = nil
    end
    local c = StructObject.new(G.LinColor)
    c.R, c.G, c.B, c.A = r[1], r[2], r[3], 1.0
    local ok1 = pcall(function() X.mid:SetVectorParameterValue("Right", c) end)
    c.R, c.G, c.B, c.A = d[1], d[2], d[3], 1.0
    local ok2 = pcall(function() X.mid:SetVectorParameterValue("Down", c) end)
    X.n = X.n + 1
    if not (ok1 and ok2) then
        X.fail = (X.fail or 0) + 1
        if X.fail <= 2 then LOG("red dot: could not write the crosshair vectors (" .. tostring(ok1) .. "/" .. tostring(ok2) .. ")") end
        if X.fail >= 20 then S.sight_fix = false; LOG("red dot: crosshair fix switched itself off after 20 failed writes") end
    end
end
-- v6.6.45 TEST: YOUR BODY FOLLOWS YOUR HEAD (room-scale). The game's body only moved with the stick; stepping or leaning
-- moved your eyes and hands but not the body, and the game decides from the BODY what you can reach, whether your gun
-- is blocked by a wall (no shot, empty scope) and where enemies hit you (playtest 31:10-33:24, 40:05-40:42). UEVR has
-- this built in (VR_RoomscaleMovement: in its second-eye pass it moves the pawn by the headset's sideways offset, with a
-- sweep so walls stop it, and re-centres the standing origin sideways; it uses the view direction this script supplies).
-- The script only switches it: on in play, off in menus (they are placed with the standing origin), while a level
-- loads, during a fade and on ladders. Nothing is touched unless the option is on.
function V62.roomscale_update()
    local want = S.roomscale == true and lvl.ready and not menu_mode and not V62.faded and body ~= nil and body.ladder ~= true
        and T >= quiet_until and not V62.binoc_on
    if want == (V62.rs_on == true) then return end
    V62.rs_on = want
    if want then setmod("VR_RoomscaleMovementSweep", "true") end
    setmod("VR_RoomscaleMovement", want and "true" or "false")
    if (V62.rs_n or 0) < 12 then
        V62.rs_n = (V62.rs_n or 0) + 1
        LOG("room-scale: your body " .. (want and "follows your head now (UEVR moves the game's body with the headset; walls stop it)" or "stays put now (menu / loading / fade / ladder, or switched off)"))
    end
end
local last_pawn, sample_t = nil, 0
local last_pawn_info, info_t = nil, 0
local function update_world(delta)
    local pawn = api:get_local_pawn(0)
    local pc = api:get_player_controller(0)
    LV.update(pc, pawn, delta)
    vguard.pc, vguard.pawn, vguard.hold = pc, pawn, hold   -- v5.5 same-frame guard
    if not same(pawn, last_pawn) then
        last_pawn = pawn
        if last_pawn_info ~= nil then LOG("  (left previous body at " .. last_pawn_info .. ")") end
        cur, fit, light, hold, wrist, body, grip = nil, nil, nil, nil, nil, nil, nil
        V62.lh = nil                           -- v6.6.12: the left-hand point is made again for the new body
        twohand.on, twohand.m, held_other = false, nil, nil
        hudp.comp, hudp.P = nil, nil
        hudp.rcomp, hudp.rw, hudp.ring, hudp.cross, hudp.ring_sep, hudp.cross_off, hudp.dot_in = nil, nil, nil, nil, false, nil, nil   -- v6.6.29/32/41
        offh.actor, offh.root, offh.grip = nil, nil, nil
        inj.sub = nil
        ui_rescan = true                       -- new level = new UI widgets: look for effect layers soon
        view.ok = false
        wrist_readds = 0
        driven = {}
        tweaks_due, lvl.tw_i = nil, nil        -- v6.0: scheduled only once the level is READY (see below)
        body = nil                             -- v6.0: the old body is going away - drop it, don't touch it
        LOG("player changed: " .. fullname(pawn))
        pcall(V62.audio_off)                   -- v6.6.18: the head point goes with the old body - camera listener meanwhile
    end
    if pawn == nil then return end
    if not lvl.free then view.ok = false; return end       -- v6.0: loading - leave the world alone
    -- v6.1: walking / turning (and the view direction that goes with it) start as soon as the loading screen is gone
    if lvl.just_free then lvl.just_free = false; if S.auto_recenter then recenter_at = 0.05 end end   -- recentre BEFORE you walk
    if not track.hooked then guarded("hand_hook", start_hand_hook) end
    guarded("body", update_body, pawn, delta)
    if not lvl.ready then return end                         -- gun / HUD / hands wait for the settle time
    if lvl.just_ready then
        lvl.just_ready = false
        tweaks_due, lvl.tw_i, lvl.tw_set = T + 4.0 + math.max(0, 1.5 - (S.level_settle or 1.5)), 1, 0   -- v6.6.6: same time as before
    end
    if tweaks_due ~= nil and T >= tweaks_due then guarded("render_tweaks", step_render_tweaks, pawn) end
    if tweaks_due == nil and lvl.gfx_done ~= lvl.pawn then           -- v6.3: graphics preset after each level load
        lvl.gfx_done = lvl.pawn
        V62.gfx_queue(S.gfx_level or 2, "(after level load)")     -- v6.6: always (only values that differ are written)
    end
    if #V62.gfx_q > 0 then guarded("gfx", V62.gfx_step, pawn) end
    guarded("frame_controls", update_frame_controls, pawn, delta)   -- v6.1: also in the first second of a menu (View)
    if V62.gchk ~= nil then guarded("guncheck", V62.gun_check, pawn) end    -- v6.6.14
    guarded("uevrattach", V62.uevr_attach_watch)                          -- v6.6.43
    guarded("binoculars", V62.binoc_update, pawn, delta)                  -- v6.6.14
    guarded("audio", V62.audio_update, pc, pawn)                          -- v6.6.18
    guarded("ringpanel", V62.ring_panel_update, pawn)                     -- v6.6.29
    guarded("headlight", V62.head_light, pawn)                            -- v6.6.26
    guarded("probe", V62.probe_step, pawn, delta)                         -- v6.6.21
    guarded("watch", V62.watch_pawn, pawn, delta)                     -- v6.2
    info_t = info_t + delta
    if info_t > 0.5 then
        info_t = 0
        TRACE("pawn location/velocity")
        local l = safe(function() return pawn:K2_GetActorLocation() end)
        local v = safe(function() return pawn:GetVelocity() end)
        if l ~= nil then
            last_pawn_info = string.format("%.0f %.0f %.0f, speed %.0f down %.0f, map %s, T=%.1f", l.X or 0, l.Y or 0, l.Z or 0,
                v and math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2) or -1, v and -(v.Z or 0) or 0,
                (fullname(pawn):match("/Game/[^%.]+/([%w_]+)%.") or "?"), T)
        end
    end
    if T < quiet_until then                     -- v4.16: the game is rebuilding menus / swapping held items right now
        if not menu_mode then guarded("pointer", update_pointer, pawn) end   -- v6.3: but your cursor ring keeps moving
        return
    end
    guarded("gun", update_gun, pawn, delta)
    sample_t = (sample_t or 0) + delta
    if sample_t > 1.0 then sample_t = 0; guarded("check", sample_driven) end
    guarded("flashlight", update_light, pawn, delta)
    guarded("melee", update_melee)
    guarded("twohand", update_twohand, pawn)
    guarded("offhand", update_offhand, pawn)
    guarded("pointer", update_pointer, pawn)
    guarded("wrist", update_wrist, pawn, delta)
end

---------------------------------------------------------------------------
-- panel (UEVR menu > "Silverfish VR settings"; under Script UI on a UEVR without script pages)
---------------------------------------------------------------------------
function V62.section(title)                                  -- a fold-out part of the panel (plain heading if this UEVR has none)
    if imgui.collapsing_header ~= nil then return imgui.collapsing_header(title) end
    imgui.text("--- " .. title .. " ---")
    return true
end
local function draw_panel()
    imgui.text("Project Silverfish VR " .. SF_VERSION .. " - every switch")
    local nerr = 0
    for _, n in pairs(errors) do nerr = nerr + n end
    if nerr > 0 then imgui.text("Errors so far: " .. nerr .. "  (details in data\\sf_main_log.txt)") end
    local changed, val
    imgui.text(string.format("Level: %s%s", lvl.ready and "ready" or (lvl.loading and "LOADING (VR features waiting)" or "settling..."),
        lvl.ready and "" or string.format("  (%.1f s)", lvl.calm_since and (T - lvl.calm_since) or 0)))
    imgui.text("Gun in hand: " .. (cur and ((cur.dn or "?") .. "  (" .. cur.cls .. ")") or "none"))
    imgui.text("Sections below open with a click. Every switch is saved at once.")
    if V62.section("Controls (Steam Frame)") then
        imgui.text("R trigger fire | L trigger aim / use 2 | A interact | B reload (hold: ammo) | X fire-select | Y jump")
        imgui.text("R bumper: tap = pick up, hold = lower / raise the weapon | L bumper = mode (gun light / laser, pry, harvest)")
        imgui.text("Menu = pause | View = journal | D-pad: up flashlight, down inventory, left / right previous / next weapon")
        imgui.text("L stick click = sprint (in menus: shift-click, also L grip) | R stick click = crouch | R stick scrolls menus")
        imgui.text("Squeeze L grip fully + D-pad up / right / down / left = utility slots 5 / 6 / 7 / 8")
        imgui.text("Hold R grip + Y = crouch-jump | hold L grip on a long gun's fore-grip / barrel = two-handed")
        imgui.text("L grip + View = next graphics preset: High > Medium > Low > Performance (1 to 4 buzzes)")
        imgui.text("Both stick clicks (hold) = UEVR menu")
        imgui.text("Optional (switches below): R grip = quick melee | L hand on your chest + grip = flashlight")
        changed, val = imgui.checkbox("Steam Frame button handling (bumpers, View, D-pad left/right)", S.frame_controls)
        if changed then S.frame_controls = val; save_settings() end
        changed, val = imgui.checkbox("D-pad left/right: weapons only (skip utility items)", S.weapons_only_dpad)
        if changed then S.weapons_only_dpad = val; save_settings() end
        changed, val = imgui.checkbox("Right grip = quick melee", S.quick_melee)
        if changed then S.quick_melee = val; save_settings() end
        changed, val = imgui.checkbox("Swing the right hand to melee (old)", S.melee_swing)
        if changed then S.melee_swing = val; save_settings() end
        changed, val = imgui.checkbox("Right bumper: tap = pick up, hold = lower / raise the weapon (off = hold G as before)", S.lower_direct)
        if changed then S.lower_direct = val; save_settings() end
        changed, val = imgui.checkbox("Flashlight: left hand on your chest + grip", S.chest_flashlight)
        if changed then S.chest_flashlight = val; save_settings() end
        changed, val = imgui.checkbox("Buzz when a hand enters a gesture zone", S.zone_haptics)
        if changed then S.zone_haptics = val; save_settings() end
        changed, val = imgui.checkbox("Off-hand flashlight starts in the raised hold, for a hand held up by your head (off = starts as a torch: beam where your hand points). Left trigger switches", S.fl_start_raised == true)
        if changed then S.fl_start_raised = val; save_settings() end
        imgui.text("Left hand on chest now: " .. tostring(fc.zone[0] == "chest") .. "   Frame actions found: " .. tostring(fc.ok))
    end
    if V62.section("Gun in the hand") then
        if cur ~= nil and GUNS[cur.cls] ~= nil then
            local g = GUNS[cur.cls]
            imgui.text("Holding: " .. cur.cls .. (g.fitted and "  (fitted)" or "  (automatic)"))
            if fit ~= nil then
                imgui.text(string.format("FITTING - hold the grip now... %.0f", fit.t))
            elseif imgui.button("Fit gun to hand (8 s)") then
                start_fit()
            end
            local any = false
            changed, val = imgui.drag_float3("Gun position (cm)", Vector3f.new(g.x, g.y, g.z), 0.2, -100, 100)
            if changed then g.x, g.y, g.z = X(val), Y(val), Z(val); any = true end
            changed, val = imgui.drag_float3("Gun angle (pitch, yaw, roll)", Vector3f.new(g.pitch, g.yaw, g.roll), 0.5, -180, 180)
            if changed then g.pitch, g.yaw, g.roll = X(val), Y(val), Z(val); any = true end
            if any and fit == nil then guarded("gun", apply_gun); save_settings() end
            if imgui.button("Reset this gun to automatic") then
                local a, c = cur.actor, cur.cls
                GUNS[c] = nil
                guarded("gun", release_gun); save_settings()
                if hold ~= nil then guarded("gun", take_gun, a, c) end
            end
        else
            imgui.text("Holding: nothing")
        end
        changed, val = imgui.slider_float("Gun angle (deg, negative = barrel down)", S.grip_angle, -80, 40)
        if changed then S.grip_angle = val; save_settings() end
        changed, val = imgui.checkbox("Two-handed grip (left hand on the fore-grip steers long guns)", S.two_handed)
        if changed then S.two_handed = val; save_settings() end
        changed, val = imgui.checkbox("Two-handed only while the left grip is held", S.twohand_hold)
        if changed then S.twohand_hold = val; save_settings() end
        changed, val = imgui.checkbox("Two-handed: the dot and picking up follow your RIGHT HAND (shots still follow the barrel)", S.twohand_hand_pointer ~= false)
        if changed then S.twohand_hand_pointer = val; save_settings() end
        changed, val = imgui.checkbox("Three ticks in the gun hand when you pull the trigger and the game has the gun blocked (too close to a wall)", S.blocked_buzz ~= false)
        if changed then S.blocked_buzz = val; save_settings() end
        imgui.text("Two-handed now: " .. tostring(twohand.on) .. "   melee swing armed: " .. tostring(melee_flag == true))
        changed, val = imgui.checkbox("Show the lowered weapon pointing down", S.show_lowered)
        if changed then S.show_lowered = val; save_settings() end
        changed, val = imgui.checkbox("Gun locked to your hand: hide the game's own recoil movement", S.gun_hold_still ~= false)
        if changed then S.gun_hold_still = val; save_settings() end
        changed, val = imgui.checkbox("Gun put back in the hand in both eye passes", S.gun_hold_both ~= false)
        if changed then S.gun_hold_both = val; save_settings() end
        changed, val = imgui.checkbox("Keep UEVR's own 'attach to controller' off the gun the mod holds", S.uevr_attach_guard ~= false)
        if changed then S.uevr_attach_guard = val; save_settings() end
        if V62.ua.logged then imgui.text(string.format("   UEVR attachment on %s: taken off every frame (moved the gun %d times)", tostring(V62.ua.cls), V62.ua.moved or 0)) end
        changed, val = imgui.checkbox("Move guns whose barrel sits below / beside the hand", S.gun_autofit)
        if changed then S.gun_autofit = val; save_settings() end
        changed, val = imgui.checkbox("Firing aims through the barrel's aiming point (off = old switch to the barrel direction)", S.fire_aim_pointer)
        if changed then S.fire_aim_pointer = val; save_settings() end
        changed, val = imgui.checkbox("VR recoil: the gun kicks in your hand + buzz on each shot", S.vr_recoil)
        if changed then S.vr_recoil = val; save_settings() end
        changed, val = imgui.checkbox("VR recoil: our own visual kick (off = buzz only)", S.recoil_visual == true)
        if changed then S.recoil_visual = val; save_settings() end
        changed, val = imgui.slider_float("VR recoil kick: muzzle tip (only with the visual kick on)", S.recoil_rise or 0.2, 0.0, 1.0)
        if changed then S.recoil_rise = val; save_settings() end
    end
    if V62.section("Sights (red dot)") then
        changed, val = imgui.checkbox("Red dot: set the sight's crosshair from the gun as drawn", S.sight_fix ~= false)
        if changed then S.sight_fix = val; save_settings() end
        changed, val = imgui.checkbox("Red dot: point it where the shot lands (barrel line hit), not parallel above it", S.sight_impact ~= false)
        if changed then S.sight_impact = val; save_settings() end
        changed, val = imgui.slider_float("Red dot trim (deg; + raises the dot = shots land lower)", S.sight_trim_deg or 0, -2.0, 2.0)
        if changed then S.sight_trim_deg = val; save_settings() end
    end
    if V62.section("HUD, aiming ring, pointer dot") then
        changed, val = imgui.checkbox("Helmet HUD in front of your eyes, following your head", S.hud_head ~= false)
        if changed then S.hud_head = val; save_settings() end
        changed, val = imgui.slider_float("Helmet HUD distance (m)", S.hud_head_dist or 1.6, 0.8, 4.0)
        if changed then S.hud_head_dist = val; save_settings() end
        changed, val = imgui.slider_float("Helmet HUD size (deg of your view)", S.hud_head_fov or 75, 30, 120)
        if changed then S.hud_head_fov = val; save_settings() end
        changed, val = imgui.slider_float("Helmet HUD height (deg; minus = lower)", S.hud_head_down or -8, -40, 20)
        if changed then S.hud_head_down = val; save_settings() end
        changed, val = imgui.slider_float("HUD width (degrees of your view)", S.hud_fov or 50, 20, 90)
        if changed then S.hud_fov = val; save_settings() end
        imgui.text(string.format("HUD on its panel: %s", tostring(wrist ~= nil)))
        changed, val = imgui.checkbox("Aiming ring on its own panel where your hand points", S.hud_ring_separate ~= false)
        if changed then S.hud_ring_separate = val; save_settings() end
        changed, val = imgui.checkbox("Helmet HUD: flip the aiming ring left/right (only if it could not be separated)", S.hud_ring_mirror == true)
        if changed then S.hud_ring_mirror = val; save_settings() end
        changed, val = imgui.checkbox("Pointer dot: the small dot where your hand points, always on", S.pointer_dot ~= false)
        if changed then S.pointer_dot = val; hudp.cross_off = nil; save_settings() end
        changed, val = imgui.checkbox("Dot / ring drawn solid: no ghost trail when it moves (off = see-through as before)", S.pointer_solid ~= false)
        if changed then
            S.pointer_solid = val; save_settings()
            if hudp.rcomp ~= nil and obj_ok(hudp.rcomp) then pcall(function() hudp.rcomp:SetBlendMode(val and 1 or 2) end) end
        end
        changed, val = imgui.slider_float("Pointer dot size", S.pointer_dot_size or 1.5, 0.5, 4.0)
        if changed then S.pointer_dot_size = val; save_settings() end
        changed, val = imgui.checkbox("...or only when the game shows its ADS crosshair (LT)", S.hud_ads_crosshair == true)
        if changed then S.hud_ads_crosshair = val; hudp.cross_off = nil; save_settings() end
        changed, val = imgui.checkbox("Hide the game's HUD while a level loads", S.hud_hide_loading ~= false)
        if changed then S.hud_hide_loading = val; save_settings() end
        changed, val = imgui.checkbox("Helmet light follows your head", S.head_light ~= false)
        if changed then S.head_light = val; save_settings() end
    end
    if V62.section("Menus and keyboard") then
        changed, val = imgui.checkbox("Menus follow your head (off = appear in front of you, then stay put)", S.menu_follow_head)
        if changed then S.menu_follow_head = val; save_settings() end
        changed, val = imgui.slider_float("Menu distance (m)", S.menu_distance, 0.8, 3.0)
        if changed then S.menu_distance = val; save_settings() end
        changed, val = imgui.slider_float("Menu size", S.menu_size, 0.5, 3.0)
        if changed then S.menu_size = val; save_settings() end
        changed, val = imgui.slider_float("Menu height (m, negative = lower)", S.menu_height, -1.0, 1.0)
        if changed then S.menu_height = val; save_settings() end
        changed, val = imgui.slider_float("Pointer tilt (deg)", S.pointer_pitch, -60, 60)
        if changed then S.pointer_pitch = val; save_settings() end
        imgui.text("Menu open: " .. tostring(menu_mode) .. "   pointer on menu: " .. tostring(pointer_inside) .. "   UI effect layers switched off: " .. tostring(fixed_count))
        changed, val = imgui.checkbox("Inventory and shop on the flat screen (off = VR panel like the other menus)", S.flat_inventory)
        if changed then S.flat_inventory = val; save_settings() end
        changed, val = imgui.checkbox("Bigger menu cursor copy (caused a double cursor; leave off)", S.big_cursor)
        if changed then S.big_cursor = val; save_settings() end
        changed, val = imgui.checkbox("SteamVR keyboard for terminals and text boxes (needs sf_kbd.dll)", S.kbd_auto)
        if changed then S.kbd_auto = val; save_settings() end
        changed, val = imgui.checkbox("Keyboard in front of you at chest height (off = SteamVR's own spot)", S.kbd_place)
        if changed then S.kbd_place = val; save_settings() end
        changed, val = imgui.slider_float("Keyboard: below your eyes (cm)", S.kbd_down or 55, 20, 90)
        if changed then S.kbd_down = val; save_settings(); V62.kbd_send(string.format("place %d %.0f %.0f %.0f", S.kbd_place and 1 or 0, S.kbd_fwd or 45, S.kbd_down, S.kbd_tilt or 50)) end
        changed, val = imgui.slider_float("Keyboard: distance in front (cm)", S.kbd_fwd or 45, 25, 90)
        if changed then S.kbd_fwd = val; save_settings(); V62.kbd_send(string.format("place %d %.0f %.0f %.0f", S.kbd_place and 1 or 0, S.kbd_fwd, S.kbd_down or 55, S.kbd_tilt or 50)) end
    end
    if V62.section("Walking, turning, sprint") then
        changed, val = imgui.checkbox("Snap turn (off = smooth)", S.snap_turn)
        if changed then S.snap_turn = val; save_settings() end
        changed, val = imgui.slider_float("Smooth turn speed (deg/s)", S.turn_speed, 30, 360)
        if changed then S.turn_speed = val; save_settings() end
        changed, val = imgui.slider_float("Snap turn angle", S.snap_angle, 10, 90)
        if changed then S.snap_angle = val; save_settings() end
        changed, val = imgui.checkbox("Walk through the game's own input (sprint works); off = direct walking", S.game_walk)
        if changed then S.game_walk = val; track.walk_direct = nil; if body then body.walk = nil end; save_settings() end
        imgui.text("Walking mode now: " .. tostring(body and (body.walk or ("game input, steering by " .. V62.wm.model)) or "-"))
        changed, val = imgui.checkbox("Sprint: the game's look follows your head while its forward key is held", S.sprint_head ~= false)
        if changed then S.sprint_head = val; save_settings() end
        changed, val = imgui.checkbox("Sprint: the game's CancelSprint when it keeps sprinting after you stop", S.sprint_cancel)
        if changed then S.sprint_cancel = val; save_settings() end
        changed, val = imgui.checkbox("Your body follows your head when you step or lean (room-scale)", S.roomscale == true)
        if changed then S.roomscale = val; save_settings() end
        imgui.text("   room-scale now: " .. (V62.rs_on and "ON - the game's body moves with the headset" or "off"))
    end
    if V62.section("Carrying and throwing") then
        changed, val = imgui.checkbox("Carrying: throw where your hand points (off = object near the hand, throws go right)", S.carry_far_aim)
        if changed then S.carry_far_aim = val; save_settings() end
        changed, val = imgui.checkbox("Harder yank = harder throw", S.throw_power)
        if changed then S.throw_power = val; save_settings() end
        changed, val = imgui.slider_float("Throw: strength per m/s of hand speed", S.throw_speed_k or 130, 50, 300)
        if changed then S.throw_speed_k = val; save_settings() end
        changed, val = imgui.slider_float("Throw: gentlest (cm/s)", S.throw_speed_min or 450, 100, 1000)
        if changed then S.throw_speed_min = val; save_settings() end
        changed, val = imgui.slider_float("Throw: hardest (cm/s)", S.throw_speed_max or 1500, 500, 3000)
        if changed then S.throw_speed_max = val; save_settings() end
    end
    if V62.section("View, height, level loads, sound") then
        changed, val = imgui.checkbox("Recentre + reset height on level load", S.auto_recenter)
        if changed then S.auto_recenter = val; save_settings() end
        if imgui.button("Recentre + reset height now") then guarded("recenter", reset_height, true) end
        changed, val = imgui.checkbox("Height reset: use my standing height if I am bent down at that moment", S.height_stand ~= false)
        if changed then S.height_stand = val; save_settings() end
        do
            local ref = V62.stand_ref()
            imgui.text(ref and string.format("   standing head height: %.2f m", ref) or "   standing head height: not known yet (needs 10 s in the headset)")
        end
        changed, val = imgui.checkbox("Hide the loading-screen box", S.hide_loading_box)
        if changed then S.hide_loading_box = val; save_settings() end
        changed, val = imgui.checkbox("Level transitions: fade to black (needs sf_kbd.dll v2)", S.transition_fade)
        if changed then S.transition_fade = val; save_settings() end
        changed, val = imgui.checkbox("Sleeping: fade to black while the game moves the camera to the bed", S.camera_away_fade)
        if changed then S.camera_away_fade = val; save_settings() end
        changed, val = imgui.checkbox("Audio: the game hears from your head - sounds follow the headset, not the gun", S.audio_head ~= false)
        if changed then S.audio_head = val; save_settings() end
    end
    if V62.section("Graphics") then
        imgui.text("Pick one - it is used at once and remembered. In the headset: left grip + View = the next one (1 to 4 buzzes).")
        for i, pr in ipairs(V62.GFX) do
            local on = (i == S.gfx_level)
            -- (the part after ### is the button's identity, so the label can change without the button "moving")
            if imgui.button((on and "> " or "   ") .. i .. "  " .. pr.name .. (on and "   (in use)" or "") .. "###sfgfx" .. i) then
                S.gfx_level = i; save_settings(); V62.gfx_queue(i, "(panel)")
            end
            imgui.text("        " .. pr.what)
        end
        imgui.text("The game's own graphics settings stay as they are; these presets sit on top of them.")
        if imgui.button(V62.pp and "Stop the performance probe" or "Run the performance probe (stand still ~1.5 min)") then
            if V62.pp then V62.probe_abort("panel") else V62.probe_start("panel") end
        end
    end
    if V62.section("Binoculars (parked - none of this works well yet)") then
        changed, val = imgui.checkbox("Binoculars: the game's binocular view in front of your eyes", S.binoculars_2d)
        if changed then S.binoculars_2d = val; save_settings() end
        changed, val = imgui.checkbox("Binoculars: live picture on the binoculars (off = binoculars as the game has them)", (S.binocular_mode or 1) == 1)
        if changed then S.binocular_mode = val and 1 or 0; V62.binoc.live_failed = nil; save_settings() end
        if imgui.button("Binocular picture: turn / flip it (" .. tostring(S.bino_orient or 0) .. ")") then
            S.bino_orient = ((S.bino_orient or 0) + 1) % 8; save_settings(); V62.bs.try_t = nil; V62.bino_destroy()
        end
        imgui.text("The game's scope they borrow: " .. ((S.bino_scope_class or "") ~= "" and (S.bino_scope_class:match("([%w_]+)$") or "?") or "(none seen yet - hold a scoped gun in mode 1)"))
        changed, val = imgui.checkbox("Binoculars: show the borrowed scope's lens", S.bino_lens ~= false)
        if changed then S.bino_lens = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.checkbox("Binoculars: show the flat picture too", S.bino_plane ~= false)
        if changed then S.bino_plane = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.checkbox("Binoculars: show the scope's body as well (not just the lens)", S.bino_scope_body == true)
        if changed then S.bino_scope_body = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.slider_float("Binoculars: lens position (cm, minus = toward your eye)", S.bino_scope_x or -17, -40, 20)
        if changed then S.bino_scope_x = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.slider_float("Binoculars: lens height (cm)", S.bino_scope_z or 6, -10, 25)
        if changed then S.bino_scope_z = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.slider_float("Binoculars: lens size (x)", S.bino_scope_scale or 2, 0.5, 6)
        if changed then S.bino_scope_scale = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.slider_float("Binoculars: flat picture position (cm)", S.bino_plane_x or -17.5, -40, 20)
        if changed then S.bino_plane_x = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.slider_float("Binoculars: flat picture height (cm)", S.bino_plane_z or 6, -10, 25)
        if changed then S.bino_plane_z = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.slider_float("Binoculars: flat picture size (cm)", S.bino_size or 11, 3, 40)
        if changed then S.bino_size = val; save_settings(); V62.bino_destroy() end
        changed, val = imgui.slider_float("Binoculars: zoom (0 = the game's own)", S.bino_zoom or 0, 0, 12)
        if changed then S.bino_zoom = val; save_settings(); V62.bs.was_want = nil end
    end
    if V62.section("Log") then
        imgui.text("Log: data\\sf_main_log.txt (in this game's UEVR profile folder)   Settings: data\\sf_settings.txt")
        changed, val = imgui.checkbox("Write every hint / prompt text the game shows to the log", S.hint_log ~= false)
        if changed then S.hint_log = val; save_settings() end
    end
end
-- v6.6.48: THE PANEL PEOPLE SEE. The playtest of 2026-11-10: "only include the settings that make sense ... trim them
-- down, only have the stuff that people need to touch ... graphics should be basically near the top". The page above
-- (draw_panel: every switch, written for development) is now only shown at the bottom of this one, and only when
-- dev_tools=true is written into sf_settings.txt. What is here: choices a player has a reason to make. What is not:
-- switches that only exist so a fix could be turned off again, and features that were tried and dropped.
-- v6.6.50: THE PAGE FITS ITS WINDOW. The fourth playtest: "it goes off the screen to the right ... it should wrap ... the
-- controls should read straight up and down, one by one ... gun angle in the hand, all g- and then it's off the screen".
-- UEVR's Lua has no wrapped text, but it can measure: imgui.calc_text_size and imgui.get_window_size. Every line is
-- broken at word ends to the width the page really has (V62.wraptext; by a character count if measuring fails). A slider's
-- name stands on the line above it (beside it, a third of the window is all a name gets). Switch labels are short, with
-- the explanation underneath.
V62.pg = { w = nil, n = 0, t = {} }
function V62.vx(v) if type(v) == "userdata" or type(v) == "table" then return X(v) end; return nil end   -- .x of a 2D size, or nil
function V62.page_begin()                                      -- once per drawn page: how wide may a line be?
    local w = safe(function()
        local a, b = V62.vx(imgui.get_window_size()), V62.vx(imgui.get_cursor_pos())
        if a == nil or b == nil then return nil end
        return a - b - 30                                      -- (the scroll bar and the right-hand margin)
    end)
    if type(w) ~= "number" or w ~= w or w < 150 or w > 8000 then w = nil else w = math.floor(w / 8) * 8 end
    if V62.pg.w ~= w or V62.pg.n > 500 then V62.pg = { w = w, n = 0, t = {} } end
end
function V62.fits(text, w, chars)
    if w ~= nil then
        local tw = safe(function() return V62.vx(imgui.calc_text_size(text)) end)
        if type(tw) == "number" and tw > 0 then return tw <= w end
    end
    return #text <= chars
end
function V62.wraptext(text, room, lead)                            -- text -> lines that fit (room = pixels taken beside it; lead = start of every further line)
    local pg = V62.pg
    room, lead = room or 0, lead or ""
    local key = room .. "|" .. lead .. "|" .. text
    local c = pg.t[key]
    if c ~= nil then return c end
    local w = pg.w and (pg.w - room) or nil
    local chars = 66 - math.floor(room / 7)
    local lines, line = {}, nil
    for word in text:gmatch("%S+") do
        if line == nil then line = (text:match("^%s*") or "") .. word
        elseif V62.fits(line .. " " .. word, w, chars) then line = line .. " " .. word
        else lines[#lines + 1] = line; line = lead .. word end
    end
    lines[#lines + 1] = line or ""
    pg.t[key] = lines; pg.n = pg.n + 1
    return lines
end
function V62.say(text, lead)                                   -- text on the page, wrapped
    for _, l in ipairs(V62.wraptext(text, 0, lead)) do imgui.text(l) end
end
function V62.row(label, key, after, help)                      -- one on/off switch, saved at once (help = a line under it)
    local lines = V62.wraptext(label, 34, "")
    local changed, val = imgui.checkbox(lines[1] .. "###sf_" .. key, S[key] == true)
    for i = 2, #lines do imgui.text("        " .. lines[i]) end
    if help ~= nil then V62.say("        " .. help, "        ") end
    if changed then S[key] = val; save_settings(); if after ~= nil then after(val) end end
end
function V62.num(title, key, lo, hi, after)                    -- one slider, its name on the line above, saved at once
    V62.say(title)
    local changed, val = imgui.slider_float("##sf_" .. key, S[key], lo, hi)
    if changed then S[key] = val; save_settings(); if after ~= nil then after(val) end end
end
-- The controls, one per line. @G = the gun hand's side, @O = the other hand's (they change places for a left-handed
-- player; everything without a mark stays where it is). Kept in step with README.md of the release.
V62.CTL = {
    { "@G trigger", "fire, use (in menus: click)" },
    { "@O trigger", "aim, second use" },
    { "A", "interact" },
    { "B", "reload (hold = change ammo type)" },
    { "X", "fire mode" },
    { "Y", "jump" },
    { "@G bumper", "tap = pick up, hold = lower / raise the weapon" },
    { "@O bumper", "weapon light / laser, pry, harvest" },
    { "Left stick", "walk (click = sprint)" },
    { "Right stick", "turn (click = crouch; in menus it scrolls)" },
    { "D-pad up", "flashlight" },
    { "D-pad down", "inventory" },
    { "D-pad left / right", "previous / next weapon" },
    { "View", "journal" },
    { "Menu", "pause" },
    { "@G grip + Y", "crouch-jump" },
    { "@O grip on a long gun", "two-handed - steadies and steers it" },
    { "@O trigger while that hand holds the flashlight", "switch between its two holds" },
    { "Left grip, squeezed fully, + D-pad", "utility slots 5 (up), 6 (right), 7 (down), 8 (left)" },
    { "Left grip, squeezed fully, + View", "next graphics preset" },
    { "Left grip (squeezed fully) or left stick click, in menus", "your click becomes a shift-click" },
    { "Both stick clicks, held for a second", "UEVR's menu" },
}
function V62.controls()
    local lh = S.left_handed == true
    local g, o = lh and "Left" or "Right", lh and "Right" or "Left"
    for _, c in ipairs(V62.CTL) do
        local name = c[1]:gsub("@G", g):gsub("@O", o)
        V62.say(name .. ": " .. c[2], "        ")
    end
end
function V62.panel()
    V62.page_begin()
    V62.say("Project Silverfish VR " .. SF_RELEASE .. " by Blind  (build " .. SF_VERSION .. ")")
    local nerr = 0
    for _, n in pairs(errors) do nerr = nerr + n end
    if nerr > 0 then V62.say("Something went wrong " .. nerr .. " times this session - details in data\\sf_main_log.txt") end
    V62.say("Click a heading to open it. Every change is saved at once.")
    if V62.section("Graphics") then
        V62.say("Pick one. It is used at once and remembered. In the headset: left grip, squeezed fully, + View steps to the next one, and the buzzes count its number.")
        for i, pr in ipairs(V62.GFX) do
            local on = (i == S.gfx_level)
            if imgui.button((on and "> " or "   ") .. i .. "  " .. pr.name .. (on and "   (in use)" or "") .. "###sfgfxp" .. i) then
                S.gfx_level = i; save_settings(); V62.gfx_queue(i, "(panel)")
            end
            V62.say("        " .. pr.what, "        ")
        end
        V62.say("These sit on top of the game's own graphics settings, which stay as you set them.")
    end
    if V62.section("Controls (Steam Frame)") then
        V62.row("Left-handed: gun and both pointers in your LEFT hand", "left_handed", function() V62.hand_sync(true) end,
            "Experimental. Triggers, bumpers and grips change hands; the sticks, A B X Y, the D-pad, View and Menu stay where they are. The list below always shows the layout in use.")
        if S.left_handed == true then
            V62.say("        Trigger swap: " .. (V62.hand_ok and "on" or "NOT ACTIVE - plugins\\a_sf_hand.dll did not answer, so the right trigger still fires"), "        ")
        end
        V62.controls()
        V62.row("D-pad left / right: weapons only", "weapons_only_dpad", nil, "Skips the utility items when you step through your weapons.")
        V62.row("Two-handed: the other hand steadies a long gun", "two_handed", nil, "Hold its fore-grip or barrel and that hand steers it too.")
        V62.row("Two-handed only while that hand's grip is held", "twohand_hold")
        V62.row("Two-handed: the pointer dot follows your gun hand", "twohand_hand_pointer", nil, "And so does what you pick up. Off = both follow the barrel. Shots always follow the barrel.")
        V62.row("Buzz in the gun hand on every shot", "vr_recoil")
        V62.row("Three ticks when you fire while the gun is blocked", "blocked_buzz", nil, "The game blocks a gun that is too close to a wall.")
        V62.row("Off-hand flashlight starts in the raised hold", "fl_start_raised", nil, "For a hand held up by your head. Off = it starts as a torch, beam where the hand points.")
    end
    if V62.section("Walking and turning") then
        V62.row("Snap turn (off = smooth turn)", "snap_turn")
        V62.num("Smooth turn speed (degrees per second)", "turn_speed", 30, 360)
        V62.num("Snap turn angle (degrees)", "snap_angle", 10, 90)
        V62.row("Room-scale: your body follows your head", "roomscale", nil, "Step or lean in your room and the game's body moves with you.")
        if imgui.button("Recentre and reset my height now") then guarded("recenter", reset_height, true) end
        V62.row("Recentre and reset my height at every level load", "auto_recenter")
    end
    if V62.section("Gun in the hand") then
        -- v6.6.50: locked until asked for (the fourth playtest: "I'm scrolling, I don't know what I'm changing here ...
        -- I don't want that to stay"). The lock is not saved: it is back on at every start.
        V62.say("How every gun sits in your hand, and where red dot sights point. Leave these alone unless guns point too high or too low for the way you hold the controller.")
        V62.say(string.format("Now: gun angle %.1f degrees, red dot trim %.2f degrees.", S.grip_angle or 0, S.sight_trim_deg or 0))
        local ch, on = imgui.checkbox("Unlock these settings###sf_gun_unlock", V62.gun_unlock == true)
        if ch then V62.gun_unlock = on end
        if V62.gun_unlock == true then
            V62.num("Gun angle in the hand, all guns (degrees; minus tips the barrel down)", "grip_angle", -80, 40)
            V62.num("Red dot sights: trim (degrees; plus raises the dot, so shots land lower)", "sight_trim_deg", -2.0, 2.0)
            if imgui.button("Put these two back to the mod's own values###sf_gun_def") then
                S.grip_angle, S.sight_trim_deg = -55.0, 0.0; save_settings()
            end
            if cur ~= nil and GUNS[cur.cls] ~= nil then
                local g = GUNS[cur.cls]
                V62.say("In your hand now: " .. tostring(cur.dn or cur.cls) .. ". The next two rows move this one gun only.")
                local any, changed, val = false, nil, nil
                V62.say("Its place in the hand (cm)")
                changed, val = imgui.drag_float3("##sf_gun_pos", Vector3f.new(g.x, g.y, g.z), 0.2, -100, 100)
                if changed then g.x, g.y, g.z = X(val), Y(val), Z(val); any = true end
                V62.say("Its angle (degrees: pitch, yaw, roll)")
                changed, val = imgui.drag_float3("##sf_gun_ang", Vector3f.new(g.pitch, g.yaw, g.roll), 0.5, -180, 180)
                if changed then g.pitch, g.yaw, g.roll = X(val), Y(val), Z(val); any = true end
                if any and fit == nil then guarded("gun", apply_gun); save_settings() end
                if imgui.button("Forget my changes to this gun###sf_gun_reset") then
                    local a, c = cur.actor, cur.cls
                    GUNS[c] = nil
                    guarded("gun", release_gun); save_settings()
                    if hold ~= nil then guarded("gun", take_gun, a, c) end
                end
                V62.say("That button puts this one gun back the way the mod holds it by itself.")
            else
                V62.say("Take a gun in your hand to adjust how that one gun sits.")
            end
        end
    end
    if V62.section("HUD and pointer dot") then
        V62.num("Helmet HUD: distance (metres)", "hud_head_dist", 0.8, 4.0)
        V62.num("Helmet HUD: size (degrees of your view)", "hud_head_fov", 30, 120)
        V62.num("Helmet HUD: height (degrees; minus = lower)", "hud_head_down", -40, 20)
        V62.row("Pointer dot where your gun hand points, always on", "pointer_dot", function() hudp.cross_off = nil end)
        V62.num("Pointer dot size", "pointer_dot_size", 0.5, 4.0)
    end
    if V62.section("Menus and keyboard") then
        V62.num("Menu distance (metres)", "menu_distance", 0.8, 3.0)
        V62.num("Menu size", "menu_size", 0.5, 3.0)
        V62.num("Menu height (metres; minus = lower)", "menu_height", -1.0, 1.0)
        V62.num("Menu pointer tilt (degrees)", "pointer_pitch", -60, 60)
        V62.row("On-screen keyboard for terminals and text boxes", "kbd_auto")
        V62.row("Keyboard in front of you at chest height", "kbd_place", nil, "Off = where SteamVR puts it.")
        local function kbd() V62.kbd_send(string.format("place %d %.0f %.0f %.0f", S.kbd_place and 1 or 0, S.kbd_fwd or 61, S.kbd_down or 75, S.kbd_tilt or 50)) end
        V62.num("Keyboard: how far below your eyes (cm)", "kbd_down", 20, 90, kbd)
        V62.num("Keyboard: how far in front of you (cm)", "kbd_fwd", 25, 90, kbd)
    end
    if V62.section("Carrying and throwing") then
        V62.row("A carried object goes where your hand points", "carry_far_aim", nil, "So a throw goes there too. Off = it floats near the hand.")
        V62.row("A harder swing of the hand throws harder", "throw_power")
        V62.num("Throw strength per m/s of hand speed", "throw_speed_k", 50, 300)
        V62.num("Gentlest throw (cm/s)", "throw_speed_min", 100, 1000)
        V62.num("Hardest throw (cm/s)", "throw_speed_max", 500, 3000)
    end
    if V62.section("Optional extras") then
        V62.say("Off unless you tick them.")
        V62.row("Trading: Add Money sets the amount for you", "trade_money", nil, "Click Add Money and hold your hand still: the pointer runs the game's money slider to the least the trader takes and stops with a buzz. Click again to take it. To set the amount yourself, move your hand well away once it has stopped.")
        V62.row("Trading: stop at the trader's second mark instead", "trade_money_ideal", nil, "The higher of the two marks on the balance bar. Only matters while the switch above is on.")
    end
    if V62.section("Help") then
        V62.say("Not working in VR yet: the binoculars, and the photo camera's viewfinder (photos themselves work).")
        V62.say("Crouch-jump lower than you expect? The game lets you jump less high when you are hungry.")
        V62.say("Settings file: data\\sf_settings.txt in this game's UEVR profile folder. Delete it to get every default back.")
        V62.say("Reporting a bug: send data\\sf_main_log.txt and UEVR's log.txt from that folder. Both are written fresh at every start, so copy them before you start the game again.")
    end
    if S.dev_tools == true and V62.section("Development: every switch") then draw_panel() end
end
-- v6.6.47: the settings get their own page in UEVR's menu - "Silverfish VR settings" in the list on the left - instead
-- of sitting under UEVR's "Script UI" (the tester, for the release: "it should be called ... VR settings or something, so
-- that when someone opens this they know"). uevr.lua.add_script_panel(name, fn) is in UEVR's LuaLoader (checked in the
-- source of the build in use, 4ee5c6b); on a UEVR without it, or if it refuses, everything stays under Script UI.
-- Script UI keeps a pointer to the page and a fold-out that shows the settings there as well.
local PANEL_NAME = "Silverfish VR settings"
V62.own_page = false
if type(uevr.lua) == "table" and uevr.lua.add_script_panel ~= nil then
    V62.own_page = pcall(uevr.lua.add_script_panel, PANEL_NAME, function() guarded("panel", V62.panel) end) == true
end
LOG(V62.own_page and ("settings page: \"" .. PANEL_NAME .. "\" in UEVR's menu (the list on the left)")
    or "settings page: under UEVR's Script UI (this UEVR has no pages for scripts)")
uevr.sdk.callbacks.on_draw_ui(function()
    if V62.own_page then
        guarded("panel", function()
            V62.page_begin()
            V62.say("Project Silverfish VR - the settings have their own page: \"" .. PANEL_NAME .. "\", in the list on the left.")
        end)
        if not V62.section("Show them here as well") then return end
    end
    guarded("panel", V62.panel)
end)
pcall(function() uevr.sdk.callbacks.on_lua_event(function(n, d)   -- v6.6.10 / v6.6.11
    if n == "sfinv" then V62.inv_raw = d elseif n == "sfperf" then V62.perf_raw = d elseif n == "sfmat" then V62.mat_raw = d   -- v6.6.37
    elseif n == "sfhand" then V62.hand_raw = d                                                                                 -- v6.6.49
    elseif n == "sftxt" then V62.txt_raw = d                                                                                   -- v6.6.43
    elseif n == "sfkbd" then V62.kbd_q = V62.kbd_q or {}; V62.kbd_q[#V62.kbd_q + 1] = d end   -- v6.6.13
end) end)

---------------------------------------------------------------------------
-- main loop
---------------------------------------------------------------------------
LOG("Project Silverfish VR " .. SF_RELEASE .. " by Blind - sf_main build " .. SF_VERSION .. " loaded")
local flush_acc, started, ui_t = 0, false, 0
local ui_menu, ui_t2 = nil, nil
-- v4.21 HITCH DETECTOR. A VR frame should be ~7-22 ms. A much longer frame is a stutter; a very long one is the
-- stall that trips UEVR's reset watchdog (which is what precedes the crashes). "delta" is how long the LAST frame
-- took, so a big value here means the previous frame stalled. Logging only the spikes costs almost nothing and
-- tells us next time exactly when frames froze and what was running - measured, not guessed.
local hitch = { count = 0, worst = 0, logged = 0, next_summary = 30 }
V62.reg("on_pre_engine_tick", function(engine, delta)
    T = T + delta
    V62.fno = (V62.fno or 0) + 1                                -- v6.6.45: frame number (which eye passes belong together)
    if T > 8 and delta > 0.08 then
        hitch.count = hitch.count + 1
        if delta > hitch.worst then hitch.worst = delta end
        if hitch.logged < 60 or delta > 0.30 then
            hitch.logged = hitch.logged + 1
            LOG(string.format("HITCH: last frame took %d ms (T=%.1f, menu=%s, last feature=%s)",
                math.floor(delta * 1000), T, tostring(menu_mode), last_feature))
        end
    end
    if T >= hitch.next_summary then
        hitch.next_summary = hitch.next_summary + 30
        if hitch.count > 0 then LOG(string.format("hitch summary: %d stutters over %d ms threshold so far, worst %d ms", hitch.count, 80, math.floor(hitch.worst * 1000))) end
        if (ctrl_jump.all or 0) > (ctrl_jump.all_logged or 0) then           -- v6.6.14
            LOG(string.format("control yaw jumps over 20 deg in one frame: %d in the last 30 s (%d total)", ctrl_jump.all - (ctrl_jump.all_logged or 0), ctrl_jump.all))
            ctrl_jump.all_logged = ctrl_jump.all
        end
    end
    pad.age = (pad.age or 0) + delta
    -- v6.5: frame times per graphics preset (only in play: no menu, level ready) - the GPU budget at 90 Hz is 11.1 ms
    local ft = V62.ft
    if ft ~= nil then ft.all = (ft.all or 0) + 1 end
    if V62.pp ~= nil then V62.ft = nil                         -- v6.6.21: the probe owns sf_perf's window
    elseif ft == nil or ft.p ~= S.gfx_level then
        pcall(function() api:dispatch_custom_event("sfperf", "report") end)   -- v6.6.11: start sf_perf's window too
        V62.ft = { p = S.gfx_level, t0 = T + 3, n = 0, sum = 0, over = 0, worst = 0, s0 = SF_SCRIPT_T or 0, all = 0 }
    elseif T > ft.t0 and not menu_mode and lvl ~= nil and lvl.ready and delta < 0.5 then
        ft.n, ft.sum = ft.n + 1, ft.sum + delta
        if delta > 0.0125 then ft.over = ft.over + 1 end
        if delta > ft.worst then ft.worst = delta end
        if ft.n >= 1800 then
            local pr = V62.GFX and V62.GFX[ft.p or 2]
            local st = "n/a"
            if SF_SCRIPT_T ~= nil and ft.s0 ~= nil and (ft.all or 0) > 0 then st = string.format("%.2f ms", (SF_SCRIPT_T - ft.s0) * 1000 / ft.all) end
            LOG(string.format("frame times, graphics %s (%s): %.1f fps average, %.1f%% of frames missed 90 Hz, worst %d ms | this script: %s per frame",
                tostring(ft.p), pr and pr.name or "?", ft.n / ft.sum, 100 * ft.over / ft.n, math.floor(ft.worst * 1000), st))
            V62.perf_raw = nil                                   -- v6.6.11: where the time goes (sf_perf.dll)
            pcall(function() api:dispatch_custom_event("sfperf", "report") end)
            local pf = V62.perf_raw
            if pf ~= nil then
                local function g(k) return pf:match(k .. "=([^;]+)") or "?" end
                LOG(string.format("   where the time goes: game engine tick %s ms/frame | CPU busy: game thread %s%%, render thread %s%%, busiest others %s%% | GPU 3D busy: this game %s%%, whole PC %s%% (others: %s) | %s fps over %s s",
                    g("tick_ms"), g("game_cpu"), g("present_cpu"), g("other_cpu"), g("gpu_game"), g("gpu_all"), g("gpu_top"), g("fps"), g("secs")))
            elseif not V62.perf_nolog then V62.perf_nolog = true; LOG("   (no answer from sf_perf.dll)") end
            V62.ft = { p = S.gfx_level, t0 = T, n = 0, sum = 0, over = 0, worst = 0, s0 = SF_SCRIPT_T or 0, all = 0 }
        end
    end
    local mc = V62.mc
    if mc ~= nil then
        if delta > 0.02 then mc.n = mc.n + 1; mc.feats[#mc.feats + 1] = string.format("%dms@%.1fs(%s)", math.floor(delta * 1000), T - mc.t, tostring(last_feature)) end
        if delta > mc.max then mc.max = delta end
        if T - mc.t > 4 then
            V62.mc = nil
            V62.mcn = (V62.mcn or 0) + 1
            if V62.mcn <= 12 then
                LOG(string.format("%s: worst frame %d ms, %d frames over 20 ms %s", mc.what or "after a menu closed", math.floor(mc.max * 1000), mc.n,
                    (#mc.feats > 0) and ("[" .. table.concat(mc.feats, " ", 1, math.min(#mc.feats, 8)) .. "]") or ""))
            end
        end
    end
    if T > 6 then
        local ok, r = pcall(read_sticks_from_uevr)
        if not (ok and r) and pad.age < 0.5 then pad.lx, pad.ly, pad.rx, pad.ry = pad.xlx, pad.xly, pad.xrx, pad.xry end
    end
    if pad.age > 4 and not pad.lost then
        pad.lost = true
        LOG("WARNING: the game has not read the controller for 4 s (buttons/sticks do nothing)")
    end
    guarded("hand", V62.hand_sync)                              -- v6.6.49 (does nothing for a right-handed player)
    if V62.aim_kick ~= nil and T > V62.aim_kick then            -- v6.6.50: the start-up second is over (see remember_ui)
        V62.aim_kick = nil
        if S.vr_body then setmod("VR_AimMethod", "0") end
        LOG("UEVR aim method after the start-up second: " .. getmod("VR_AimMethod"))
    end
    flush_acc = flush_acc + delta
    if flush_acc > 2 then flush_acc = 0; flushlog() end
    if T < 6 then return end
    if not started then
        guarded("startup", function()
            if ORIG == nil then remember_ui() end
            lookups()
        end)
        started = G.ready and ORIG ~= nil
        if not started then return end
    end
    guarded("standh", V62.stand_sample)                         -- v6.6.43
    guarded("recenter", update_recenter, delta)
    guarded("menus", update_menus)
    if menu_mode then guarded("menu_scroll", V62.menu_scroll, (pad.ry or 0) / 32767, delta) end   -- v6.3
    -- v4.10: scanning all UI objects is costly (a hitch each time) - do it right after a menu opens/closes, else every 6 s
    ui_t = (ui_t or 0) + delta
    if menu_mode ~= ui_menu or ui_rescan then
        ui_menu = menu_mode; ui_rescan = false; ui_t = 0; ui_t2 = { 1.5, 4.0 }   -- v6.6: as in v6.4.1 (open AND close)
    end
    local due = ui_t > 20.0
    if ui_t2 ~= nil and ui_t2[1] ~= nil and ui_t >= ui_t2[1] then table.remove(ui_t2, 1); due = true end
    if due then
        if ui_t > 20.0 then ui_t = 0 end
        guarded("ui_effects", V62.timed, "UI effect scan", fix_ui_effects)
    end
    guarded("world", update_world, delta)
    if V62.hh ~= nil then guarded("hudhide", V62.hud_hide_tick) end              -- v6.6.43
    if V62.hq ~= nil and #V62.hq > 0 then guarded("hints", V62.hint_poll) end    -- v6.6.43
    if V62.bq ~= nil then guarded("barter", V62.barter_watch) end                 -- v6.6.45 / v6.6.48
    guarded("roomscale", V62.roomscale_update)                                   -- v6.6.45
    pcall(vguard_rebase)                        -- v5.5: see vguard_rebase
    TRACE("idle")
end)

-- v6.1: what did the game do with our Move input this tick? (world direction of its movement input)
-- v6.2: learn which direction the game steers by (control rotation or body) and a constant offset - slowly, from
-- frames where the pointer isn't steeply up/down - and log how far the real direction was from the wanted one
function V62.walk_learn(b, inj, basis, gy)
    local M = V62.wm
    if T - (V62.wfwd or -10) < 0.3 then return end      -- v6.3: the game's own W is held for a sprint - not a clean sample
    local function wrap(d) return (d + 540) % 360 - 180 end
    local oc, oa = wrap(basis - inj.cy), wrap(basis - inj.ay)
    M.n = M.n + 1
    if M.n == 1 then
        LOG(string.format("walking through the game's Move input works (offset from control rotation %.0f, from body %.0f deg)", oc, oa))
    end
    if math.abs(inj.cp or 0) < 50 then
        local k = M.n < 30 and 0.2 or 0.03
        M.off.control = M.off.control + wrap(oc - M.off.control) * k
        M.off.actor = M.off.actor + wrap(oa - M.off.actor) * k
        M.dev.control = M.dev.control * 0.98 + wrap(oc - M.off.control) ^ 2 * 0.02
        M.dev.actor = M.dev.actor * 0.98 + wrap(oa - M.off.actor) ^ 2 * 0.02
    end
    if M.n >= 90 then
        local pick = (M.dev.actor < M.dev.control * 0.5) and "actor" or ((M.dev.control < M.dev.actor * 0.5) and "control" or M.model)
        if pick ~= M.model then M.model = pick; LOG("walking: the game steers by the " .. (pick == "actor" and "body" or "control rotation") .. " - switched") end
    end
    local err = math.abs(wrap(gy - inj.want))
    M.es, M.ec = M.es + err, M.ec + 1
    if err > 30 then M.big = M.big + 1 end
    if math.abs(inj.cp or 0) >= 50 then M.steep, M.steep_err = M.steep + 1, M.steep_err + err end
    if M.ec >= 300 and T - M.rep_t > 60 then
        M.rep_t = T
        LOG(string.format("walking check: average direction error %.1f deg over %d frames, %d frames off by >30 deg; pointer steep %d frames (avg err %.1f); steering by %s, offset %.1f, spread control %.0f body %.0f",
            M.es / M.ec, M.ec, M.big, M.steep, M.steep > 0 and M.steep_err / M.steep or 0, M.model, M.off[M.model], math.sqrt(M.dev.control), math.sqrt(M.dev.actor)))
        M.es, M.ec, M.big, M.steep, M.steep_err = 0, 0, 0, 0, 0
    end
end
local function walk_measure()
    local b = body
    if b == nil or b.inj == nil or b.walk == "direct" or (T - b.inj.t) > 0.05 then return end
    local inj_now = b.inj
    b.inj = nil
    local v = safe(function() return b.pawn:GetLastMovementInputVector() end)
    local vx, vy = v and (v.X or v.x) or 0, v and (v.Y or v.y) or 0
    local len = math.sqrt(vx * vx + vy * vy)
    if len < 0.05 then
        b.walk_none = (b.walk_none or 0) + 1
        if b.walk_none > 45 and not b.walk_seen then
            b.walk, track.walk_direct = "direct", true
            LOG("walking: the game ignored its Move input for 45 frames - switched to direct walking (sprint may not work)")
        end
        return
    end
    b.walk_seen = true
    local gy = math.deg(math.atan(vy, vx))
    local basis = gy - math.deg(math.atan(inj_now.x, inj_now.y))
    b.gbasis = basis
    if inj_now.cy ~= nil then V62.walk_learn(b, inj_now, basis, gy) end
end
V62.reg("on_post_engine_tick", function(engine, delta)
    if started and lvl.free then guarded("walk_measure", walk_measure) end
    -- v6.0: never while a level is loading (the old gun / off-hand item may be mid-teardown)
    if started and T >= quiet_until and lvl.ready then
        guarded("gun_enforce", enforce_gun); guarded("recoil", V62.recoil_apply); guarded("gunstill", V62.gun_still_log)
        guarded("binoflags", V62.bino_flags); guarded("offhand_enforce", enforce_offhand)
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    pcall(function() api:dispatch_custom_event("sfkbd", "fade 0.3 0") end)   -- v6.6.14: never leave the view black
    pcall(V62.audio_off)                                                     -- v6.6.18: the game's own listener again
    pcall(V62.probe_restore)                                                 -- v6.6.21
    pcall(V62.bino_destroy)                                                  -- v6.6.25
    if V62.binoc_on then
        if V62.binoc.mode == "live" then pcall(V62.bino_live_off) else setmod("VR_2DScreenMode", "false") end
    end
    pcall(V62.hud_unhide, "script reset")                                   -- v6.6.43
    if V62.rs_on then V62.rs_on = false; setmod("VR_RoomscaleMovement", "false") end   -- v6.6.45
    pcall(remove_wrist, "script reset")
    pcall(release_body)
    if ORIG ~= nil and ORIG.aim ~= nil and ORIG.aim ~= "" then pcall(vr.set_mod_value, "VR_AimMethod", ORIG.aim) end
    pcall(release_gun)
    pcall(function() if light ~= nil then undrive(light, "flashlight") end end)
    pcall(set_menu_mode, false)
    flushlog()
end)

end -- sf_main_body

local ok, err = pcall(sf_main_body)
if not ok then
    pcall(fs.write, "sf_main_log.txt", "LOAD ERROR: " .. tostring(err))
    uevr.sdk.callbacks.on_draw_ui(function()
        imgui.text("Project Silverfish VR failed to load:")
        imgui.text(tostring(err))
    end)
end
