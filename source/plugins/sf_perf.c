/*
 * sf_perf.dll - tiny READ-ONLY UEVR plugin: where does each frame's time go? (2026-11-07)
 *
 * Measures, between two reports asked for by sf_main.lua ("sfperf" "report"):
 *   - frames presented and the average frame time
 *   - how long the game's own engine tick takes (game thread work, from UEVR's pre/post engine tick callbacks)
 *   - CPU use of the game thread, the presenting (render/RHI) thread and the busiest other threads of the game
 *     (GetThreadTimes - 100% = that thread never rested)
 *   - GPU 3D-engine use of the game process and of the whole PC (Windows' own "GPU Engine" counters, the same
 *     numbers Task Manager shows; sampled once a second on a background thread)
 *   - v2 (2026-11-09): the 3 OTHER programs using the most GPU 3D engine (name and %), from the same counters - to see
 *     what besides the game eats the graphics card (SteamVR compositor, streaming, browsers, ...)
 *   - v3 (2026-11-09): programs Windows will not let us open (the desktop compositor dwm.exe, services) are named
 *     from the process list instead of showing as "pid1234".
 *   - v4 (2026-11-10, the public build): v3 could also list the monitors and the windows on the desktop (program
 *     name and size) when asked. That was a development aid; it is removed. The plugin looks at no window at all.
 * Answer: dispatch_lua_event("sfperf", "<text>"). It changes nothing in the game or on the PC.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <pdh.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <stdint.h>
typedef struct lua_State lua_State;
#include "uevr/API.h"

static const UEVR_PluginInitializeParam* P = NULL;
static LARGE_INTEGER g_freq;
static volatile LONG64 g_tick_acc = 0, g_tick_n = 0, g_frames = 0;
static LARGE_INTEGER g_tick_t0;
static DWORD g_game_tid = 0, g_present_tid = 0;
static volatile double g_gpu_game_sum = 0, g_gpu_all_sum = 0;
static volatile LONG g_gpu_n = 0;
static LARGE_INTEGER g_last_report;
static LONG64 g_last_frames = 0, g_last_tick_acc = 0, g_last_tick_n = 0;
static CRITICAL_SECTION g_cs;
#define MAXP 64
typedef struct { DWORD pid; double sum; } PG;              /* v2: GPU 3D use per other process, summed per sample */
static PG g_pg[MAXP];
static int g_npg = 0;

#define MAXT 1024
typedef struct { DWORD tid; ULONGLONG cpu; } TT;
static TT g_tt[MAXT];
static int g_ntt = 0;

static void logi(const char* s) { if (P && P->functions && P->functions->log_info) P->functions->log_info("%s", s); }

static ULONGLONG ft64(FILETIME f) { return ((ULONGLONG)f.dwHighDateTime << 32) | f.dwLowDateTime; }

static ULONGLONG thread_cpu(DWORD tid) {
    FILETIME c, e, k, u;
    ULONGLONG r = 0;
    HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, tid);
    if (h == NULL) return 0;
    if (GetThreadTimes(h, &c, &e, &k, &u)) r = ft64(k) + ft64(u);
    CloseHandle(h);
    return r;                               /* 100 ns units */
}

static void on_pre_tick(UEVR_UGameEngineHandle engine, float delta) {
    (void)engine; (void)delta;
    if (g_game_tid == 0) g_game_tid = GetCurrentThreadId();
    QueryPerformanceCounter(&g_tick_t0);
}
static void on_post_tick(UEVR_UGameEngineHandle engine, float delta) {
    LARGE_INTEGER t;
    (void)engine; (void)delta;
    if (g_tick_t0.QuadPart == 0) return;
    QueryPerformanceCounter(&t);
    InterlockedAdd64(&g_tick_acc, t.QuadPart - g_tick_t0.QuadPart);
    InterlockedIncrement64(&g_tick_n);
    g_tick_t0.QuadPart = 0;
}
static void on_present(void) {
    if (g_present_tid == 0) g_present_tid = GetCurrentThreadId();
    InterlockedIncrement64(&g_frames);
}

/* ---- GPU counters on a background thread ---- */
static double sum_counters(PDH_HCOUNTER* cs, int n) {
    double s = 0;
    int i;
    for (i = 0; i < n; i++) {
        PDH_FMT_COUNTERVALUE v;
        if (PdhGetFormattedCounterValue(cs[i], PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, NULL, &v) == ERROR_SUCCESS && v.CStatus == ERROR_SUCCESS) s += v.doubleValue;
    }
    return s;
}
static int add_wild(PDH_HQUERY q, const wchar_t* path, PDH_HCOUNTER* out, int maxn, DWORD* pids) {
    static wchar_t buf[1 << 16];
    DWORD len = (DWORD)(sizeof(buf) / sizeof(buf[0]));
    int n = 0;
    wchar_t* p;
    if (PdhExpandWildCardPathW(NULL, path, buf, &len, 0) != ERROR_SUCCESS) return 0;
    for (p = buf; *p && n < maxn; p += wcslen(p) + 1) {
        if (PdhAddCounterW(q, p, 0, &out[n]) == ERROR_SUCCESS) {
            if (pids != NULL) {                                    /* "...GPU Engine(pid_1234_luid_..." */
                const wchar_t* k = wcsstr(p, L"pid_");
                pids[n] = k ? (DWORD)wcstoul(k + 4, NULL, 10) : 0;
            }
            n++;
        }
    }
    return n;
}
static void add_pid(DWORD pid, double v) {                   /* caller holds g_cs */
    int i;
    if (pid == 0 || pid == GetCurrentProcessId() || v <= 0) return;
    for (i = 0; i < g_npg; i++) if (g_pg[i].pid == pid) { g_pg[i].sum += v; return; }
    if (g_npg < MAXP) { g_pg[g_npg].pid = pid; g_pg[g_npg].sum = v; g_npg++; }
}
static void put_name(const wchar_t* b, char* out, int n) {
    int i;
    for (i = 0; i < n - 1 && b[i]; i++) out[i] = (b[i] < 128 && b[i] != ';' && b[i] != ',' && b[i] != ':' && b[i] != '|' && b[i] != '=') ? (char)b[i] : '_';
    out[i] = 0;
}
static void pid_name(DWORD pid, char* out, int n) {
    wchar_t w[MAX_PATH];
    DWORD len = MAX_PATH;
    const wchar_t* b;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    snprintf(out, n, "pid%lu", (unsigned long)pid);
    if (h != NULL) {
        if (QueryFullProcessImageNameW(h, 0, w, &len)) {
            b = wcsrchr(w, L'\\'); b = b ? b + 1 : w;
            put_name(b, out, n);
            CloseHandle(h);
            return;
        }
        CloseHandle(h);
    }
    {                                                           /* v3: not allowed to open it - the process list still names it */
        static struct { DWORD pid; char nm[48]; } cache[16];    /* looked up once per program (game thread only) */
        static int ncache = 0;
        HANDLE snap;
        PROCESSENTRY32W pe;
        int i;
        for (i = 0; i < ncache; i++) if (cache[i].pid == pid) { snprintf(out, n, "%s", cache[i].nm); return; }
        snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return;
        pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) do {
            if (pe.th32ProcessID == pid) { put_name(pe.szExeFile, out, n); break; }
            pe.dwSize = sizeof(pe);
        } while (Process32NextW(snap, &pe));
        CloseHandle(snap);
        if (ncache < 16) { cache[ncache].pid = pid; snprintf(cache[ncache].nm, sizeof(cache[ncache].nm), "%s", out); ncache++; }
    }
}

static DWORD WINAPI gpu_thread(LPVOID arg) {
    wchar_t game_path[128];
    PDH_HQUERY q = NULL;
    PDH_HCOUNTER cg[64], ca[256];
    DWORD cpid[256];
    int ng = 0, na = 0, age = 0, i;
    (void)arg;
    swprintf(game_path, 128, L"\\GPU Engine(pid_%lu_*engtype_3D)\\Utilization Percentage", (unsigned long)GetCurrentProcessId());
    for (;;) {
        if (q == NULL || age >= 30) {           /* (re)build: engine instances come and go */
            if (q != NULL) PdhCloseQuery(q);
            q = NULL; ng = na = 0; age = 0;
            if (PdhOpenQueryW(NULL, 0, &q) == ERROR_SUCCESS) {
                ng = add_wild(q, game_path, cg, 64, NULL);
                na = add_wild(q, L"\\GPU Engine(*engtype_3D)\\Utilization Percentage", ca, 256, cpid);
                PdhCollectQueryData(q);
            }
            Sleep(1000);
        }
        if (q != NULL && PdhCollectQueryData(q) == ERROR_SUCCESS && (ng > 0 || na > 0)) {
            double g = sum_counters(cg, ng), a = 0;
            EnterCriticalSection(&g_cs);
            for (i = 0; i < na; i++) {
                PDH_FMT_COUNTERVALUE v;
                if (PdhGetFormattedCounterValue(ca[i], PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, NULL, &v) == ERROR_SUCCESS && v.CStatus == ERROR_SUCCESS) {
                    a += v.doubleValue;
                    add_pid(cpid[i], v.doubleValue);
                }
            }
            g_gpu_game_sum += g; g_gpu_all_sum += a; g_gpu_n++;
            LeaveCriticalSection(&g_cs);
        }
        age++;
        Sleep(1000);
    }
    return 0;
}

/* ---- report ---- */
static void report(void) {
    static char out[1024];
    LARGE_INTEGER now;
    double secs, fps, tick_ms, gpu_g = -1, gpu_a = -1;
    LONG64 frames, tick_acc, tick_n;
    TT cur[MAXT];
    int ncur = 0, i, j;
    double best[3] = { 0, 0, 0 }; DWORD best_tid[3] = { 0, 0, 0 };
    double game_pct = -1, pres_pct = -1;
    char top[200] = "", nm[48];
    PG pg[MAXP]; int npg = 0, gn = 0;
    HANDLE snap;
    THREADENTRY32 te;
    DWORD pid = GetCurrentProcessId();

    QueryPerformanceCounter(&now);
    secs = g_last_report.QuadPart ? (double)(now.QuadPart - g_last_report.QuadPart) / (double)g_freq.QuadPart : 0;
    frames = g_frames - g_last_frames;
    tick_acc = g_tick_acc - g_last_tick_acc;
    tick_n = g_tick_n - g_last_tick_n;
    fps = secs > 0 ? frames / secs : 0;
    tick_ms = tick_n > 0 ? (double)tick_acc * 1000.0 / (double)g_freq.QuadPart / (double)tick_n : 0;
    EnterCriticalSection(&g_cs);
    if (g_gpu_n > 0) { gpu_g = g_gpu_game_sum / g_gpu_n; gpu_a = g_gpu_all_sum / g_gpu_n; }
    gn = g_gpu_n;
    memcpy(pg, g_pg, sizeof(PG) * g_npg); npg = g_npg; g_npg = 0;
    g_gpu_game_sum = 0; g_gpu_all_sum = 0; g_gpu_n = 0;
    LeaveCriticalSection(&g_cs);
    if (gn > 0) {                                                  /* v2: top 3 other GPU users */
        int k, t;
        for (k = 0; k < 3; k++) {
            int bi = -1;
            for (t = 0; t < npg; t++) if (pg[t].sum > 0 && (bi < 0 || pg[t].sum > pg[bi].sum)) bi = t;
            if (bi < 0 || pg[bi].sum / gn < 0.5) break;
            pid_name(pg[bi].pid, nm, sizeof(nm));
            snprintf(top + strlen(top), sizeof(top) - strlen(top), "%s%s:%.0f", k ? "," : "", nm, pg[bi].sum / gn);
            pg[bi].sum = 0;
        }
    }

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap != INVALID_HANDLE_VALUE) {
        te.dwSize = sizeof(te);
        if (Thread32First(snap, &te)) do {
            if (te.th32OwnerProcessID == pid && ncur < MAXT) { cur[ncur].tid = te.th32ThreadID; cur[ncur].cpu = thread_cpu(te.th32ThreadID); ncur++; }
            te.dwSize = sizeof(te);
        } while (Thread32Next(snap, &te));
        CloseHandle(snap);
    }
    if (secs > 0) {
        for (i = 0; i < ncur; i++) {
            ULONGLONG prev = 0; int found = 0;
            double pct;
            for (j = 0; j < g_ntt; j++) if (g_tt[j].tid == cur[i].tid) { prev = g_tt[j].cpu; found = 1; break; }
            if (!found) continue;
            pct = (double)(cur[i].cpu - prev) / 1e7 / secs * 100.0;
            if (cur[i].tid == g_game_tid) game_pct = pct;
            if (cur[i].tid == g_present_tid) pres_pct = pct;
            if (cur[i].tid == g_game_tid || cur[i].tid == g_present_tid) continue;
            for (j = 0; j < 3; j++) if (pct > best[j]) {
                int k;
                for (k = 2; k > j; k--) { best[k] = best[k - 1]; best_tid[k] = best_tid[k - 1]; }
                best[j] = pct; best_tid[j] = cur[i].tid; break;
            }
        }
    }
    memcpy(g_tt, cur, sizeof(TT) * ncur); g_ntt = ncur;
    g_last_report = now; g_last_frames = g_frames; g_last_tick_acc = g_tick_acc; g_last_tick_n = g_tick_n;
    snprintf(out, sizeof(out),
        "secs=%.1f;fps=%.1f;tick_ms=%.2f;game_cpu=%.0f;present_cpu=%.0f;other_cpu=%.0f,%.0f,%.0f;gpu_game=%.0f;gpu_all=%.0f;threads=%d;gpu_top=%s",
        secs, fps, tick_ms, game_pct, pres_pct, best[0], best[1], best[2], gpu_g, gpu_a, ncur, top[0] ? top : "-");
    if (P && P->functions && P->functions->dispatch_lua_event) P->functions->dispatch_lua_event("sfperf", out);
}

static void on_custom_event(const char* evt, const char* data) {
    if (evt == NULL || data == NULL || strcmp(evt, "sfperf") != 0) return;
    if (strncmp(data, "report", 6) == 0) report();
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    HANDLE th;
    P = param;
    QueryPerformanceFrequency(&g_freq);
    InitializeCriticalSection(&g_cs);
    if (param->callbacks != NULL) {
        if (param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
        if (param->callbacks->on_present != NULL) param->callbacks->on_present(on_present);
    }
    if (param->sdk != NULL && param->sdk->callbacks != NULL) {
        if (param->sdk->callbacks->on_pre_engine_tick != NULL) param->sdk->callbacks->on_pre_engine_tick(on_pre_tick);
        if (param->sdk->callbacks->on_post_engine_tick != NULL) param->sdk->callbacks->on_post_engine_tick(on_post_tick);
    }
    th = CreateThread(NULL, 0, gpu_thread, NULL, 0, NULL);
    if (th != NULL) { SetThreadPriority(th, THREAD_PRIORITY_BELOW_NORMAL); CloseHandle(th); }
    logi("[sf_perf] v4 loaded - measures frame time, game/render thread CPU and GPU use for the Silverfish VR log (read-only)");
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) { (void)inst; (void)reason; (void)reserved; return TRUE; }
