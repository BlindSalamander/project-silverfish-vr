/* test program for sf_start_logic.h (plain C, runs anywhere):  cc -o t sf_start_test.c && ./t <config.txt> <stock actions.json> <profile actions.json> */
#include <stdio.h>
#include <stdlib.h>
#include "sf_start_logic.h"
#include "sf_start_actions.h"
static char in[70000], out[70000], out2[70000];
static int slurp(const char* p, char* b, int max) { FILE* f = fopen(p, "rb"); int n; if (!f) return -1; n = (int)fread(b, 1, max, f); fclose(f); return n; }
static int fails = 0;
static void ok(int cond, const char* what) { printf("%s  %s\n", cond ? "ok  " : "FAIL", what); if (!cond) fails++; }
static int has(const char* b, int n, const char* w) { return sf_find(b, n, w, 0) >= 0; }
static int count(const char* b, int n, const char* w) { int c = 0, p = 0; while ((p = sf_find(b, n, w, p)) >= 0) { c++; p++; } return c; }
int main(int argc, char** argv) {
    int n, m, m2, ch, r, i;
    /* --- config --- */
    n = slurp(argv[1], in, 65536);
    printf("config.txt: %d bytes\n", n);
    m = sf_fix_config(in, n, out, sizeof(out), &ch);
    printf("  as it is on the PC now: %d line(s) changed, %d -> %d bytes\n", ch, n, m);
    ok(has(out, m, "\r\nVR_AimMethod=2\r\n"), "VR_AimMethod is 2, with its CRLF line ending");
    ok(!has(out, m, "VR_AimMethod=0"), "no VR_AimMethod=0 left");
    ok(count(out, m, "\n") == count(in, n, "\n"), "same number of lines");
    ok(count(out, m, "\r\n") == count(out, m, "\n"), "every line still ends CRLF");
    { int same = 0, a = 0, b = 0;   /* every other line byte-identical */
      while (a < n && b < m) { int ea = a, eb = b; while (ea < n && in[ea] != '\n') ea++; while (eb < m && out[eb] != '\n') eb++;
        if (ea - a == eb - b && memcmp(in + a, out + b, ea - a) == 0) same++; a = ea + 1; b = eb + 1; }
      printf("  lines byte-identical to before: %d of %d\n", same, count(in, n, "\n")); ok(same == count(in, n, "\n") - ch, "only the changed lines differ"); }
    m2 = sf_fix_config(out, m, out2, sizeof(out2), &ch);
    ok(ch == 0 && m2 == m && memcmp(out, out2, m) == 0, "second run: nothing to change, text identical");
    /* all seven wrong */
    { const char* bad = "A=1\r\nVR_AimMethod=0\r\nVR_2DScreenMode=true\r\nVR_DPadShifting=true\r\nVR_GhostingFix=true\r\nFrameworkConfig_L3R3LongPress=false\r\nVR_MotionControlsInactivityTimer=30.000000\r\nVR_Compatibility_AHUD=false\r\nZ=9\r\n";
      m = sf_fix_config(bad, (int)strlen(bad), out, sizeof(out), &ch); out[m] = 0;
      ok(ch == 7, "all seven wrong -> seven changed");
      ok(strcmp(out, "A=1\r\nVR_AimMethod=2\r\nVR_2DScreenMode=false\r\nVR_DPadShifting=false\r\nVR_GhostingFix=false\r\nFrameworkConfig_L3R3LongPress=true\r\nVR_MotionControlsInactivityTimer=100.000000\r\nVR_Compatibility_AHUD=true\r\nZ=9\r\n") == 0, "...and the text is exactly as expected"); }
    /* keys missing, LF file, no newline at the end */
    { const char* part = "VR_AimMethod=0\nOther=5";
      m = sf_fix_config(part, (int)strlen(part), out, sizeof(out), &ch); out[m] = 0;
      ok(ch == 7 && has(out, m, "VR_AimMethod=2\nOther=5\nVR_2DScreenMode=false\n") && !has(out, m, "\r"), "LF file without a last newline: one changed, six added, LF kept");
      m2 = sf_fix_config(out, m, out2, sizeof(out2), &ch); ok(ch == 0, "...and stable on the second run"); }
    { const char* tricky = "VR_AimMethodX=0\r\nXVR_AimMethod=0\r\nVR_AimMethod =0\r\n=5\r\n\r\nVR_AimMethod=1\r\nVR_AimMethod=0\r\n";
      m = sf_fix_config(tricky, (int)strlen(tricky), out, sizeof(out), &ch); out[m] = 0;
      ok(has(out, m, "VR_AimMethodX=0\r\nXVR_AimMethod=0\r\nVR_AimMethod =0\r\n=5\r\n\r\nVR_AimMethod=2\r\nVR_AimMethod=0\r\n"), "look-alike keys untouched; only the first real one is set"); }
    m = sf_fix_config("", 0, out, sizeof(out), &ch); ok(ch == 7 && m > 0, "empty text: the seven lines are written");
    m = sf_fix_config(in, n, out, 10, &ch); ok(m == -1, "output too small -> refused, nothing written past the end");
    /* aim method 1, 2, 3 at start: is a non-Game value other than 2 forced to 2? (yes - by design, the tested value) */
    /* --- actions --- */
    n = slurp(argv[2], in, 65536);
    printf("UEVR's own actions.json: %d bytes\n", n);
    r = sf_fix_actions(in, n, out, sizeof(out), &m);
    ok(r == 1, "UEVR's own file: Frame entry added");
    { FILE* f = fopen("patched_stock_actions.json", "wb"); fwrite(out, 1, m, f); fclose(f); }
    r = sf_fix_actions(out, m, out2, sizeof(out2), &m2); ok(r == 0, "...second run: already there");
    n = slurp(argv[3], in, 65536);
    r = sf_fix_actions(in, n, out, sizeof(out), &m); ok(r == 0, "the profile's own actions.json: already there, untouched");
    ok((int)sizeof(SF_ACTIONS_JSON) - 1 == n && memcmp(SF_ACTIONS_JSON, in, n) == 0, "the copy carried inside the plugin is byte-identical to the profile's actions.json");
    { const char* e = "{ \"default_bindings\": [ ] }"; r = sf_fix_actions(e, (int)strlen(e), out, sizeof(out), &m); out[m] = 0; ok(r == 1, "empty list: entry added without a stray comma"); { FILE* f = fopen("patched_empty.json", "wb"); fwrite(out, 1, m, f); fclose(f); } }
    { const char* e = "{ \"actions\": [] }"; r = sf_fix_actions(e, (int)strlen(e), out, sizeof(out), &m); ok(r == -1, "no list at all: reported, caller writes the carried file"); }
    { const char* e = "{ \"default_bindings\": { } }"; r = sf_fix_actions(e, (int)strlen(e), out, sizeof(out), &m); ok(r == -1, "list is not a list: reported"); }
    { const char* e = "{ \"default_bindings\""; r = sf_fix_actions(e, (int)strlen(e), out, sizeof(out), &m); ok(r == -1, "cut-off file: reported"); }
    r = sf_fix_actions("", 0, out, sizeof(out), &m); ok(r == -1, "empty file: reported");
    for (i = 0; i < 2000; i++) {   /* random cuts of the real files must never crash or overrun */
        int cut = (i * 7919) % (n + 1); sf_fix_actions(in, cut, out, sizeof(out), &m); sf_fix_config(in, cut, out, sizeof(out), &ch);
    }
    ok(1, "2000 cut-off inputs: no crash");
    printf(fails ? "FAILED: %d\n" : "all passed\n", fails);
    return fails;
}
