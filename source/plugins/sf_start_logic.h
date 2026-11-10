/*
 * sf_start_logic.h - the two text fixes of sf_start.dll, in plain C with no Windows calls, so that the same code is
 * run by the test program (sf_start_test.c, any platform) and by the plugin.
 */
#ifndef SF_START_LOGIC_H
#define SF_START_LOGIC_H
#include <string.h>

/* ---- 1. config.txt: the start settings this profile needs -------------------------------------------------------- */
typedef struct { const char* key; const char* value; } SfWant;
static const SfWant SF_WANT[] = {
    { "VR_AimMethod", "2" },                              /* not "Game" at start: see sf_start.c */
    { "VR_2DScreenMode", "false" },                       /* never start on the flat screen */
    { "VR_DPadShifting", "false" },                       /* the Frame layout re-uses the thumbrest actions for the bumpers */
    { "VR_GhostingFix", "false" },                        /* crashes after level loads with it on (UEVR issues 18 / 235) */
    { "FrameworkConfig_L3R3LongPress", "true" },          /* UEVR's menu = HOLD both stick clicks; a short press is sprint / crouch */
    { "VR_MotionControlsInactivityTimer", "100.000000" }, /* controllers stay "active" while you stand still */
    { "VR_Compatibility_AHUD", "true" },                  /* the game's canvas-drawn UI reaches the VR overlay */
};
#define SF_NWANT ((int)(sizeof(SF_WANT) / sizeof(SF_WANT[0])))

/* Copies the text of config.txt from in[0..n) to out, with every wanted line set to its value; wanted lines that are
 * missing are added at the end. Line endings are kept as they are. Returns the new length, or -1 if out is too small.
 * *changed = how many lines were changed or added (0 = the file is already right, nothing needs writing). */
static int sf_fix_config(const char* in, int n, char* out, int max, int* changed) {
    int seen[SF_NWANT];
    int i = 0, o = 0, k, crlf = 0, last_has_eol = 1;
    *changed = 0;
    for (k = 0; k < SF_NWANT; k++) seen[k] = 0;
    while (i < n) {
        int ls = i, le, eol, eq = -1, j, hit = -1;
        while (i < n && in[i] != '\n') i++;
        le = i;                                            /* line is in[ls..le), then "\n" if i < n */
        eol = (i < n) ? 1 : 0;
        if (eol) i++;
        last_has_eol = eol;
        if (le > ls && in[le - 1] == '\r') { le--; if (eol) crlf = 1; }
        for (j = ls; j < le; j++) if (in[j] == '=') { eq = j; break; }
        if (eq > ls) {
            for (k = 0; k < SF_NWANT; k++) {
                int kl = (int)strlen(SF_WANT[k].key);
                if (eq - ls == kl && memcmp(in + ls, SF_WANT[k].key, (size_t)kl) == 0) { hit = k; break; }
            }
        }
        if (hit >= 0 && !seen[hit]) {
            int vl = (int)strlen(SF_WANT[hit].value);
            int kl = (int)strlen(SF_WANT[hit].key);
            seen[hit] = 1;
            if (le - (eq + 1) == vl && memcmp(in + eq + 1, SF_WANT[hit].value, (size_t)vl) == 0) {
                if (o + (i - ls) > max) return -1;
                memcpy(out + o, in + ls, (size_t)(i - ls)); o += i - ls;      /* already right: copied as it is */
            } else {
                int tail = i - le;                                            /* its own line ending, kept */
                if (o + kl + 1 + vl + tail > max) return -1;
                memcpy(out + o, SF_WANT[hit].key, (size_t)kl); o += kl;
                out[o++] = '=';
                memcpy(out + o, SF_WANT[hit].value, (size_t)vl); o += vl;
                memcpy(out + o, in + le, (size_t)tail); o += tail;
                (*changed)++;
            }
        } else {
            if (o + (i - ls) > max) return -1;
            memcpy(out + o, in + ls, (size_t)(i - ls)); o += i - ls;          /* any other line: untouched */
        }
    }
    for (k = 0; k < SF_NWANT; k++) if (!seen[k]) {
        int kl = (int)strlen(SF_WANT[k].key), vl = (int)strlen(SF_WANT[k].value);
        if (o + kl + vl + 6 > max) return -1;
        if (o > 0 && !last_has_eol) { if (crlf) out[o++] = '\r'; out[o++] = '\n'; }
        memcpy(out + o, SF_WANT[k].key, (size_t)kl); o += kl;
        out[o++] = '=';
        memcpy(out + o, SF_WANT[k].value, (size_t)vl); o += vl;
        if (crlf) out[o++] = '\r';
        out[o++] = '\n';
        last_has_eol = 1;
        (*changed)++;
    }
    return o;
}

/* ---- 2. actions.json: the Steam Frame layout in SteamVR's list of default layouts --------------------------------- */
static const char SF_FRAME_FILE[] = "bindings_frame_controller.json";

static int sf_find(const char* in, int n, const char* what, int from) {   /* first place of "what" at or after from, or -1 */
    int wl = (int)strlen(what), i;
    for (i = from; i + wl <= n; i++) if (in[i] == what[0] && memcmp(in + i, what, (size_t)wl) == 0) return i;
    return -1;
}

/* Returns 0 if the text already names the Frame layout (nothing to do); 1 if out now holds the text with the entry
 * added as the first of "default_bindings" (*outlen = its length); -1 if the text has no such list or out is too small
 * (the caller then writes the complete file it carries). */
static int sf_fix_actions(const char* in, int n, char* out, int max, int* outlen) {
    static const char ENTRY[] =
        "\n    {\n      \"controller_type\": \"frame_controller\",\n      \"binding_url\": \"bindings_frame_controller.json\"\n    }";
    int el = (int)(sizeof(ENTRY) - 1), p, b, q, empty, o = 0;
    *outlen = 0;
    if (sf_find(in, n, SF_FRAME_FILE, 0) >= 0) return 0;
    p = sf_find(in, n, "\"default_bindings\"", 0);
    if (p < 0) return -1;
    b = p;
    while (b < n && in[b] != '[') { if (in[b] == '{' || in[b] == '}' || in[b] == ']') return -1; b++; }
    if (b >= n) return -1;
    q = b + 1;
    while (q < n && (in[q] == ' ' || in[q] == '\t' || in[q] == '\r' || in[q] == '\n')) q++;
    if (q >= n) return -1;
    empty = (in[q] == ']');
    if (n + el + 8 > max) return -1;
    memcpy(out + o, in, (size_t)(b + 1)); o += b + 1;                /* ... "default_bindings": [ */
    memcpy(out + o, ENTRY, (size_t)el); o += el;
    if (empty) { out[o++] = '\n'; out[o++] = ' '; out[o++] = ' '; }  /* [ {entry} ] */
    else out[o++] = ',';                                             /* [ {entry}, {the ones UEVR wrote} ... */
    memcpy(out + o, in + b + 1, (size_t)(n - b - 1)); o += n - b - 1;
    *outlen = o;
    return 1;
}
#endif
