#define  _CRT_SECURE_NO_WARNINGS 1
#define  _SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING 1
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <memory>
#include <chrono>
#include <string>
#include <iostream>
#include <fstream>
#include <locale>
#include <codecvt>
#include <cctype>
#include <filesystem>
#include <utility>

#include "uevr/Plugin.hpp"
#include "main.h"

DWORD WINAPI TimerCallbackThreadProc(LPVOID lpParameter);
// v6: our own "keep-alive" reads of the controller (see keepalive_pump) must not look like the game reading it
static thread_local bool t_SelfPump = false;
typedef DWORD (WINAPI *PFN_XInputGetState_t)(DWORD, XINPUT_STATE*);
/*
OpenXR Action Paths 
    static const inline std::string s_action_pose = "/actions/default/in/Pose";
    static const inline std::string s_action_grip_pose = "/actions/default/in/GripPose";
    static const inline std::string s_action_trigger = "/actions/default/in/Trigger";
    static const inline std::string s_action_grip = "/actions/default/in/Grip";
    static const inline std::string s_action_joystick = "/actions/default/in/Joystick";
    static const inline std::string s_action_joystick_click = "/actions/default/in/JoystickClick";

    static const inline std::string s_action_a_button_left = "/actions/default/in/AButtonLeft";
    static const inline std::string s_action_b_button_left = "/actions/default/in/BButtonLeft";
    static const inline std::string s_action_a_button_touch_left = "/actions/default/in/AButtonTouchLeft";
    static const inline std::string s_action_b_button_touch_left = "/actions/default/in/BButtonTouchLeft";

    static const inline std::string s_action_a_button_right = "/actions/default/in/AButtonRight";
    static const inline std::string s_action_b_button_right = "/actions/default/in/BButtonRight";
    static const inline std::string s_action_a_button_touch_right = "/actions/default/in/AButtonTouchRight";
    static const inline std::string s_action_b_button_touch_right = "/actions/default/in/BButtonTouchRight";

    static const inline std::string s_action_dpad_up = "/actions/default/in/DPad_Up";
    static const inline std::string s_action_dpad_right = "/actions/default/in/DPad_Right";
    static const inline std::string s_action_dpad_down = "/actions/default/in/DPad_Down";
    static const inline std::string s_action_dpad_left = "/actions/default/in/DPad_Left";
    static const inline std::string s_action_system_button = "/actions/default/in/SystemButton";
    static const inline std::string s_action_thumbrest_touch_left = "/actions/default/in/ThumbrestTouchLeft";
    static const inline std::string s_action_thumbrest_touch_right = "/actions/default/in/ThumbrestTouchRight";

*/


#define CONTROLLER_SOURCE_THREAD    0xFFFFFFFF
#define XINPUT_POLL_TIME 			17

void DebugPrint(char* Format, ...);
using namespace uevr;

#define PLUGIN_LOG_ONCE(...) \
    static bool _logged_ = false; \
    if (!_logged_) { \
        _logged_ = true; \
        API::get()->log_info(__VA_ARGS__); \
    }
    
	
class JoyToKey : public uevr::Plugin {
public:
    KEY_ITEM m_Keys[TOTAL_BUTTONS];
    std::string m_Path;
    const UEVR_PluginInitializeParam* m_Param;
    const UEVR_VRData* m_VR;
	bool m_XinputPumpRunning;
	// Silverfish VR fork (2026-09-26): the game's own controller reads stop after one call, which used to switch
	// this plugin's VR input off forever. Now VR input only pauses while the game really keeps reading (<500 ms ago).
	volatile ULONGLONG m_LastNaturalTick = 0;
	bool m_LoggedNatural = false;
	bool m_VrActive = false;
	bool m_BothSticksWasDown = false;
	bool m_ExtraDebug = false;
	// v3 (2026-09-26): every VR button press is delivered to the GAME window. Windows sends key presses to whatever
	// window has focus and mouse clicks to whatever window is under the cursor - after the SteamVR dashboard / desktop
	// view was used, clicks (fire, menu select) landed in other windows while keys still reached the game.
	HWND m_GameWnd = NULL;
	int m_FocusFixes = 0;
	int m_CursorFixes = 0;
	ULONGLONG m_WheelNext = 0;
	PFN_XInputGetState_t m_PumpFn = NULL;
	bool m_PumpTried = false;
	bool m_PumpWorking = false;
	ULONGLONG m_PumpNext = 0;
	unsigned m_PumpCount = 0;
	unsigned m_SelfSeen = 0;          // v7: keep-alive reads that came back through UEVR's hook
	bool m_PumpReported = false;
	// v7 melee swing
	std::string m_MeleeFile;
	bool m_MeleeArmed = false;
	ULONGLONG m_MeleeCheck = 0;
	float m_SwPos[8][3] = {};
	ULONGLONG m_SwTick[8] = {};
	int m_SwHead = 0;
	int m_SwCount = 0;
	ULONGLONG m_SwingCooldown = 0;
	ULONGLONG m_SwingUpAt = 0;
	unsigned m_Swings = 0;
	ULONGLONG m_MenuCheckTick = 0;
	ULONGLONG m_MenuOpenSince = 0;
	bool m_MenuOpen = false;
	bool m_WheelLogged = false;

	static BOOL CALLBACK FindGameWndProc(HWND h, LPARAM lp) {
		DWORD pid = 0;
		GetWindowThreadProcessId(h, &pid);
		if(pid != GetCurrentProcessId() || !IsWindowVisible(h)) return TRUE;
		RECT rc; if(!GetWindowRect(h, &rc)) return TRUE;
		LONG area = (rc.right - rc.left) * (rc.bottom - rc.top);
		char cls[64] = {0}; GetClassNameA(h, cls, sizeof(cls));
		if(strcmp(cls, "UnrealWindow") == 0) area += 100000000;   // prefer the engine's own window
		auto best = (std::pair<HWND, LONG>*)lp;
		if(area > best->second) { best->first = h; best->second = area; }
		return TRUE;
	}

	HWND game_window() {
		if(m_GameWnd != NULL && IsWindow(m_GameWnd) && IsWindowVisible(m_GameWnd)) return m_GameWnd;
		std::pair<HWND, LONG> best(NULL, 0);
		EnumWindows(FindGameWndProc, (LPARAM)&best);
		m_GameWnd = best.first;
		return m_GameWnd;
	}

	static void describe(HWND h, char* out, size_t n) {
		char cls[64] = {0}, title[96] = {0};
		DWORD pid = 0;
		if(h) { GetClassNameA(h, cls, sizeof(cls)); GetWindowTextA(h, title, sizeof(title)); GetWindowThreadProcessId(h, &pid); }
		snprintf(out, n, "%s '%s' pid %lu", cls, title, (unsigned long)pid);
	}

	void make_game_foreground() {
		HWND g = game_window();
		if(g == NULL) return;
		HWND fg = GetForegroundWindow();
		if(fg == g) return;
		DWORD fgpid = 0;
		DWORD fgThread = fg ? GetWindowThreadProcessId(fg, &fgpid) : 0;
		if(fgpid == GetCurrentProcessId()) return;              // one of the game's own windows (e.g. UEVR) - fine
		char was[200]; describe(fg, was, sizeof(was));
		DWORD me = GetCurrentThreadId();
		if(IsIconic(g)) ShowWindow(g, SW_RESTORE);
		BOOL att = (fgThread != 0 && fgThread != me) ? AttachThreadInput(me, fgThread, TRUE) : FALSE;
		BringWindowToTop(g);
		SetForegroundWindow(g);
		if(att) AttachThreadInput(me, fgThread, FALSE);
		if(GetForegroundWindow() != g) {
			INPUT alt[2] = {};
			alt[0].type = INPUT_KEYBOARD; alt[0].ki.wVk = VK_MENU;
			alt[1] = alt[0]; alt[1].ki.dwFlags = KEYEVENTF_KEYUP;
			SendInput(2, alt, sizeof(INPUT));
			SetForegroundWindow(g);
		}
		Sleep(20);
		m_FocusFixes++;
		if(m_FocusFixes <= 20)
			API::get()->log_info("JoytoKey.dll (Silverfish fork): VR button pressed while another window had focus (%s) - focus given back to the game (ok=%d, fix #%d)",
				was, GetForegroundWindow() == g ? 1 : 0, m_FocusFixes);
	}

	// true = delivered straight to the game window (cursor was over something else)
	bool post_mouse_to_game(WORD key, bool key_up) {
		HWND g = game_window();
		if(g == NULL) return false;
		POINT pt;
		if(!GetCursorPos(&pt)) return false;
		HWND under = WindowFromPoint(pt);
		HWND root = under ? GetAncestor(under, GA_ROOT) : NULL;
		if(root == g) return false;                      // normal case: the real click lands on the game
		DWORD upid = 0;
		if(root) GetWindowThreadProcessId(root, &upid);
		if(root != NULL && upid == GetCurrentProcessId()) return false;
		UINT msg = 0; WPARAM wp = 0;
		if(key == VK_LBUTTON)      { msg = key_up ? WM_LBUTTONUP : WM_LBUTTONDOWN; wp = key_up ? 0 : MK_LBUTTON; }
		else if(key == VK_RBUTTON) { msg = key_up ? WM_RBUTTONUP : WM_RBUTTONDOWN; wp = key_up ? 0 : MK_RBUTTON; }
		else if(key == VK_MBUTTON) { msg = key_up ? WM_MBUTTONUP : WM_MBUTTONDOWN; wp = key_up ? 0 : MK_MBUTTON; }
		else if(key == 0x0A || key == 0x0B) {
			if(key_up) return true;
			PostMessage(g, WM_MOUSEWHEEL, MAKEWPARAM(0, (key == 0x0A) ? WHEEL_DELTA : -WHEEL_DELTA), MAKELPARAM(pt.x, pt.y));
			return true;
		}
		else return false;
		RECT rc; GetClientRect(g, &rc);
		POINT c = pt; ScreenToClient(g, &c);
		if(c.x < 0) c.x = 0; if(c.y < 0) c.y = 0;
		if(c.x >= rc.right) c.x = rc.right - 1; if(c.y >= rc.bottom) c.y = rc.bottom - 1;
		PostMessage(g, msg, wp, MAKELPARAM(c.x, c.y));
		m_CursorFixes++;
		if(m_CursorFixes <= 10) {
			char was[200]; describe(root, was, sizeof(was));
			API::get()->log_info("JoytoKey.dll (Silverfish fork): click sent straight to the game (the cursor spot is covered by %s at %ld,%ld) (#%d)",
				was, pt.x, pt.y, m_CursorFixes);
		}
		return true;
	}

	// v6 keep-alive: this game never reads a gamepad. UEVR reacts to that - every frame a VR button or stick is in use -
	// by broadcasting "a device was plugged in" (WM_DEVICECHANGE) to the game, 36,000 times in an 8-minute session,
	// and the game re-scans all its input devices each time: those were the big stutters. Reading the (UEVR-hooked)
	// controller ourselves 10x a second tells UEVR a gamepad is being read, so it stops. It also brings back UEVR's own
	// both-sticks menu toggle.
	PFN_XInputGetState_t find_game_import(const char* dllPart, const char* fnName) {
		HMODULE exe = GetModuleHandleA(NULL);
		if(exe == NULL) return NULL;
		unsigned char* base = (unsigned char*)exe;
		IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)base;
		if(dos->e_magic != IMAGE_DOS_SIGNATURE) return NULL;
		IMAGE_NT_HEADERS64* nt = (IMAGE_NT_HEADERS64*)(base + dos->e_lfanew);
		if(nt->Signature != IMAGE_NT_SIGNATURE) return NULL;
		IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
		if(dir.VirtualAddress == 0) return NULL;
		IMAGE_IMPORT_DESCRIPTOR* imp = (IMAGE_IMPORT_DESCRIPTOR*)(base + dir.VirtualAddress);
		for(; imp->Name != 0; imp++) {
			const char* name = (const char*)(base + imp->Name);
			std::string lower(name);
			for(auto& ch : lower) ch = (char)tolower((unsigned char)ch);
			if(lower.find(dllPart) == std::string::npos) continue;
			IMAGE_THUNK_DATA64* orig = (IMAGE_THUNK_DATA64*)(base + (imp->OriginalFirstThunk ? imp->OriginalFirstThunk : imp->FirstThunk));
			IMAGE_THUNK_DATA64* iat = (IMAGE_THUNK_DATA64*)(base + imp->FirstThunk);
			for(; orig->u1.AddressOfData != 0; orig++, iat++) {
				if(orig->u1.Ordinal & IMAGE_ORDINAL_FLAG64) continue;
				IMAGE_IMPORT_BY_NAME* ibn = (IMAGE_IMPORT_BY_NAME*)(base + orig->u1.AddressOfData);
				if(strcmp((const char*)ibn->Name, fnName) == 0) return (PFN_XInputGetState_t)iat->u1.Function;
			}
		}
		return NULL;
	}

	void keepalive_pump() {
		// v9: switched off. Steam Input answers these reads itself (result 0 = "gamepad connected") and never passes
		// them on, so they can't reach UEVR; the both-sticks menu uses the Insert key, which works.
		if(!m_PumpReported) { m_PumpReported = true; API::get()->log_info("JoytoKey.dll (Silverfish fork): keep-alive reads off (Steam Input answers them itself)"); }
		return;
		ULONGLONG now = GetTickCount64();
		if(now < m_PumpNext) return;
		m_PumpNext = now + 100;
		if(!m_PumpTried) {
			HMODULE xi = GetModuleHandleA("xinput1_4.dll");
			if(xi == NULL) xi = GetModuleHandleA("xinput1_3.dll");
			if(xi == NULL) { if(now > 60000) { m_PumpTried = true; API::get()->log_info("JoytoKey.dll (Silverfish fork): keep-alive: no XInput DLL loaded - not active"); } return; }
			m_PumpTried = true;
			// v8: call exactly what the GAME calls - the XInputGetState slot in its own import table (that path is
			// proven to reach UEVR); the plain export was hooked by something else and never reached it.
			m_PumpFn = find_game_import("xinput", "XInputGetState");
			const char* how = "game import table";
			if(m_PumpFn == NULL) { m_PumpFn = (PFN_XInputGetState_t)GetProcAddress(xi, "XInputGetState"); how = "DLL export"; }
			API::get()->log_info("JoytoKey.dll (Silverfish fork): keep-alive controller reads %s via %s at %p", m_PumpFn ? "ON" : "unavailable", how, (void*)m_PumpFn);
		}
		if(m_PumpFn == NULL) return;
		XINPUT_STATE st; ZeroMemory(&st, sizeof(st));
		t_SelfPump = true;
		DWORD rv = m_PumpFn(0, &st);
		t_SelfPump = false;
		m_PumpCount++;
		m_PumpWorking = (m_SelfSeen > 0);
		if(!m_PumpReported && m_PumpCount >= 30) {
			m_PumpReported = true;
			unsigned char* b = (unsigned char*)m_PumpFn;
			API::get()->log_info("JoytoKey.dll (Silverfish fork): keep-alive check: %u reads, %u came back through UEVR's hook, XInputGetState at %p starts with %02X %02X %02X %02X %02X, last result %lu -> %s",
				m_PumpCount, m_SelfSeen, (void*)m_PumpFn, b[0], b[1], b[2], b[3], b[4], (unsigned long)rv,
				m_PumpWorking ? "WORKING" : "NOT reaching UEVR (both-sticks menu uses the Insert key instead)");
		}
	}

	// v7: melee swing - sf_main.lua writes data\sf_melee.txt = "1" while a knife / tool is in the right hand.
	// A fast swing of the right controller then presses the attack button (left mouse) for one hit.
	void melee_poll() {
		ULONGLONG now = GetTickCount64();
		if(now - m_MeleeCheck > 500) {
			m_MeleeCheck = now;
			if(m_MeleeFile.empty()) {
				auto p = std::filesystem::path(m_Path).parent_path().parent_path() / "data" / "sf_melee.txt";
				m_MeleeFile = p.string();
			}
			bool armed = false;
			std::ifstream f(m_MeleeFile);
			if(f) { char c = 0; f >> c; armed = (c == '1'); }
			if(armed != m_MeleeArmed) {
				m_MeleeArmed = armed;
				API::get()->log_info("JoytoKey.dll (Silverfish fork): melee swing %s", armed ? "armed" : "off");
				m_SwCount = 0;
			}
		}
		if(m_SwingUpAt != 0 && now >= m_SwingUpAt) {
			m_SwingUpAt = 0;
			if(!post_mouse_to_game(VK_LBUTTON, true)) send_mouse(VK_LBUTTON, true);
		}
		if(!m_MeleeArmed) return;
		UEVR_Vector3f pos; UEVR_Quaternionf q;
		ZeroMemory(&pos, sizeof(pos)); ZeroMemory(&q, sizeof(q));
		m_VR->get_pose(m_VR->get_right_controller_index(), &pos, &q);
		int i = m_SwHead;
		m_SwPos[i][0] = pos.x; m_SwPos[i][1] = pos.y; m_SwPos[i][2] = pos.z; m_SwTick[i] = now;
		m_SwHead = (m_SwHead + 1) % 8;
		if(m_SwCount < 5) { m_SwCount++; return; }
		int j = (m_SwHead + 3) % 8;   // sample ~50 ms ago (v8: quicker than the 80 ms window)
		float dx = pos.x - m_SwPos[j][0], dy = pos.y - m_SwPos[j][1], dz = pos.z - m_SwPos[j][2];
		float dt = (float)(now - m_SwTick[j]) / 1000.0f;
		if(dt <= 0.0f) return;
		float speed = sqrtf(dx * dx + dy * dy + dz * dz) / dt;   // metres per second
		if(speed > 1.9f && now >= m_SwingCooldown && !game_menu_open()) {
			m_SwingCooldown = now + 450;
			m_SwingUpAt = now + 90;
			if(!post_mouse_to_game(VK_LBUTTON, false)) send_mouse(VK_LBUTTON, false);
			m_Swings++;
			if(m_Swings <= 5) API::get()->log_info("JoytoKey.dll (Silverfish fork): melee swing (%.1f m/s) -> attack", speed);
		}
	}

	void send_wheel(bool up) {
		if(!post_mouse_to_game(up ? 0x0A : 0x0B, false)) {
			INPUT in = {}; in.type = INPUT_MOUSE; in.mi.dwFlags = MOUSEEVENTF_WHEEL;
			in.mi.mouseData = up ? WHEEL_DELTA : (DWORD)(-WHEEL_DELTA);
			SendInput(1, &in, sizeof(INPUT));
		}
	}

	// v5: a game menu is open exactly when sf_main.lua has switched UEVR to its flat menu screen. (v4 looked at the
	// Windows cursor, which can still be showing for a moment after a menu closes -> the wheel changed weapons.)
	bool game_menu_open() {
		ULONGLONG now = GetTickCount64();
		if(now - m_MenuCheckTick > 100) {
			m_MenuCheckTick = now;
			char v[16] = {0};
			m_VR->get_mod_value("VR_2DScreenMode", v, sizeof(v));
			bool open = (strcmp(v, "true") == 0);
			if(open && !m_MenuOpen) m_MenuOpenSince = now;
			m_MenuOpen = open;
		}
		return m_MenuOpen && (now - m_MenuOpenSince) > 150;
	}

	void put_cursor_on_game() {
		HWND g = game_window();
		if(g == NULL) return;
		POINT pt;
		if(!GetCursorPos(&pt)) return;
		HWND under = WindowFromPoint(pt);
		HWND root = under ? GetAncestor(under, GA_ROOT) : NULL;
		if(root == g) return;
		DWORD upid = 0;
		if(root) GetWindowThreadProcessId(root, &upid);
		if(upid == GetCurrentProcessId() && root != NULL) return;
		RECT rc;
		if(!GetClientRect(g, &rc)) return;
		POINT c = { (rc.right - rc.left) / 2, (rc.bottom - rc.top) / 2 };
		ClientToScreen(g, &c);
		char was[200]; describe(root, was, sizeof(was));
		SetCursorPos(c.x, c.y);
		m_CursorFixes++;
		if(m_CursorFixes <= 20)
			API::get()->log_info("JoytoKey.dll (Silverfish fork): mouse click would have gone to another window (%s at %ld,%ld) - cursor moved onto the game (fix #%d)",
				was, pt.x, pt.y, m_CursorFixes);
	}
	
    JoyToKey() = default;
	
    void on_dllmain(HANDLE handle) override {
         StoreConfigFileLocation(handle);
   }

    void on_initialize() override {
      DWORD ThreadId  = 0;
      API::get()->log_info("JoytoKey.dll: Config file should be: %s\n", m_Path.c_str());  
      ReadConfig(m_Path);

      m_Param = API::get()->param();
      m_VR = m_Param->vr;

	  m_XinputPumpRunning = false;
	  CreateThread(NULL, 0,(LPTHREAD_START_ROUTINE)(&TimerCallbackThreadProc), this, 0 , &ThreadId);
    }

    void send_key_or_mouse(int Index, bool key_up) {
        if(m_Keys[Index].Key == 0xFF || m_Keys[Index].Key == 0) return;   // switched off
        if(!key_up) make_game_foreground();
        if(m_Keys[Index].Mouse == true)
        {
            // v4: a click goes to the game even when another window (e.g. an always-on-top app) covers that spot
            if(!post_mouse_to_game(m_Keys[Index].Key, key_up)) send_mouse(m_Keys[Index].Key, key_up);
        }
        else
        {
            send_key(m_Keys[Index].Key, key_up);
        }
    }
    

    void MoveMousePointer(SHORT& StickValue, bool Horizontal) {
		int Value = StickValue;
		
        // Clamp Value to the range -20000 to +20000
        if (Value < -32000) Value = -32000;
        if (Value > 32000) Value = 32000;
        
        // Flip the axis. The joystick is inverted to the mouse + vs -
        if (Horizontal == false) Value = Value * -1;
        
        // Dead zone 15%
        if (Value > 0 && Value < 3000) return;
        if (Value < 0 && Value > -3000) return;
        
        if (Value < 5000 && Value > -5000) Value = Value / 2;
        if (Value > 28000 || Value < -28000) Value = (int)((Value * 3)/2);

        if(Horizontal == false) Value = (Value / 3) * 2;
        // Scale Value to the range -10 to +10
        float scaledValue = (static_cast<float>(Value) / 3200.0f);

        // Calculate new position based on Horizontal flag
        int newX = (Horizontal ? static_cast<int>(scaledValue) : 0);
        int newY = (Horizontal ? 0 : static_cast<int>(scaledValue));

        // Create an INPUT structure for the mouse movement
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dx = newX; // Move relative
        input.mi.dy = newY; // Move relative
        input.mi.dwFlags = MOUSEEVENTF_MOVE; // Use absolute movement

        // Send the input to move the mouse
        SendInput(1, &input, sizeof(INPUT));
		
		// Clear stick value
		StickValue = 0;
    }

    void send_key(WORD key, bool key_up) {
        INPUT input;
        ZeroMemory(&input, sizeof(INPUT));
        input.type = INPUT_KEYBOARD;
        input.ki.wVk = key;
        if(key_up) input.ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(1, &input, sizeof(INPUT));
    }
    
    void send_mouse(WORD key, bool key_up) {
        INPUT input;
        ZeroMemory(&input, sizeof(INPUT));
        input.type = INPUT_MOUSE;
        
        // Handle mouse button events
        if(key == VK_LBUTTON) {
            input.mi.dwFlags = (key_up ? MOUSEEVENTF_LEFTUP : MOUSEEVENTF_LEFTDOWN);
        }
        else if(key == VK_RBUTTON) {
            input.mi.dwFlags = (key_up ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_RIGHTDOWN);
        }
        else if(key == VK_MBUTTON) {
            input.mi.dwFlags = (key_up ? MOUSEEVENTF_MIDDLEUP : MOUSEEVENTF_MIDDLEDOWN);
        }
        else if(key == VK_XBUTTON1) {
            input.mi.dwFlags = (key_up ? MOUSEEVENTF_XUP : MOUSEEVENTF_XDOWN);
            input.mi.mouseData = XBUTTON1;
        }
        else if(key == VK_XBUTTON2) {
            input.mi.dwFlags = (key_up ? MOUSEEVENTF_XUP : MOUSEEVENTF_XDOWN);
            input.mi.mouseData = XBUTTON2;
        }
        // Handle mouse wheel events
        else if(key == 0x0A) { // Wheel up
            input.mi.dwFlags = MOUSEEVENTF_WHEEL;
            input.mi.mouseData = WHEEL_DELTA; // Positive for wheel up
        }
        else if(key == 0x0B) { // Wheel down
            input.mi.dwFlags = MOUSEEVENTF_WHEEL;
            input.mi.mouseData = -WHEEL_DELTA; // Negative for wheel down
        }

        SendInput(1, &input, sizeof(INPUT));
    }

    //*******************************************************************************************
	//
	// Pass controller 1 and controller 2 instead of controller and hmd to see if controllers
	// aer near each other.
	// proximity is probably in 1.0 meter virtual ranges.
	//
    //*******************************************************************************************
	bool is_controller_near_hmd(
		UEVR_TrackedDeviceIndex controller_index,
		float proximity_threshold, // Define a threshold distance
		UEVR_TrackedDeviceIndex hmd_index) 
	{
		UEVR_Vector3f controller_pos, hmd_pos;
		UEVR_Quaternionf unused_rotation; // Not needed for this calculation

		ZeroMemory(&controller_pos, sizeof(controller_pos));
		ZeroMemory(&hmd_pos, sizeof(hmd_pos));
		ZeroMemory(&unused_rotation, sizeof(unused_rotation));
		
		// Use VR->get_pose() directly
		m_VR->get_pose(controller_index, &controller_pos, &unused_rotation);
		m_VR->get_pose(hmd_index, &hmd_pos, &unused_rotation);

		// Compute the squared distance between the two points
		float distance_squared = 
			(controller_pos.x - hmd_pos.x) * (controller_pos.x - hmd_pos.x) +
			(controller_pos.y - hmd_pos.y) * (controller_pos.y - hmd_pos.y) +
			(controller_pos.z - hmd_pos.z) * (controller_pos.z - hmd_pos.z);

		// Compare against squared threshold to avoid expensive sqrt calculation
		return distance_squared <= proximity_threshold * proximity_threshold;
	}

    //*******************************************************************************************
    // This is the controller input routine for non-xinput devices. It builds an XINPUT_STATE 
	// and calls on_xinput_get_state()
    //*******************************************************************************************
	void start_input_polling()
	{
		XINPUT_STATE state;
		uint32_t retval = 0;
		uint32_t user_index = CONTROLLER_SOURCE_THREAD;
		
        UEVR_InputSourceHandle LeftController = m_VR->get_left_joystick_source();
        UEVR_InputSourceHandle RightController = m_VR->get_right_joystick_source();
		
		UEVR_ActionHandle VR_LB_RB = m_VR->get_action_handle("/actions/default/in/Grip");
		UEVR_ActionHandle VR_RT_LT = m_VR->get_action_handle("/actions/default/in/Trigger");
		UEVR_ActionHandle VR_STICK = m_VR->get_action_handle("/actions/default/in/Joystick");
		UEVR_ActionHandle VR_STICK_CLICK = m_VR->get_action_handle("/actions/default/in/JoystickClick");
		UEVR_ActionHandle VR_B = m_VR->get_action_handle("/actions/default/in/AButtonLeft");
		UEVR_ActionHandle VR_Y = m_VR->get_action_handle("/actions/default/in/BButtonLeft");
		UEVR_ActionHandle VR_A = m_VR->get_action_handle("/actions/default/in/AButtonRight");
		UEVR_ActionHandle VR_X = m_VR->get_action_handle("/actions/default/in/BButtonRight");
		UEVR_ActionHandle VR_START = m_VR->get_action_handle("/actions/default/in/SystemButton");
		UEVR_ActionHandle ThumbrestLeft = m_VR->get_action_handle("/actions/default/in/ThumbrestTouchLeft");
		UEVR_ActionHandle ThumbrestRight = m_VR->get_action_handle("/actions/default/in/ThumbrestTouchRight");
		UEVR_ActionHandle VR_DUP = m_VR->get_action_handle("/actions/default/in/DPad_Up");
		UEVR_ActionHandle VR_DDOWN = m_VR->get_action_handle("/actions/default/in/DPad_Down");
		UEVR_ActionHandle VR_DLEFT = m_VR->get_action_handle("/actions/default/in/DPad_Left");
		UEVR_ActionHandle VR_DRIGHT = m_VR->get_action_handle("/actions/default/in/DPad_Right");
		
		UEVR_Vector2f LeftAxis;
		UEVR_Vector2f RightAxis;
		
		API::get()->log_info("JoytoKey.dll: start_input_polling is beginning.");  

		while(true)
		{
			keepalive_pump();
			melee_poll();
			if(GetTickCount64() - m_LastNaturalTick < 500)
			{
				if(m_VrActive) { m_VrActive = false; API::get()->log_info("JoytoKey.dll (Silverfish fork): game is reading the controller - VR input paused."); }
				Sleep(XINPUT_POLL_TIME);
				continue;
			}
			if(!m_VrActive) { m_VrActive = true; API::get()->log_info("JoytoKey.dll (Silverfish fork): VR controller input ACTIVE."); }
			// Clear the xinput state.
			ZeroMemory(&state, sizeof(XINPUT_STATE));
			ZeroMemory(&LeftAxis, sizeof(UEVR_Vector2f));
			ZeroMemory(&RightAxis, sizeof(UEVR_Vector2f));
			
			// Populate the xinput state based on VR actions.
			if(m_VR->is_action_active(VR_LB_RB, LeftController)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_LEFT_SHOULDER;
			if(m_VR->is_action_active(VR_LB_RB, RightController)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_RIGHT_SHOULDER;

			if(m_VR->is_action_active(VR_RT_LT, LeftController)) state.Gamepad.bLeftTrigger = 255;
			if(m_VR->is_action_active(VR_RT_LT, RightController)) state.Gamepad.bRightTrigger = 255;

			if(m_VR->is_action_active(VR_STICK_CLICK, LeftController)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_LEFT_THUMB;
			if(m_VR->is_action_active(VR_STICK_CLICK, RightController)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_RIGHT_THUMB;
			
			// Steam Frame: all four face buttons are on one controller -> check both hands
			if(m_VR->is_action_active_any_joystick(VR_B)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_B;
			if(m_VR->is_action_active_any_joystick(VR_Y)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_Y;
			if(m_VR->is_action_active_any_joystick(VR_A)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_A;
			if(m_VR->is_action_active_any_joystick(VR_X)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_X;
			if(m_VR->is_action_active_any_joystick(VR_DUP)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_DPAD_UP;
			if(m_VR->is_action_active_any_joystick(VR_DDOWN)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_DPAD_DOWN;
			if(m_VR->is_action_active_any_joystick(VR_DLEFT)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_DPAD_LEFT;
			if(m_VR->is_action_active_any_joystick(VR_DRIGHT)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_DPAD_RIGHT;
			
			if(m_VR->is_action_active_any_joystick(VR_START)) state.Gamepad.wButtons |= XINPUT_GAMEPAD_START;

			// Joystickaxis come back as an x,y float ranging from -1.0 to +1.0. The xinput axis ranges from -32767 to + 32767
			m_VR->get_joystick_axis(LeftController, &LeftAxis);
			m_VR->get_joystick_axis(RightController, &RightAxis);
			
			state.Gamepad.sThumbLX = (SHORT)(LeftAxis.x * 32767.0f);
			state.Gamepad.sThumbLY = (SHORT)(LeftAxis.y * 32767.0f);
			state.Gamepad.sThumbRX = (SHORT)(RightAxis.x * 32767.0f);
			state.Gamepad.sThumbRY = (SHORT)(RightAxis.y * 32767.0f);
			
			// Silverfish fork: both stick clicks together = UEVR menu (UEVR only sees that combo when the game reads the
			// controller itself, which this game doesn't) -> press UEVR's menu key (Insert) instead.
			{
				const WORD both = XINPUT_GAMEPAD_LEFT_THUMB | XINPUT_GAMEPAD_RIGHT_THUMB;
				const bool bothDown = (state.Gamepad.wButtons & both) == both;
				if(bothDown && !m_BothSticksWasDown && !m_PumpWorking)   // v6: with the keep-alive UEVR opens its menu itself
				{
					make_game_foreground();
					send_key(VK_INSERT, false);
					Sleep(30);
					send_key(VK_INSERT, true);
					API::get()->log_info("JoytoKey.dll (Silverfish fork): both sticks clicked -> UEVR menu key (Insert)");
				}
				m_BothSticksWasDown = bothDown;
				if(bothDown) state.Gamepad.wButtons &= ~both;   // don't also sprint / melee
			}

			// v4: right stick up/down scrolls game menus (mouse wheel); in the game world the stick turns (sf_main.lua)
			{
				float ry = RightAxis.y;
				ULONGLONG now = GetTickCount64();
				if((ry > 0.5f || ry < -0.5f) && game_menu_open())
				{
					ULONGLONG gap = (ry > 0.9f || ry < -0.9f) ? 45 : 100;   // v5: faster
					if(m_WheelNext == 0 || now >= m_WheelNext)
					{
						send_wheel(ry > 0);
						m_WheelNext = now + ((m_WheelNext == 0) ? 220 : gap);   // short pause after the first step
						if(!m_WheelLogged) { m_WheelLogged = true; API::get()->log_info("JoytoKey.dll (Silverfish fork): right stick scrolls the menu"); }
					}
				}
				else m_WheelNext = 0;
			}

			// Call the xinput state function
			on_xinput_get_state(&retval, user_index, &state);
			
			// Go through every VR action and if it's active, map to an equivalent xinput state object.
			Sleep(XINPUT_POLL_TIME);
		}
		
		API::get()->log_info("JoytoKey.dll: start_input_polling is exiting as unneeded.");  

	}
	
    //*******************************************************************************************
    // This is the controller input routine. Everything happens here.
    //*******************************************************************************************
    void on_xinput_get_state(uint32_t* retval, uint32_t user_index, XINPUT_STATE* state) 
    {
        int i = 0;
        int Start = 0;
		int MotionLbFactor = 0;
        int Limit = GAMEPAD_NUMBER_OF_BUTTONS;
		
		// We are using this flag to determine if the source of calling this function is
		// the UEVR / game's xinput pump or if it's from our thread.
		if(t_SelfPump) { m_SelfSeen++; return; }   // v6: our own keep-alive read - nothing to do
		if(user_index != CONTROLLER_SOURCE_THREAD)
		{
			m_LastNaturalTick = GetTickCount64();
			if(!m_LoggedNatural)
			{
				m_LoggedNatural = true;
				API::get()->log_info("JoytoKey.dll (Silverfish fork): game read the controller - VR input pauses only while it keeps doing so.");
			}
		}			
		
        if(state != NULL)
        {
			UEVR_TrackedDeviceIndex HmdIndex = m_VR->get_hmd_index();
			UEVR_TrackedDeviceIndex LeftIndex = m_VR->get_left_controller_index();
			UEVR_TrackedDeviceIndex RightIndex = m_VR->get_right_controller_index();
			
			bool LeftAndHmd = is_controller_near_hmd(LeftIndex, TOUCH_PROXIMITY, HmdIndex);
			bool RightAndHmd = is_controller_near_hmd(RightIndex, TOUCH_PROXIMITY, HmdIndex);
			bool LeftAndRight = is_controller_near_hmd(LeftIndex, TOUCH_PROXIMITY, RightIndex);
			
			if(m_ExtraDebug == true)
			{
				
				API::get()->log_info("JoytoKey.dll: on_xinput_get_state: wButtons=0x%04x, Right Stick(%d,%d), Left Stick(%d,%d)\n", 
									 state->Gamepad.wButtons, 
									 state->Gamepad.sThumbRX,
									 state->Gamepad.sThumbRY,
									 state->Gamepad.sThumbLX,
									 state->Gamepad.sThumbLY
									 );  
			}

            // if using shift key
            if(m_Keys[GAMEPAD_LB].Key == 0)
            {
                // LB is not down, so we need to clear every LB key
                if(!(state->Gamepad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER))
                {
                    // OK If LB is not down, go through every shift key and if one is down, release it
                    for(i = GAMEPAD_NUMBER_OF_BUTTONS; i < TOTAL_GAMEPAD_BUTTONS; i++)
                    {
                        if(m_Keys[i].KeyDown == true)
                        {
                            send_key_or_mouse(i, KEYUP);
                            m_Keys[i].KeyDown = false;
                        }
                    }
					
					// clear motion shifted LB buttons
					for(i = LEFT_CONTROL_LB_TO_HMD; i < TOTAL_BUTTONS; i++)
					{
                        if(m_Keys[i].KeyDown == true)
                        {
                            send_key_or_mouse(i, KEYUP);
                            m_Keys[i].KeyDown = false;
                        }
					}
                }
                
                // LB is down, so we need to clear every regular key.
                else
                {
                    // OK If LB not down, go through every shift key and if one is down, release it
                    for(i = 1; i < GAMEPAD_NUMBER_OF_BUTTONS; i++)
                    {
                        if(m_Keys[i].KeyDown == true)
                        {
                            send_key_or_mouse(i, KEYUP);
                            m_Keys[i].KeyDown = false;
                        }
                    }
					
					// Clear non-shifted motion buttons
					for(i = LEFT_CONTROL_TO_HMD; i < (NUM_MOTIONS/2); i++)
					{
                        if(m_Keys[i].KeyDown == true)
                        {
                            send_key_or_mouse(i, KEYUP);
                            m_Keys[i].KeyDown = false;
                        }
					}

                    Start = GAMEPAD_NUMBER_OF_BUTTONS;
					MotionLbFactor = NUM_MOTIONS/2;
                    Limit = TOTAL_GAMEPAD_BUTTONS;
                }
            }
			
            // Seems there's a state before the game gets going these all return 1.
            if(LeftAndHmd == true && RightAndHmd == true && LeftAndRight == true)
            {
                LeftAndHmd = false;
                RightAndHmd = false;
                LeftAndRight = false;
            }
            
            // (Silverfish fork: per-poll proximity logging removed - it wrote ~50 lines a second into UEVR's log)
			// Go through the motion positions
			SetKeyForControllerPosition(LEFT_CONTROL_TO_HMD + MotionLbFactor, LeftAndHmd);
			SetKeyForControllerPosition(RIGHT_CONTROL_TO_HMD + MotionLbFactor, RightAndHmd);
			SetKeyForControllerPosition(LEFT_RIGHT_CONTROL_TOUCH + MotionLbFactor, LeftAndRight);
            
            // go through each xinput button. If it's down check if we need to set it. If its not, check if we need to clear it
            SetKeyForGamepad(state, Start + GAMEPAD_DPAD_UP, XINPUT_GAMEPAD_DPAD_UP);
            SetKeyForGamepad(state, Start + GAMEPAD_DPAD_DOWN, XINPUT_GAMEPAD_DPAD_DOWN);
            SetKeyForGamepad(state, Start + GAMEPAD_DPAD_LEFT, XINPUT_GAMEPAD_DPAD_LEFT);
            SetKeyForGamepad(state, Start + GAMEPAD_DPAD_RIGHT, XINPUT_GAMEPAD_DPAD_RIGHT);
           
            SetKeyForGamepad(state, Start + GAMEPAD_START, XINPUT_GAMEPAD_START);
            SetKeyForGamepad(state, Start + GAMEPAD_BACK, XINPUT_GAMEPAD_BACK);
            SetKeyForGamepad(state, Start + GAMEPAD_L3, XINPUT_GAMEPAD_LEFT_THUMB);
            SetKeyForGamepad(state, Start + GAMEPAD_R3, XINPUT_GAMEPAD_RIGHT_THUMB);
            
            SetKeyForGamepad(state, Start + GAMEPAD_LB, XINPUT_GAMEPAD_LEFT_SHOULDER);
            SetKeyForGamepad(state, Start + GAMEPAD_RB, XINPUT_GAMEPAD_RIGHT_SHOULDER);
            
            SetKeyForGamepad(state, Start + GAMEPAD_A, XINPUT_GAMEPAD_A);
            SetKeyForGamepad(state, Start + GAMEPAD_B, XINPUT_GAMEPAD_B);
            SetKeyForGamepad(state, Start + GAMEPAD_X, XINPUT_GAMEPAD_X);
            SetKeyForGamepad(state, Start + GAMEPAD_Y, XINPUT_GAMEPAD_Y);
            
            SetKeyForAxis(state->Gamepad.bRightTrigger, 200, Start + GAMEPAD_RT);
            SetKeyForAxis(state->Gamepad.bLeftTrigger, 200, Start + GAMEPAD_LT);

            SetKeyForAxis(state->Gamepad.sThumbLX, 20000, Start + GAMEPAD_LSTICK_RIGHT);
            SetKeyForAxis(state->Gamepad.sThumbLX, -20000, Start + GAMEPAD_LSTICK_LEFT);
            SetKeyForAxis(state->Gamepad.sThumbLY, 20000, Start + GAMEPAD_LSTICK_UP);
            SetKeyForAxis(state->Gamepad.sThumbLY, -20000, Start + GAMEPAD_LSTICK_DOWN);
            
            // If right axis isn't overridden, use it as a mouse pointer.
            if(m_Keys[Start + GAMEPAD_RSTICK_RIGHT].Key == 0 && m_Keys[Start + GAMEPAD_RSTICK_LEFT].Key == 0)
            {
                if(m_Keys[Start + GAMEPAD_RSTICK_RIGHT].Key != 0xFF && m_Keys[Start + GAMEPAD_RSTICK_LEFT].Key != 0xFF)
                    MoveMousePointer(state->Gamepad.sThumbRX, true);
            }
            else
            {
                SetKeyForAxis(state->Gamepad.sThumbRX, 20000, Start + GAMEPAD_RSTICK_RIGHT);
                SetKeyForAxis(state->Gamepad.sThumbRX, -20000, Start + GAMEPAD_RSTICK_LEFT);
            }
            if(m_Keys[Start + GAMEPAD_RSTICK_UP].Key == 0 && m_Keys[Start + GAMEPAD_RSTICK_DOWN].Key == 0)
            {
                if(m_Keys[Start + GAMEPAD_RSTICK_UP].Key != 0xFF && m_Keys[Start + GAMEPAD_RSTICK_DOWN].Key != 0xFF)
                    MoveMousePointer(state->Gamepad.sThumbRY, false);
            }
            else
            {
                SetKeyForAxis(state->Gamepad.sThumbRY, 20000, Start + GAMEPAD_RSTICK_UP);
                SetKeyForAxis(state->Gamepad.sThumbRY, -20000, Start + GAMEPAD_RSTICK_DOWN);
            }
        }
    }

    void SetKeyForAxis(SHORT& Axis, int CompareValue, int i)
    {
		if(_SetKeyForAxis(Axis, CompareValue, i) == true) Axis = 0;
	}
	
    void SetKeyForAxis(BYTE& Axis, int CompareValue, int i)
    {
		if(_SetKeyForAxis(Axis, CompareValue, i) == true) Axis = 0;
	}

	//***************************************************************************************************
    // Sets the key up or down for the axis values
	//***************************************************************************************************
    bool _SetKeyForAxis(int Axis, int CompareValue, int i)
    {
		bool KeyExists = false;
		if(m_Keys[i].Key)
		{
			bool ConsiderDown = false;
			
			if(CompareValue > 0)
			{
				if(Axis > CompareValue) ConsiderDown = true;
			}
			else 
			{
				if(Axis < CompareValue) ConsiderDown = true;
			}
			
			if(ConsiderDown == true)
			{
				if(m_Keys[i].KeyDown == false)
				{
					m_Keys[i].KeyDown = true;
					send_key_or_mouse(i, KEYDOWN);
                    KeyExists = true;
				}
			}
			else
			{
				if(m_Keys[i].KeyDown == true)
				{
					m_Keys[i].KeyDown = false;
					send_key_or_mouse(i, KEYUP);
				}
			}
		}
		
		return KeyExists;
    }

	//***************************************************************************************************
    // Sets the key up or down for the wbutton values
	//***************************************************************************************************
    void SetKeyForGamepad(XINPUT_STATE* state, int i, int Mask)
    {
		if(m_Keys[i].Key)
		{
			if(state->Gamepad.wButtons & Mask)
			{
				if(m_Keys[i].KeyDown == false)
				{
					m_Keys[i].KeyDown = true;
					send_key_or_mouse(i, KEYDOWN);
                    // Clear the gamepad button.
                    state->Gamepad.wButtons &= ~(Mask);
				}
			}
			else
			{
				if(m_Keys[i].KeyDown == true)
				{
					m_Keys[i].KeyDown = false;
					send_key_or_mouse(i, KEYUP);
				}
			}
			
		}
    }
    

	//***************************************************************************************************
    // Sets the key up or down for the wbutton values
	//***************************************************************************************************
    void SetKeyForControllerPosition(int i, bool State)
    {
		if(m_Keys[i].Key)
		{
			if(State == true)
			{
                API::get()->log_info("joytokey: Setting Key:0x%x", m_Keys[i].Key);
				if(m_Keys[i].KeyDown == false)
				{
					m_Keys[i].KeyDown = true;
					send_key_or_mouse(i, KEYDOWN);
				}
			}
			else
			{
				if(m_Keys[i].KeyDown == true)
				{
					m_Keys[i].KeyDown = false;
					send_key_or_mouse(i, KEYUP);
				}
			}
			
		}
    }

	//***************************************************************************************************
	// Stores the path and file location of the cvar.txt config file.
	//***************************************************************************************************
	void StoreConfigFileLocation(HANDLE handle) {
		wchar_t wide_path[MAX_PATH]{};
		if (GetModuleFileNameW((HMODULE)handle, wide_path, MAX_PATH)) {
			const auto config_path = std::filesystem::path(wide_path).parent_path();
			
			// Set the path for joytokey.txt
			m_Path = (config_path / "joytokey.txt").string(); 

			// Check if joytokey.debug exists in the same folder
			if (std::filesystem::exists(config_path / "joytokey.debug")) {
				m_ExtraDebug = true;
			}
		}
	}

	//***************************************************************************************************
	// Reads the config file cvars.txt and stores it in a linked list of CVAR_ITEMs.
	//***************************************************************************************************
    void ReadConfig(std::string ConfigFile) {
		std::string Line;
		
		int Length = 0;
		int i = 0;
        int LineNumber = 0;
		size_t Pos = 0;
		
        for(i = 0; i < TOTAL_BUTTONS; i++)
        {
            ZeroMemory(&m_Keys[i], sizeof(KEY_ITEM));
        }
        
		std::wstring_convert<std::codecvt_utf8<wchar_t>> Converter;
		
        
        API::get()->log_info("joytokey.dll: reading config file %s", ConfigFile.c_str());
		std::ifstream fileStream(ConfigFile.c_str());
		if(!fileStream.is_open()) {
			API::get()->log_error("joytokey.dll: %s cannot be opened or does not exist.", ConfigFile.c_str());
			return;
		}
		
			
		while (std::getline(fileStream, Line)) {
            LineNumber++;

            Length = static_cast<int>(Line.length());

			if(Line[0] == '#') continue;
			if(Line[0] == ';') continue;
			if(Line[0] == '[') continue;
			if(Line[0] == ' ') continue;
			if(Length < 3) continue;
			
			// Strip  spaces, carriage returns from line.
			Pos = Line.find_last_not_of(" \r\n");
			if(Pos != std::string::npos) {
				Line.erase(Pos + 1);
			}

			Pos = Line.find('=');
			if(Pos == std::string::npos) {
				API::get()->log_info("joytokey.dll: Invalid line, no = sign found or nothing after = found");   
				continue;
			}

			//API::get()->log_info("joytokey.dll: Line %d was %d long", LineNumber, Length);   
			API::get()->log_info("joytokey.dll: Processing config line: %s", Line.c_str());   

			// At this point, we are convinced we have a valid entry, find the key item to store it in.
            int KeyNumber = GetKeyNumber(Line);
            API::get()->log_info("joytokey.dll:  GetKeyNumber returned, key=%d", KeyNumber);
            if(KeyNumber >= 0 && KeyNumber < TOTAL_BUTTONS)
            {
                m_Keys[KeyNumber].Key = GetKeyFromLine(Line);
                // Silverfish fork: "OFF" really switches an input off (a plain 0 used to mean the '0' key, 0x30)
                { std::string t = Line; while(!t.empty() && (t.back() == '\r' || t.back() == ' ' || t.back() == '\t')) t.pop_back();
                  if(t.size() >= 4 && t.compare(t.size() - 4, 4, "=OFF") == 0) m_Keys[KeyNumber].Key = 0xFF; }
                if(m_Keys[KeyNumber].Key > 0 && m_Keys[KeyNumber].Key < 0x08) m_Keys[KeyNumber].Mouse = true;
                if(m_Keys[KeyNumber].Key == 0x0A || m_Keys[KeyNumber].Key == 0x0B) m_Keys[KeyNumber].Mouse = true;
                
                API::get()->log_info("joytokey.dll: Added entry: %s, %d=0x%02X", Line.c_str(), KeyNumber, m_Keys[KeyNumber].Key);
            }
		}		
		
		fileStream.close();
	}


	unsigned char GetKeyFromLine(const std::string& Line) {
		size_t pos = Line.find("=");
		if (pos != std::string::npos) {
			// Extract the part after "="
			std::string value = Line.substr(pos + 1);
			
			// Check if value is empty after "="
			if (value.empty()) {
				return 0; // Return a default value or handle as necessary
			}

			// Check if value is a single character
			if (value.size() == 1) {
				char key = value[0];
				// Accept only A-Z and 0-9
				if ((key >= 'A' && key <= 'Z') || (key >= '0' && key <= '9')) {
					return static_cast<unsigned char>(key); // Return the character as virtual key code
				} else if (std::islower(key) && (key >= 'a' && key <= 'z')) {
					// Convert lowercase a-z to uppercase
					return static_cast<unsigned char>(std::toupper(key));
				}
				// Ignore all other single characters
				return 0;
			}

			// Handle hex values with optional "0x" prefix
			if (value.size() > 2 && value.substr(0, 2) == "0x") {
				value = value.substr(2); // Remove "0x" prefix if present
			}

			// Try converting the hex string to an integer
			try {
				int intValue = std::stoi(value, nullptr, 16);
				if (intValue >= 0 && intValue <= 255) { // Ensure within unsigned char range
					return static_cast<unsigned char>(intValue);
				} else {
					return 0; // Handle out of range values
				}
			} catch (const std::invalid_argument&) {
				return 0; // Handle invalid hex values
			} catch (const std::out_of_range&) {
				return 0; // Handle out of range values
			}
		}

		return 0; // Return a default value if no "=" is found
	}

	//***************************************************************************************************
	// Returns the number for the hex string as a char so "0x2F" returns 0x2F
	//***************************************************************************************************
    unsigned char GetKeyFromLineOld(const std::string& Line) {
        size_t pos = Line.find("=");
        if (pos != std::string::npos) {
            // Extract the part after "="
            std::string hexValue = Line.substr(pos + 1);
            
            // Convert the hex string to an integer (base 16) and then to unsigned char
            int intValue = std::stoi(hexValue, nullptr, 16);
            return static_cast<unsigned char>(intValue);
        } else {
            return 0;
        }
    }
    
	//***************************************************************************************************
	// Returns the number for the key string.
	//***************************************************************************************************
    int GetKeyNumber(const std::string& Line) {
        int KeyNumber = -1;
        
        if(Line.find("GAMEPAD_LB=") != std::string::npos) KeyNumber = 0;
        else if(Line.find("GAMEPAD_DPAD_UP=") != std::string::npos) KeyNumber = 1;
        else if(Line.find("GAMEPAD_DPAD_DOWN=") != std::string::npos) KeyNumber = 2;
        else if(Line.find("GAMEPAD_DPAD_LEFT=") != std::string::npos) KeyNumber = 3;
        else if(Line.find("GAMEPAD_DPAD_RIGHT=") != std::string::npos) KeyNumber = 4;
        else if(Line.find("GAMEPAD_START=") != std::string::npos) KeyNumber = 5;
        else if(Line.find("GAMEPAD_BACK=") != std::string::npos) KeyNumber = 6;
        else if(Line.find("GAMEPAD_L3=") != std::string::npos) KeyNumber = 7;
        else if(Line.find("GAMEPAD_R3=") != std::string::npos) KeyNumber = 8;
        else if(Line.find("GAMEPAD_RT=") != std::string::npos) KeyNumber = 9;
        else if(Line.find("GAMEPAD_RB=") != std::string::npos) KeyNumber = 10;
        else if(Line.find("GAMEPAD_A=") != std::string::npos) KeyNumber = 11;
        else if(Line.find("GAMEPAD_B=") != std::string::npos) KeyNumber = 12;
        else if(Line.find("GAMEPAD_X=") != std::string::npos) KeyNumber = 13;
        else if(Line.find("GAMEPAD_Y=") != std::string::npos) KeyNumber = 14;
        else if(Line.find("GAMEPAD_LSTICK_UP=") != std::string::npos) KeyNumber = 15;
        else if(Line.find("GAMEPAD_LSTICK_DOWN=") != std::string::npos) KeyNumber = 16;
        else if(Line.find("GAMEPAD_LSTICK_LEFT=") != std::string::npos) KeyNumber = 17;
        else if(Line.find("GAMEPAD_LSTICK_RIGHT=") != std::string::npos) KeyNumber = 18;
        else if(Line.find("GAMEPAD_RSTICK_UP=") != std::string::npos) KeyNumber = 19;
        else if(Line.find("GAMEPAD_RSTICK_DOWN=") != std::string::npos) KeyNumber = 20;
        else if(Line.find("GAMEPAD_RSTICK_LEFT=") != std::string::npos) KeyNumber = 21;
        else if(Line.find("GAMEPAD_RSTICK_RIGHT=") != std::string::npos) KeyNumber = 22;
        else if(Line.find("GAMEPAD_LT=") != std::string::npos) KeyNumber = 23;
        
        else if(Line.find("GAMEPAD_LB_DPAD_UP=") != std::string::npos) KeyNumber = 25;
        else if(Line.find("GAMEPAD_LB_DPAD_DOWN=") != std::string::npos) KeyNumber = 26;
        else if(Line.find("GAMEPAD_LB_DPAD_LEFT=") != std::string::npos) KeyNumber = 27;
        else if(Line.find("GAMEPAD_LB_DPAD_RIGHT=") != std::string::npos) KeyNumber = 28;
        else if(Line.find("GAMEPAD_LB_START=") != std::string::npos) KeyNumber = 29;
        else if(Line.find("GAMEPAD_LB_BACK=") != std::string::npos) KeyNumber = 30;
        else if(Line.find("GAMEPAD_LB_L3=") != std::string::npos) KeyNumber = 31;
        else if(Line.find("GAMEPAD_LB_R3=") != std::string::npos) KeyNumber = 32;
        else if(Line.find("GAMEPAD_LB_RT=") != std::string::npos) KeyNumber = 33;
        else if(Line.find("GAMEPAD_LB_RB=") != std::string::npos) KeyNumber = 34;
        else if(Line.find("GAMEPAD_LB_A=") != std::string::npos) KeyNumber = 35;
        else if(Line.find("GAMEPAD_LB_B=") != std::string::npos) KeyNumber = 36;
        else if(Line.find("GAMEPAD_LB_X=") != std::string::npos) KeyNumber = 37;
        else if(Line.find("GAMEPAD_LB_Y=") != std::string::npos) KeyNumber = 38;
        else if(Line.find("GAMEPAD_LB_LSTICK_UP=") != std::string::npos) KeyNumber = 39;
        else if(Line.find("GAMEPAD_LB_LSTICK_DOWN=") != std::string::npos) KeyNumber = 40;
        else if(Line.find("GAMEPAD_LB_LSTICK_LEFT=") != std::string::npos) KeyNumber = 41;
        else if(Line.find("GAMEPAD_LB_LSTICK_RIGHT=") != std::string::npos) KeyNumber = 42;
        else if(Line.find("GAMEPAD_LB_RSTICK_UP=") != std::string::npos) KeyNumber = 43;
        else if(Line.find("GAMEPAD_LB_RSTICK_DOWN=") != std::string::npos) KeyNumber = 44;
        else if(Line.find("GAMEPAD_LB_RSTICK_LEFT=") != std::string::npos) KeyNumber = 45;
        else if(Line.find("GAMEPAD_LB_RSTICK_RIGHT=") != std::string::npos) KeyNumber = 46;
        else if(Line.find("GAMEPAD_LB_LT=") != std::string::npos) KeyNumber = 47;

        else if(Line.find("LEFT_CONTROL_TO_HMD=") != std::string::npos) KeyNumber = TOTAL_GAMEPAD_BUTTONS;
        else if(Line.find("RIGHT_CONTROL_TO_HMD=") != std::string::npos) KeyNumber = TOTAL_GAMEPAD_BUTTONS + 1;
        else if(Line.find("LEFT_RIGHT_CONTROL_TOUCH=") != std::string::npos) KeyNumber = TOTAL_GAMEPAD_BUTTONS + 2;
        else if(Line.find("LEFT_CONTROL_LB_TO_HMD=") != std::string::npos) KeyNumber = TOTAL_GAMEPAD_BUTTONS + 3;
        else if(Line.find("RIGHT_CONTROL_LB_TO_HMD=") != std::string::npos) KeyNumber = TOTAL_GAMEPAD_BUTTONS + 4;
        else if(Line.find("LEFT_RIGHT_CONTROL_LB_TOUCH=") != std::string::npos) KeyNumber = TOTAL_GAMEPAD_BUTTONS + 5;

        return KeyNumber;
    }
    
};
// Actually creates the plugin. Very important that this global is created.
// The fact that it's using std::unique_ptr is not important, as long as the constructor is called in some way.
std::unique_ptr<JoyToKey> g_plugin{new JoyToKey()};

void DebugPrint(char* Format, ...)
{
  char FormattedMessage[512];    
  va_list ArgPtr = NULL;  
  
  /* Generate the formatted debug message. */        
  va_start(ArgPtr, Format);        
  vsprintf(FormattedMessage, Format, ArgPtr);        
  va_end(ArgPtr); 

  OutputDebugString(FormattedMessage);
}

DWORD WINAPI
TimerCallbackThreadProc(
  LPVOID    lpParameter   // thread data
    )
{
    JoyToKey* Jtc = (JoyToKey*)lpParameter;
    Sleep(5000);
    
	Jtc->start_input_polling();
    return 0;
}

