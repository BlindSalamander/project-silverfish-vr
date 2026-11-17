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
 *   - v5 (2026-11-12): how long every VR frame takes ON THE GRAPHICS CARD, from SteamVR's own frame timing
 *     (IVRCompositor::GetFrameTimings - the numbers SteamVR's frame timing graph shows): the game's GPU time per frame,
 *     the compositor's, late/repeated frames and dropped frames. Read on the game thread 4x a second (no new thread).
 *     Written once a second to data\sf_gpu_log.txt (flushed every line, so it survives a crash) and added to the report.
 *     v5.1: a frame that came more than 250 ms after the one before (the game froze, e.g. loading) is counted apart:
 *     SteamVR times such a frame across the freeze, so its "GPU time" is mostly waiting, not graphics work (measured
 *     2026-11-12: 150-1018 ms "GPU frames" while the card was 2-44 % busy). Averages / worst are of normal frames only.
 *   - v5.2 (2026-11-13): RECORDS EVERYTHING for later analysis, buffered in memory and written 4x a second (no file work
 *     per frame): data\sf_ticks.csv = every engine tick (start, tick ms, time since the previous tick), data\sf_vrframes.csv
 *     = every SteamVR frame (all of SteamVR's per-frame timing fields), data\sf_timeline.csv = what the player was doing,
 *     sent by sf_main.lua as custom event "sftl" (poses, buttons, menus, item, level, marks, hitches) plus FREEZE lines
 *     for any engine tick more than 250 ms after the previous one. Every timeline line has the computer's clock; the
 *     other two files carry "#clock" lines every 10 s. Each file stops growing at 400 MB.
 *   - v5.3 (2026-11-14): the report no longer stalls the game. The per-thread CPU sample (a system-wide thread snapshot,
 *     24 ms on a busy PC) moved to the background thread; report() compares two finished samples. SteamVR's function
 *     table is dropped and fetched again when UEVR restarts OpenVR (init token). The DLL pins itself, so UEVR's
 *     "unload / reload plugins" cannot free code the background thread is still running.
 *   - Release 1.0.2: the recordings of v5.2 (sf_ticks.csv, sf_vrframes.csv, sf_timeline.csv) are a development aid and are
 *     NOT in the published build: they are compiled in only with -DSFPERF_RECORD=1. The published plugin writes one file,
 *     data\sf_gpu_log.txt (one line per second, started fresh at every start).
 * Answer: dispatch_lua_event("sfperf", "<text>"). It changes nothing in the game or on the PC.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <pdh.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <stdint.h>
#include <share.h>
#include <time.h>
#include <stdarg.h>
#include <stdlib.h>
#undef EXTERN_C
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-variable"
#include "openvr_capi.h"
#pragma GCC diagnostic pop
typedef struct lua_State lua_State;
#include "uevr/API.h"

#ifndef SFPERF_RECORD
#define SFPERF_RECORD 0                 /* 1 = the v5.2 development recordings (every tick / VR frame / timeline) */
#endif

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
/* v5.3: the thread list + CPU times are sampled on the background thread every 2 s. Until v5.2 report() took a
 * system-wide thread snapshot on the GAME thread: 24 ms on a busy PC, a ~34 ms engine tick at every report (13 Nov
 * session: 122 of 122 reports sat on a 32-45 ms tick). report() now only compares two finished samples. */
typedef struct { TT t[MAXT]; int n; LARGE_INTEGER at; } TS;
static TS g_ts_new;                                         /* newest sample (background thread writes it under g_cs) */
static TS g_ts_rep;                                         /* the sample the last report used (game thread only) */

static void logi(const char* s) { if (P && P->functions && P->functions->log_info) P->functions->log_info("%s", s); }

/* ---- v5: SteamVR frame timing (game thread only) ---- */
typedef void* (*PFN_GGI)(const char*, EVRInitError*);
static struct VR_IVRCompositor_FnTable* COMP = NULL;
static DWORD g_vr_try = 0;
static int g_vr_ok = 0;
static uint32_t g_vr_token = 0;                             /* v5.3: OpenVR's init token when COMP was fetched */
typedef uint32_t (*PFN_TOK)(void);
static uint32_t vr_token(void) {                            /* changes whenever UEVR shuts OpenVR down / starts it again */
    HMODULE h = GetModuleHandleA("openvr_api.dll");
    PFN_TOK f = h ? (PFN_TOK)(void*)GetProcAddress(h, "VR_GetInitToken") : NULL;
    return f ? f() : 0;
}
static uint32_t g_last_idx = 0;
static DWORD g_vr_poll = 0;
typedef struct { int n, nok; double app_sum, app_max, tot_max, comp_sum; int late, dropped, mis; double interval_max; int stalls; double stall_max; } VB;
static VB g_sec, g_rep;                                     /* this second (log file) / since the last report */
static DWORD g_sec_t0 = 0;
static FILE* g_gl = NULL;
static int g_gl_lines = 0, g_gl_tried = 0;
/* ---- v5.2: every engine tick, every SteamVR frame, and the timeline - buffered, written 4x a second ---- */
typedef struct { char* p; size_t n, cap; } SB;
static SB g_tk, g_vf, g_tl;
static FILE *g_ftk = NULL, *g_fvf = NULL, *g_ftl = NULL;
static size_t g_btk = 0, g_bvf = 0, g_btl = 0;
static int g_rec_tried = 0;
static CRITICAL_SECTION g_rcs;
static LARGE_INTEGER g_t0q, g_prev_pre;
static double g_frame_ms = 0.0;
static DWORD g_clock_t = 0;
#define REC_MAX ((size_t)400 * 1024 * 1024)
static double qms(LARGE_INTEGER t) { return (double)(t.QuadPart - g_t0q.QuadPart) * 1000.0 / (double)g_freq.QuadPart; }
static void sb_add(SB* b, const char* s, size_t n) {
    if (b->n + n > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 262144;
        char* q;
        while (nc < b->n + n) nc *= 2;
        if (nc > (size_t)64 * 1024 * 1024) return;                 /* never more than 64 MB waiting in memory */
        q = (char*)realloc(b->p, nc);
        if (q == NULL) return;
        b->p = q; b->cap = nc;
    }
    memcpy(b->p + b->n, s, n); b->n += n;
}
static void sb_printf(SB* b, const char* fmt, ...) {
    char tmp[1100];
    va_list a;
    int n;
    va_start(a, fmt); n = vsnprintf(tmp, sizeof(tmp), fmt, a); va_end(a);
    if (n <= 0) return;
    if (n >= (int)sizeof(tmp)) n = (int)sizeof(tmp) - 1;
    sb_add(b, tmp, (size_t)n);
}
static FILE* rec_open(const wchar_t* dir, const wchar_t* name, const char* head) {
    wchar_t path[MAX_PATH + 64];
    FILE* f;
    swprintf(path, MAX_PATH + 64, L"%ls\\data\\%ls", dir, name);
    f = _wfsopen(path, L"wb", _SH_DENYNO);                       /* fresh every start; readable while open */
    if (f != NULL) { fputs(head, f); fflush(f); }
    return f;
}
static void rec_open_all(void) {
    wchar_t dir[MAX_PATH], d2[MAX_PATH + 16];
    unsigned int n;
    char h[700], d[32] = "?";
    time_t tt = time(NULL);
    struct tm* lt = localtime(&tt);
    if (!SFPERF_RECORD || g_rec_tried) return;
    g_rec_tried = 1;
    if (P == NULL || P->functions == NULL || P->functions->get_persistent_dir == NULL) return;
    n = P->functions->get_persistent_dir(dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    swprintf(d2, MAX_PATH + 16, L"%ls\\data", dir);
    CreateDirectoryW(d2, NULL);
    if (lt) strftime(d, sizeof(d), "%Y-%m-%d %H:%M:%S", lt);
    snprintf(h, sizeof(h), "# Silverfish VR - every engine tick (sf_perf v5.3). Started %s. qpc_ms = ms since the plugin started;\n"
        "# tick_ms = the game's engine tick (game thread work); frame_ms = time since the previous tick started. #clock lines every 10 s.\nqpc_ms,tick_ms,frame_ms\n", d);
    g_ftk = rec_open(dir, L"sf_ticks.csv", h);
    snprintf(h, sizeof(h), "# Silverfish VR - every SteamVR frame, SteamVR's own timing (sf_perf v5.3). Started %s. #clock lines every 10 s.\n"
        "# app = game GPU ms (pre+post submit); total = whole GPU frame; comp = compositor GPU; interval = since the previous game frame;\n"
        "# submit / wait = CPU ms in Submit / WaitGetPoses; presents/mis/dropped as SteamVR counts them; reproj = reprojection flags\n"
        "qpc_ms,frame,sys_s,app_ms,total_ms,comp_ms,interval_ms,submit_ms,wait_ms,presents,mis,dropped,reproj\n", d);
    g_fvf = rec_open(dir, L"sf_vrframes.csv", h);
    snprintf(h, sizeof(h), "# Silverfish VR - what you were doing (sf_perf v5.3 writes it; sf_main.lua sends most lines). Started %s.\n"
        "# kinds: pose (head x y z qx qy qz qw | left x y z | right x y z, metres), pad (buttons as the game sees them), state (menu, screen,\n"
        "# item, level, walking, turning), screen, fire, mark, hitch, FREEZE (engine tick >250 ms after the previous one), note\ntime,qpc_ms,kind,data\n", d);
    g_ftl = rec_open(dir, L"sf_timeline.csv", h);
}
static void rec_write(FILE* f, SB* b, size_t* total) {
    if (f != NULL && b->n > 0 && *total < REC_MAX) { fwrite(b->p, 1, b->n, f); fflush(f); *total += b->n; }
    b->n = 0;
}
static void rec_flush(void) {
    LARGE_INTEGER now;
    DWORD t = GetTickCount();
    if (!SFPERF_RECORD) return;
    rec_open_all();
    QueryPerformanceCounter(&now);
    EnterCriticalSection(&g_rcs);
    if (t - g_clock_t >= 10000) {
        SYSTEMTIME st;
        g_clock_t = t;
        GetLocalTime(&st);
        sb_printf(&g_tk, "#clock %02d:%02d:%02d.%03d = qpc_ms %.1f\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, qms(now));
        sb_printf(&g_vf, "#clock %02d:%02d:%02d.%03d = qpc_ms %.1f\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, qms(now));
    }
    rec_write(g_ftk, &g_tk, &g_btk);
    rec_write(g_fvf, &g_vf, &g_bvf);
    rec_write(g_ftl, &g_tl, &g_btl);
    LeaveCriticalSection(&g_rcs);
}
static void tl_line(const char* kind, const char* data) {
    char clean[920];
    size_t i;
    SYSTEMTIME st;
    LARGE_INTEGER now;
    if (!SFPERF_RECORD) return;
    for (i = 0; data[i] != 0 && i < sizeof(clean) - 1; i++) clean[i] = (data[i] == '\n' || data[i] == '\r') ? ' ' : data[i];
    clean[i] = 0;
    GetLocalTime(&st);
    QueryPerformanceCounter(&now);
    EnterCriticalSection(&g_rcs);
    sb_printf(&g_tl, "%02d:%02d:%02d.%03d,%.1f,%s,%s\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, qms(now), kind, clean);
    LeaveCriticalSection(&g_rcs);
}
static void vb_add(VB* b, const struct Compositor_FrameTiming* t) {
    double app = (double)t->m_flPreSubmitGpuMs + (double)t->m_flPostSubmitGpuMs;
    b->n++;
    if (t->m_flClientFrameIntervalMs > 250.0f) {               /* v5.1: stretched by a freeze - kept apart */
        b->stalls++;
        if (app > b->stall_max) b->stall_max = app;
    } else {
        b->nok++;
        b->app_sum += app;
        if (app > b->app_max) b->app_max = app;
        if (t->m_flTotalRenderGpuMs > b->tot_max) b->tot_max = t->m_flTotalRenderGpuMs;
        b->comp_sum += t->m_flCompositorRenderGpuMs;
    }
    if (t->m_nNumFramePresents > 1) b->late += (int)(t->m_nNumFramePresents - 1);
    b->dropped += (int)t->m_nNumDroppedFrames;
    b->mis += (int)t->m_nNumMisPresented;
    if (t->m_flClientFrameIntervalMs > b->interval_max) b->interval_max = t->m_flClientFrameIntervalMs;
}
static void vr_init(void) {
    HMODULE h;
    PFN_GGI ggi;
    EVRInitError e = EVRInitError_VRInitError_None;
    char name[96];
    if (g_vr_ok || GetTickCount() - g_vr_try < 5000) return;      /* OpenVR may come up after the plugin: retry every 5 s */
    g_vr_try = GetTickCount();
    h = GetModuleHandleA("openvr_api.dll");
    if (h == NULL) return;
    ggi = (PFN_GGI)(void*)GetProcAddress(h, "VR_GetGenericInterface");
    if (ggi == NULL) return;
    snprintf(name, sizeof(name), "FnTable:%s", IVRCompositor_Version);
    COMP = (struct VR_IVRCompositor_FnTable*)ggi(name, &e);
    if (COMP == NULL || e != EVRInitError_VRInitError_None || COMP->GetFrameTimings == NULL) { COMP = NULL; return; }
    g_vr_token = vr_token();
    g_vr_ok = 1;
    logi("[sf_perf] SteamVR frame timing available - graphics card time per frame goes to data\\sf_gpu_log.txt");
}
static void gl_open(void) {
    wchar_t dir[MAX_PATH], path[MAX_PATH + 64];
    unsigned int n;
    if (g_gl_tried) return;
    g_gl_tried = 1;
    if (P == NULL || P->functions == NULL || P->functions->get_persistent_dir == NULL) return;
    n = P->functions->get_persistent_dir(dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    swprintf(path, MAX_PATH + 64, L"%ls\\data", dir);
    CreateDirectoryW(path, NULL);
    swprintf(path, MAX_PATH + 64, L"%ls\\data\\sf_gpu_log.txt", dir);
    g_gl = _wfsopen(path, L"w", _SH_DENYNO);                 /* fresh every start; others may read it while open */
    if (g_gl != NULL) {
        time_t tt = time(NULL);
        struct tm* lt = localtime(&tt);
        char d[32] = "?";
        if (lt) strftime(d, sizeof(d), "%Y-%m-%d %H:%M:%S", lt);
        fprintf(g_gl, "# Silverfish VR - graphics card time per VR frame, from SteamVR (sf_perf v5.3). Started %s. One line per second.\n", d);
        fprintf(g_gl, "# frames = game frames SteamVR got that second; app = game GPU ms per frame (avg / worst); total = whole GPU frame incl. SteamVR, worst;\n");
        fprintf(g_gl, "# comp = SteamVR compositor GPU ms avg; late = extra times an old frame was shown; dropped = frames SteamVR had to repeat; interval = worst gap between game frames (ms)\n");
        fprintf(g_gl, "# stalls = frames that came >250 ms after the previous one (game froze); their timing is mostly the freeze, so they are left out of app/total and shown as stall_ms (worst)\n");
        fprintf(g_gl, "time,frames,app_avg_ms,app_worst_ms,total_worst_ms,comp_avg_ms,late,dropped,mispresented,interval_worst_ms,stalls,stall_ms\n");
        fflush(g_gl);
    }
}
static void vr_poll(void) {
    static struct Compositor_FrameTiming ft[128];
    uint32_t got, i, k;
    DWORD now = GetTickCount();
    if (now - g_vr_poll < 250) return;
    g_vr_poll = now;
    rec_flush();                                            /* v5.2 */
    /* v5.3: UEVR can shut OpenVR down and start it again mid-session (headset re-entry, a slow input update, its
     * "Reinitialize Runtime" button; seen twice at start-up on 10 Nov). The function table then belongs to an unloaded
     * vrclient - calling through it is a crash waiting to happen. The init token changes on every shutdown / init. */
    if (g_vr_ok && vr_token() != g_vr_token) {
        COMP = NULL; g_vr_ok = 0; g_vr_try = now; g_last_idx = 0;
        logi("[sf_perf] SteamVR was restarted by UEVR - frame timing reconnects in a few seconds");
    }
    vr_init();
    if (!g_vr_ok) return;
    memset(ft, 0, sizeof(ft));
    for (i = 0; i < 128; i++) ft[i].m_nSize = sizeof(struct Compositor_FrameTiming);
    got = COMP->GetFrameTimings(ft, 128);
    if (got > 128) got = 128;
    if (got == 0) return;
    {   /* where we are: first poll, or SteamVR restarted (frame numbers started again) -> only remember the newest */
        uint32_t mx = 0;
        for (i = 0; i < got; i++) if (ft[i].m_nFrameIndex > mx) mx = ft[i].m_nFrameIndex;
        if (g_last_idx == 0 || mx < g_last_idx) { g_last_idx = mx; return; }
    }
    /* oldest first (taken in frame-number order, whatever order SteamVR hands them over in) */
    for (k = 0; k < got; k++) {
        uint32_t best = 0xFFFFFFFFu, bi = 0xFFFFFFFFu;
        for (i = 0; i < got; i++) if (ft[i].m_nFrameIndex > g_last_idx && ft[i].m_nFrameIndex < best) { best = ft[i].m_nFrameIndex; bi = i; }
        if (bi == 0xFFFFFFFFu) break;
        g_last_idx = best;
        EnterCriticalSection(&g_cs);
        vb_add(&g_rep, &ft[bi]);
        LeaveCriticalSection(&g_cs);
        vb_add(&g_sec, &ft[bi]);
        if (SFPERF_RECORD) {   /* v5.2: every frame */
            LARGE_INTEGER q;
            const struct Compositor_FrameTiming* f = &ft[bi];
            QueryPerformanceCounter(&q);
            EnterCriticalSection(&g_rcs);
            sb_printf(&g_vf, "%.1f,%u,%.4f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%u,%u,%u,0x%x\n", qms(q), f->m_nFrameIndex, f->m_flSystemTimeInSeconds,
                (double)f->m_flPreSubmitGpuMs + (double)f->m_flPostSubmitGpuMs, (double)f->m_flTotalRenderGpuMs, (double)f->m_flCompositorRenderGpuMs,
                (double)f->m_flClientFrameIntervalMs, (double)f->m_flSubmitFrameMs, (double)f->m_flWaitGetPosesCalledMs, f->m_nNumFramePresents,
                f->m_nNumMisPresented, f->m_nNumDroppedFrames, f->m_nReprojectionFlags);
            LeaveCriticalSection(&g_rcs);
        }
    }
    if (g_sec_t0 == 0) g_sec_t0 = now;
    if (now - g_sec_t0 >= 1000) {
        g_sec_t0 = now;
        gl_open();
        if (g_gl != NULL && g_gl_lines < 50000) {
            SYSTEMTIME st;
            GetLocalTime(&st);
            fprintf(g_gl, "%02d:%02d:%02d.%03d,%d,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%.0f,%d,%.0f\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                g_sec.n, g_sec.nok ? g_sec.app_sum / g_sec.nok : 0.0, g_sec.app_max, g_sec.tot_max, g_sec.nok ? g_sec.comp_sum / g_sec.nok : 0.0,
                g_sec.late, g_sec.dropped, g_sec.mis, g_sec.interval_max, g_sec.stalls, g_sec.stall_max);
            fflush(g_gl);
            g_gl_lines++;
        }
        memset(&g_sec, 0, sizeof(g_sec));
    }
}


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
    g_frame_ms = g_prev_pre.QuadPart ? (double)(g_tick_t0.QuadPart - g_prev_pre.QuadPart) * 1000.0 / (double)g_freq.QuadPart : 0.0;   /* v5.2 */
    g_prev_pre = g_tick_t0;
}
static void on_post_tick(UEVR_UGameEngineHandle engine, float delta) {
    LARGE_INTEGER t;
    (void)engine; (void)delta;
    if (g_tick_t0.QuadPart == 0) return;
    QueryPerformanceCounter(&t);
    InterlockedAdd64(&g_tick_acc, t.QuadPart - g_tick_t0.QuadPart);
    InterlockedIncrement64(&g_tick_n);
    if (SFPERF_RECORD) {                                        /* v5.2: every tick */
        EnterCriticalSection(&g_rcs);
        sb_printf(&g_tk, "%.2f,%.3f,%.2f\n", qms(g_tick_t0), (double)(t.QuadPart - g_tick_t0.QuadPart) * 1000.0 / (double)g_freq.QuadPart, g_frame_ms);
        LeaveCriticalSection(&g_rcs);
        if (g_frame_ms > 250.0) { char m[64]; snprintf(m, sizeof(m), "%.0f ms", g_frame_ms); tl_line("FREEZE", m); }
    }
    g_tick_t0.QuadPart = 0;
    vr_poll();                                              /* v5: after the tick is measured */
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
        static struct { DWORD pid; char nm[48]; } cache[64];    /* looked up once per program (game thread only) */
        static int ncache = 0;
        HANDLE snap;
        PROCESSENTRY32W pe;
        int i;
        for (i = 0; i < ncache; i++) if (cache[i].pid == pid) { snprintf(out, n, "%s", cache[i].nm); return; }
        if (ncache >= 64) return;                               /* v5.3: cache full - "pidNNNN" stays, no 3 ms snapshot per report */
        snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return;
        pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) do {
            if (pe.th32ProcessID == pid) { put_name(pe.szExeFile, out, n); break; }
            pe.dwSize = sizeof(pe);
        } while (Process32NextW(snap, &pe));
        CloseHandle(snap);
        cache[ncache].pid = pid; snprintf(cache[ncache].nm, sizeof(cache[ncache].nm), "%s", out); ncache++;
    }
}

static void threads_sample(void) {                           /* v5.3: background thread only */
    static TS s;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te;
    DWORD pid = GetCurrentProcessId();
    if (snap == INVALID_HANDLE_VALUE) return;
    s.n = 0;
    te.dwSize = sizeof(te);
    if (Thread32First(snap, &te)) do {
        if (te.th32OwnerProcessID == pid && s.n < MAXT) { s.t[s.n].tid = te.th32ThreadID; s.t[s.n].cpu = thread_cpu(te.th32ThreadID); s.n++; }
        te.dwSize = sizeof(te);
    } while (Thread32Next(snap, &te));
    CloseHandle(snap);
    QueryPerformanceCounter(&s.at);
    EnterCriticalSection(&g_cs);
    g_ts_new = s;
    LeaveCriticalSection(&g_cs);
}

static DWORD WINAPI gpu_thread(LPVOID arg) {
    wchar_t game_path[128];
    PDH_HQUERY q = NULL;
    PDH_HCOUNTER cg[64], ca[256];
    DWORD cpid[256];
    int ng = 0, na = 0, age = 0, i;
    DWORD ts_t = 0;
    (void)arg;
    swprintf(game_path, 128, L"\\GPU Engine(pid_%lu_*engtype_3D)\\Utilization Percentage", (unsigned long)GetCurrentProcessId());
    for (;;) {
        if (ts_t == 0 || GetTickCount() - ts_t >= 2000) { ts_t = GetTickCount(); threads_sample(); }   /* v5.3 */
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
    static char out[1200];
    LARGE_INTEGER now;
    double secs, fps, tick_ms, gpu_g = -1, gpu_a = -1;
    LONG64 frames, tick_acc, tick_n;
    static TS cur;                                             /* game thread only */
    int ncur = 0, i, j;
    double best[3] = { 0, 0, 0 }; DWORD best_tid[3] = { 0, 0, 0 };
    double game_pct = -1, pres_pct = -1, tsecs;
    char top[200] = "", nm[48], vrs[260] = "vr_frames=0";
    VB vb;
    PG pg[MAXP]; int npg = 0, gn = 0;

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
    vb = g_rep; memset(&g_rep, 0, sizeof(g_rep));           /* v5 */
    LeaveCriticalSection(&g_cs);
    if (vb.n > 0) snprintf(vrs, sizeof(vrs), "vr_frames=%d;app_gpu=%.1f;app_gpu_max=%.1f;total_gpu_max=%.1f;comp_gpu=%.1f;late=%d;dropped=%d;interval_max=%.0f;stalls=%d;stall_max=%.0f",
        vb.n, vb.nok ? vb.app_sum / vb.nok : 0.0, vb.app_max, vb.tot_max, vb.nok ? vb.comp_sum / vb.nok : 0.0, vb.late, vb.dropped, vb.interval_max, vb.stalls, vb.stall_max);
    else if (!g_vr_ok) snprintf(vrs, sizeof(vrs), "vr_frames=-1");
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

    /* v5.3: the newest background sample against the one the last report used (no snapshot on the game thread) */
    EnterCriticalSection(&g_cs);
    cur = g_ts_new;
    LeaveCriticalSection(&g_cs);
    ncur = cur.n;
    tsecs = (g_ts_rep.n > 0 && cur.n > 0) ? (double)(cur.at.QuadPart - g_ts_rep.at.QuadPart) / (double)g_freq.QuadPart : 0;
    if (tsecs >= 1.0) {
        for (i = 0; i < cur.n; i++) {
            ULONGLONG prev = 0; int found = 0;
            double pct;
            for (j = 0; j < g_ts_rep.n; j++) if (g_ts_rep.t[j].tid == cur.t[i].tid) { prev = g_ts_rep.t[j].cpu; found = 1; break; }
            if (!found) continue;
            pct = (double)(cur.t[i].cpu - prev) / 1e7 / tsecs * 100.0;
            if (cur.t[i].tid == g_game_tid) game_pct = pct;
            if (cur.t[i].tid == g_present_tid) pres_pct = pct;
            if (cur.t[i].tid == g_game_tid || cur.t[i].tid == g_present_tid) continue;
            for (j = 0; j < 3; j++) if (pct > best[j]) {
                int k;
                for (k = 2; k > j; k--) { best[k] = best[k - 1]; best_tid[k] = best_tid[k - 1]; }
                best[j] = pct; best_tid[j] = cur.t[i].tid; break;
            }
        }
        g_ts_rep = cur;
    } else if (g_ts_rep.n == 0 && cur.n > 0) {
        g_ts_rep = cur;                                        /* the first report: the starting point */
    }
    g_last_report = now; g_last_frames = g_frames; g_last_tick_acc = g_tick_acc; g_last_tick_n = g_tick_n;
    snprintf(out, sizeof(out),
        "secs=%.1f;fps=%.1f;tick_ms=%.2f;game_cpu=%.0f;present_cpu=%.0f;other_cpu=%.0f,%.0f,%.0f;gpu_game=%.0f;gpu_all=%.0f;threads=%d;gpu_top=%s;%s",
        secs, fps, tick_ms, game_pct, pres_pct, best[0], best[1], best[2], gpu_g, gpu_a, ncur, top[0] ? top : "-", vrs);
    if (P && P->functions && P->functions->dispatch_lua_event) P->functions->dispatch_lua_event("sfperf", out);
}

static void on_custom_event(const char* evt, const char* data) {
    if (evt == NULL || data == NULL) return;
    if (strcmp(evt, "sftl") == 0) {                         /* v5.2: "kind,data" from sf_main.lua */
        char kind[24];
        const char* c = strchr(data, ',');
        size_t k = c ? (size_t)(c - data) : strlen(data);
        if (k >= sizeof(kind)) k = sizeof(kind) - 1;
        memcpy(kind, data, k); kind[k] = 0;
        tl_line(kind, c ? c + 1 : "");
        return;
    }
    if (strcmp(evt, "sfperf") != 0) return;
    if (strncmp(data, "report", 6) == 0) report();
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    HANDLE th;
    static int once = 0;                                    /* v5.3: UEVR's "reload plugins" calls this again */
    P = param;
    if (!once) {
        HMODULE self;
        QueryPerformanceFrequency(&g_freq);
        QueryPerformanceCounter(&g_t0q);                    /* v5.2 */
        InitializeCriticalSection(&g_cs);
        InitializeCriticalSection(&g_rcs);
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCWSTR)(void*)&uevr_plugin_initialize, &self);
    }
    if (param->callbacks != NULL) {
        if (param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
        if (param->callbacks->on_present != NULL) param->callbacks->on_present(on_present);
    }
    if (param->sdk != NULL && param->sdk->callbacks != NULL) {
        if (param->sdk->callbacks->on_pre_engine_tick != NULL) param->sdk->callbacks->on_pre_engine_tick(on_pre_tick);
        if (param->sdk->callbacks->on_post_engine_tick != NULL) param->sdk->callbacks->on_post_engine_tick(on_post_tick);
    }
    if (!once) {
        once = 1;
        th = CreateThread(NULL, 0, gpu_thread, NULL, 0, NULL);
        if (th != NULL) { SetThreadPriority(th, THREAD_PRIORITY_BELOW_NORMAL); CloseHandle(th); }
    }
    logi(SFPERF_RECORD ? "[sf_perf] v5.3 loaded - measures frame time, game/render thread CPU, GPU use and SteamVR's GPU time per frame, and records every tick, every VR frame and the timeline in data (reads the game, changes nothing in it)"
                   : "[sf_perf] v5.3 loaded - measures frame time, game/render thread CPU, GPU use and SteamVR's GPU time per frame (reads the game, changes nothing in it)");
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) { (void)inst; (void)reason; (void)reserved; return TRUE; }
