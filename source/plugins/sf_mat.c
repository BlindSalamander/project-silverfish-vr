/*
 * sf_mat.dll - READ-ONLY UEVR plugin for Project Silverfish VR (2026-11-09), v1 (mod v6.6.37)
 *
 * Why: UEVR's Lua cannot read arrays of structs. The sights place their crosshair through values in their post-process
 * material (MaterialInstanceDynamic.ScalarParameterValues / VectorParameterValues) and possibly a material parameter
 * collection (its ScalarParameters / VectorParameters lists carry the names). To find the value that kicks on a shot,
 * the script needs those arrays, frame by frame. This plugin reads ANY array-of-structs (or of objects) property of an
 * object by name, including the fields of structs nested one level down (FMaterialParameterInfo.Name, FLinearColor.R..).
 * It never writes anything and never calls game functions.
 *
 * Driven only by sf_main.lua:
 *     uevr.api:dispatch_custom_event("sfmat", "read <object address hex> <Prop>[,<Prop>...]")
 * -> answers right away (same thread) with dispatch_lua_event("sfmat", "<text>"):
 *     one line per array: <Prop>;n=<count>;sz=<struct size>;f=<field>:<type>@<off>,...;0=<v>|<v>|...;1=...
 *     nested struct fields appear as Outer.Inner (e.g. ParameterInfo.Name, ParameterValue.R).
 * Safety: objects are checked with UEVR's object table, every memory range with VirtualQuery; counts / sizes / offsets
 * are bounded; anything unexpected ends that line with err=.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <stdint.h>
typedef struct lua_State lua_State;
#include "uevr/API.h"

static const UEVR_PluginInitializeParam* P = NULL;
static const UEVR_SDKData* SDK = NULL;
static int g_logged = 0;

static void logi(const char* s) {
    if (P && P->functions && P->functions->log_info) P->functions->log_info("%s", s);
}

static int readable(const void* p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    const char* a = (const char*)p;
    const char* end = a + n;
    if (p == NULL || n == 0 || n > (1u << 20)) return 0;
    while (a < end) {
        if (VirtualQuery(a, &mbi, sizeof(mbi)) == 0) return 0;
        if (mbi.State != MEM_COMMIT) return 0;
        if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
        if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                             PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return 0;
        a = (const char*)mbi.BaseAddress + mbi.RegionSize;
    }
    return 1;
}

static void fname_str(UEVR_FNameHandle fn, char* out, int outsz) {
    wchar_t w[256];
    unsigned int n;
    int i;
    out[0] = 0;
    if (fn == NULL || SDK->fname == NULL || SDK->fname->to_string == NULL) return;
    if (!readable(fn, 8)) return;
    n = SDK->fname->to_string(fn, w, 255);
    if (n > 255) n = 255;
    w[n] = 0;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, out, outsz, NULL, NULL);
    out[outsz - 1] = 0;
    for (i = 0; out[i]; i++) if (out[i] == '|' || out[i] == ';' || out[i] == '=' || out[i] == ',' || out[i] == '\n') out[i] = '_';
}

static void field_class(UEVR_FFieldHandle f, char* out, int outsz) {
    UEVR_FFieldClassHandle c = SDK->ffield->get_class(f);
    out[0] = 0;
    if (c == NULL) return;
    fname_str(SDK->ffield_class->get_fname(c), out, outsz);
}

static int obj_ok(void* o) {
    return o != NULL && SDK->uobject_hook != NULL && SDK->uobject_hook->exists((UEVR_UObjectHandle)o);
}

static void obj_name(void* o, char* out, int outsz) {
    out[0] = 0;
    if (!obj_ok(o)) { snprintf(out, outsz, "-"); return; }
    fname_str(SDK->uobject->get_fname((UEVR_UObjectHandle)o), out, outsz);
}

static void app(char* buf, size_t cap, const char* s) {
    size_t l = strlen(buf), k = strlen(s);
    if (l + k + 1 >= cap) return;
    memcpy(buf + l, s, k + 1);
}

#define MAXF 64
typedef struct { char name[96]; char type[48]; int off; UEVR_FFieldHandle f; } Field;

/* flatten the properties of a struct (one level of nesting) into fields with absolute offsets */
static void collect(UEVR_UScriptStructHandle ss, const char* prefix, int base, Field* out, int* nf, int depth) {
    UEVR_FFieldHandle f;
    for (f = SDK->ustruct->get_child_properties((UEVR_UStructHandle)ss); f != NULL && *nf < MAXF; f = SDK->ffield->get_next(f)) {
        char fnm[64], cls[48];
        int off;
        fname_str(SDK->ffield->get_fname(f), fnm, sizeof(fnm));
        field_class(f, cls, sizeof(cls));
        off = SDK->fproperty->get_offset((UEVR_FPropertyHandle)f);
        if (!strcmp(cls, "StructProperty") && depth < 1) {
            UEVR_UScriptStructHandle inner = SDK->fstructproperty->get_struct((UEVR_FStructPropertyHandle)f);
            char pre[160];
            if (inner != NULL) {
                snprintf(pre, sizeof(pre), "%s%s.", prefix, fnm);
                collect(inner, pre, base + off, out, nf, depth + 1);
                continue;
            }
        }
        snprintf(out[*nf].name, sizeof(out[*nf].name), "%s%s", prefix, fnm);
        snprintf(out[*nf].type, sizeof(out[*nf].type), "%s", cls);
        out[*nf].off = base + off;
        out[*nf].f = f;
        (*nf)++;
    }
}

static void read_array(void* obj, const wchar_t* wname, const char* name, char* out, size_t cap) {
    char tmp[512], cls[64];
    UEVR_UClassHandle klass;
    UEVR_FPropertyHandle prop, inner;
    UEVR_UScriptStructHandle ss;
    Field fields[MAXF];
    int nf = 0, i, j, size, count;
    const char* how = "ops";
    struct { char* data; int32_t num; int32_t max; } *arr;

    if (!obj_ok(obj)) { snprintf(tmp, sizeof(tmp), "%s;err=object\n", name); app(out, cap, tmp); return; }
    klass = SDK->uobject->get_class((UEVR_UObjectHandle)obj);
    prop = klass ? SDK->ustruct->find_property((UEVR_UStructHandle)klass, wname) : NULL;
    if (prop == NULL) { snprintf(tmp, sizeof(tmp), "%s;err=noprop\n", name); app(out, cap, tmp); return; }
    field_class((UEVR_FFieldHandle)prop, cls, sizeof(cls));
    if (strcmp(cls, "ArrayProperty") != 0) { snprintf(tmp, sizeof(tmp), "%s;err=type %s\n", name, cls); app(out, cap, tmp); return; }
    inner = SDK->farrayproperty->get_inner((UEVR_FArrayPropertyHandle)prop);
    if (inner == NULL) { snprintf(tmp, sizeof(tmp), "%s;err=noinner\n", name); app(out, cap, tmp); return; }
    field_class((UEVR_FFieldHandle)inner, cls, sizeof(cls));
    if (!strcmp(cls, "ClassProperty") || !strcmp(cls, "ObjectProperty")) {
        arr = SDK->uobject->get_property_data((UEVR_UObjectHandle)obj, wname);
        if (arr == NULL || !readable(arr, 16)) { snprintf(tmp, sizeof(tmp), "%s;err=array\n", name); app(out, cap, tmp); return; }
        count = arr->num;
        if (count < 0 || count > 256) { snprintf(tmp, sizeof(tmp), "%s;err=count %d\n", name, count); app(out, cap, tmp); return; }
        snprintf(tmp, sizeof(tmp), "%s;n=%d;sz=8;kind=%s", name, count, cls);
        app(out, cap, tmp);
        if (count > 0 && (arr->data == NULL || !readable(arr->data, (size_t)count * 8))) { app(out, cap, ";err=data\n"); return; }
        for (i = 0; i < count; i++) {
            char v[300];
            void* p = *(void**)(arr->data + (size_t)i * 8);
            if (p == NULL) snprintf(v, sizeof(v), "0"); else obj_name(p, v, sizeof(v));
            snprintf(tmp, sizeof(tmp), ";%d=", i);
            app(out, cap, tmp);
            app(out, cap, v);
        }
        app(out, cap, "\n");
        return;
    }
    if (!strcmp(cls, "NameProperty")) {                                    /* array of names */
        arr = SDK->uobject->get_property_data((UEVR_UObjectHandle)obj, wname);
        if (arr == NULL || !readable(arr, 16)) { snprintf(tmp, sizeof(tmp), "%s;err=array\n", name); app(out, cap, tmp); return; }
        count = arr->num;
        if (count < 0 || count > 256) { snprintf(tmp, sizeof(tmp), "%s;err=count %d\n", name, count); app(out, cap, tmp); return; }
        snprintf(tmp, sizeof(tmp), "%s;n=%d;sz=8;kind=Name", name, count);
        app(out, cap, tmp);
        if (count > 0 && (arr->data == NULL || !readable(arr->data, (size_t)count * 8))) { app(out, cap, ";err=data\n"); return; }
        for (i = 0; i < count; i++) {
            char v[300];
            fname_str((UEVR_FNameHandle)(arr->data + (size_t)i * 8), v, sizeof(v));
            snprintf(tmp, sizeof(tmp), ";%d=", i);
            app(out, cap, tmp);
            app(out, cap, v);
        }
        app(out, cap, "\n");
        return;
    }
    if (strcmp(cls, "StructProperty") != 0) { snprintf(tmp, sizeof(tmp), "%s;err=inner %s\n", name, cls); app(out, cap, tmp); return; }
    ss = SDK->fstructproperty->get_struct((UEVR_FStructPropertyHandle)inner);
    size = ss ? SDK->uscriptstruct->get_struct_size(ss) : 0;
    if (size <= 0 && ss != NULL && SDK->ustruct->get_properties_size != NULL) {
        int ps = SDK->ustruct->get_properties_size((UEVR_UStructHandle)ss);
        int al = SDK->ustruct->get_min_alignment != NULL ? SDK->ustruct->get_min_alignment((UEVR_UStructHandle)ss) : 1;
        if (al < 1 || al > 16) al = (al > 16) ? 16 : 1;
        size = ps > 0 ? ((ps + al - 1) / al) * al : 0;
        how = "props";
    }
    arr = SDK->uobject->get_property_data((UEVR_UObjectHandle)obj, wname);
    if (size <= 0 || size > 4096 || arr == NULL || !readable(arr, 16)) { snprintf(tmp, sizeof(tmp), "%s;err=size %d\n", name, size); app(out, cap, tmp); return; }
    count = arr->num;
    if (count < 0 || count > 256) { snprintf(tmp, sizeof(tmp), "%s;err=count %d\n", name, count); app(out, cap, tmp); return; }
    snprintf(tmp, sizeof(tmp), "%s;n=%d;sz=%d;how=%s;f=", name, count, size, how);
    app(out, cap, tmp);
    collect(ss, "", 0, fields, &nf, 0);
    for (j = 0; j < nf; j++) {
        if (fields[j].off < 0 || fields[j].off >= size) { app(out, cap, ";err=layout\n"); return; }
        snprintf(tmp, sizeof(tmp), "%s%s:%s@%d", j ? "," : "", fields[j].name, fields[j].type, fields[j].off);
        app(out, cap, tmp);
    }
    if (count > 0 && (arr->data == NULL || !readable(arr->data, (size_t)count * (size_t)size))) { app(out, cap, ";err=data\n"); return; }
    for (i = 0; i < count; i++) {
        char* e = arr->data + (size_t)i * (size_t)size;
        snprintf(tmp, sizeof(tmp), ";%d=", i);
        app(out, cap, tmp);
        for (j = 0; j < nf; j++) {
            const char* t = fields[j].type;
            int off = fields[j].off;
            char v[300];
            v[0] = 0;
            if (off < 0 || off >= size) { snprintf(v, sizeof(v), "?"); }
            else if (!strcmp(t, "ObjectProperty") || !strcmp(t, "ClassProperty")) {
                void* p = (off + 8 <= size) ? *(void**)(e + off) : NULL;
                if (p == NULL) snprintf(v, sizeof(v), "0"); else obj_name(p, v, sizeof(v));
            } else if (!strcmp(t, "IntProperty")) { if (off + 4 <= size) snprintf(v, sizeof(v), "%d", *(int32_t*)(e + off)); }
            else if (!strcmp(t, "UInt32Property")) { if (off + 4 <= size) snprintf(v, sizeof(v), "%u", *(uint32_t*)(e + off)); }
            else if (!strcmp(t, "Int64Property")) { if (off + 8 <= size) snprintf(v, sizeof(v), "%lld", (long long)*(int64_t*)(e + off)); }
            else if (!strcmp(t, "ByteProperty") || !strcmp(t, "EnumProperty")) { snprintf(v, sizeof(v), "%u", (unsigned)*(uint8_t*)(e + off)); }
            else if (!strcmp(t, "FloatProperty")) { if (off + 4 <= size) snprintf(v, sizeof(v), "%.6g", (double)*(float*)(e + off)); }
            else if (!strcmp(t, "DoubleProperty")) { if (off + 8 <= size) snprintf(v, sizeof(v), "%.6g", *(double*)(e + off)); }
            else if (!strcmp(t, "BoolProperty")) {
                if (SDK->fboolproperty && SDK->fboolproperty->get_value_from_object)
                    snprintf(v, sizeof(v), "%d", SDK->fboolproperty->get_value_from_object((UEVR_FBoolPropertyHandle)fields[j].f, e) ? 1 : 0);
            }
            else if (!strcmp(t, "NameProperty")) { if (off + 8 <= size) fname_str((UEVR_FNameHandle)(e + off), v, sizeof(v)); }
            else snprintf(v, sizeof(v), "~");
            if (j) app(out, cap, "|");
            app(out, cap, v);
        }
    }
    app(out, cap, "\n");
}

static void on_custom_event(const char* evt, const char* data) {
    static char out[32768];
    char cmd[16] = {0}, props[512] = {0};
    unsigned long long a = 0;
    char* tok;
    char* ctx = NULL;
    if (evt == NULL || data == NULL || strcmp(evt, "sfmat") != 0) return;
    if (sscanf(data, "%15s %llx %511s", cmd, &a, props) < 3 || strcmp(cmd, "read") != 0 || a == 0) return;
    out[0] = 0;
    for (tok = strtok_s(props, ",", &ctx); tok != NULL; tok = strtok_s(NULL, ",", &ctx)) {
        wchar_t w[128];
        if (strlen(tok) == 0 || strlen(tok) > 120) continue;
        MultiByteToWideChar(CP_UTF8, 0, tok, -1, w, 128);
        w[127] = 0;
        read_array((void*)(uintptr_t)a, w, tok, out, sizeof(out));
    }
    if (g_logged < 6) {
        char line[1100];
        const char* p = out;
        g_logged++;
        logi("[sf_mat] array read (read-only):");
        while (*p) {
            size_t n = strcspn(p, "\n");
            size_t k = n < 1000 ? n : 1000;
            memcpy(line, "[sf_mat] ", 9);
            memcpy(line + 9, p, k);
            line[9 + k] = 0;
            logi(line);
            p += n;
            if (*p == '\n') p++;
        }
    }
    if (P && P->functions && P->functions->dispatch_lua_event) P->functions->dispatch_lua_event("sfmat", out);
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    P = param;
    SDK = param->sdk;
    if (SDK == NULL || SDK->uobject == NULL || SDK->ustruct == NULL || SDK->ffield == NULL || SDK->fproperty == NULL ||
        SDK->farrayproperty == NULL || SDK->fstructproperty == NULL || SDK->uscriptstruct == NULL || SDK->fname == NULL ||
        SDK->ffield_class == NULL || SDK->uobject_hook == NULL) {
        logi("[sf_mat] not started: this UEVR build lacks part of the C API");
        return true;
    }
    if (param->callbacks != NULL && param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
    logi("[sf_mat] loaded - reads material parameter arrays for the Silverfish VR script (read-only, v1)");
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) { (void)inst; (void)reason; (void)reserved; return TRUE; }
