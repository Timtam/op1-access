// OP1AccessShim — Lua C extension that bridges Tolk speech output into the
// OP1Access Lua mod.
//
// Build: this DLL statically links Lua 5.4 (matched to UE4SS's bundled
// version) and dynamically links Tolk.dll at runtime via LoadLibrary +
// GetProcAddress. Tolk.dll itself is built from tools/tolk-src/ by the
// same build script and deployed alongside this DLL plus the screen
// reader bridge DLLs (nvdaControllerClient64.dll, SAAPI64.dll) that Tolk
// in turn loads at runtime.
//
// Functions exposed to Lua:
//   Speak(text [, interrupt])  -> bool
//   Silence()                  -> bool
//   IsSpeakingSupported()      -> bool   (Tolk has detected a screen reader)
//   DetectScreenReader()       -> string|nil  (name of active backend)
//   PreferSAPI(bool)           -> bool   (force SAPI as primary)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <mutex>
#include <string>
#include <cstdio>
#include <cstdint>
#include <cstring>

#include "MinHook.h"

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

namespace {

using FnTolk_Load        = void          (__stdcall*)();
using FnTolk_Unload      = void          (__stdcall*)();
using FnTolk_IsLoaded    = bool          (__stdcall*)();
using FnTolk_Output      = bool          (__stdcall*)(const wchar_t*, bool);
using FnTolk_Silence     = bool          (__stdcall*)();
using FnTolk_HasSpeech   = bool          (__stdcall*)();
using FnTolk_DetectScreenReader = const wchar_t* (__stdcall*)();
using FnTolk_TrySAPI     = void          (__stdcall*)(bool);
using FnTolk_PreferSAPI  = void          (__stdcall*)(bool);

HMODULE                   g_self             = nullptr;
HMODULE                   g_tolk             = nullptr;
FnTolk_Load               g_tolk_load        = nullptr;
FnTolk_IsLoaded           g_tolk_isloaded    = nullptr;
FnTolk_Output             g_tolk_output      = nullptr;
FnTolk_Silence            g_tolk_silence     = nullptr;
FnTolk_HasSpeech          g_tolk_has_speech  = nullptr;
FnTolk_DetectScreenReader g_tolk_detect      = nullptr;
FnTolk_TrySAPI            g_tolk_try_sapi    = nullptr;
FnTolk_PreferSAPI         g_tolk_prefer_sapi = nullptr;
std::once_flag            g_init_once;

// --- Native hooking (MinHook) -------------------------------------------
// PHASE 1 self-test: QueryPerformanceCounter is called every frame by the
// engine; hooking it and counting calls proves in-process native hooking works.
// This is the foundation for reading struct-returning UFunctions (e.g.
// GetTalkText) that UE4SS's Lua RegisterHook crashes on -- in C++ we read the
// struct bytes directly, no Lua marshalling.
using FnQPC = BOOL (WINAPI*)(LARGE_INTEGER*);
FnQPC          g_qpc_orig   = nullptr;
volatile long  g_hook_count = 0;
bool           g_mh_ready   = false;
std::once_flag g_hooks_once;

BOOL WINAPI hk_qpc(LARGE_INTEGER* p) {
    InterlockedIncrement(&g_hook_count);
    return g_qpc_orig ? g_qpc_orig(p) : FALSE;
}

void init_hooks() {
    // Initialize MinHook. (The Phase-1 QueryPerformanceCounter self-test that
    // proved in-process hooking has been removed now that real UFunction hooks
    // work.)
    g_mh_ready = (MH_Initialize() == MH_OK);
}

// --- GetTalkText capture (the payoff) -----------------------------------
// GetTalkText(Label) -> OutText (TalkText struct). The localized dialogue is
// OutText.Text: a TArray<FString> at struct offset 0x50 (one entry per line).
// We hook the UFunction's native exec (Func, at UFunction+0xB0 -- confirmed by
// its prologue), call the original so OutText is filled, then read the strings by
// offset in C++ (no Lua marshalling -> no crash). The read is SEH-guarded so a
// wrong offset degrades to "nothing" instead of crashing.
std::mutex   g_talk_mtx;
std::string  g_last_talk;          // UTF-8, last captured line(s)
bool         g_talk_new = false;
int          g_talk_src  = 0;      // which candidate yielded the text (diagnostic)
using FnExec = void (*)(void*, void*, void*);
FnExec       g_gtt_orig  = nullptr;
volatile long g_gtt_count = 0;     // times the GetTalkText hook fired (diagnostic)

// SEH-guarded raw read into a caller-provided buffer. POD-only (no C++ objects)
// so __try is allowed (MSVC C2712 forbids __try alongside object unwinding).
static int read_talktext_raw(void* tt, wchar_t* wbuf, int cap) {
    int wlen = 0;
    __try {
        uintptr_t b   = reinterpret_cast<uintptr_t>(tt);
        void* arrData = *reinterpret_cast<void**>(b + 0x50);   // TalkText.Text -> TArray data
        int   arrNum  = *reinterpret_cast<int*>(b + 0x58);     // TArray element count
        if (arrData && arrNum > 0 && arrNum <= 64) {
            for (int i = 0; i < arrNum; i++) {
                uintptr_t el = reinterpret_cast<uintptr_t>(arrData) + static_cast<uintptr_t>(i) * 16;
                wchar_t* s = *reinterpret_cast<wchar_t**>(el);
                int      n = *reinterpret_cast<int*>(el + 8);  // FString length (incl. null)
                if (s && n > 1 && n < 2000) {
                    for (int j = 0; j < n - 1 && wlen < cap - 1; j++) wbuf[wlen++] = s[j];
                    if (wlen < cap - 1) wbuf[wlen++] = (i + 1 < arrNum) ? L'\n' : L' ';
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        wlen = 0;
    }
    return wlen;
}

// OutText is likely an out-param (filled by reference), not the return at
// `result`. Pull candidate addresses from the call FFrame: +0x38 is
// MostRecentPropertyAddress (= &OutText after the exec reads it), +0x28 is
// Locals (OutText param sits at +8). SEH-guarded, POD-only.
static void read_frame_cands(void* frame, void** c_mrpa, void** c_locals) {
    *c_mrpa = nullptr; *c_locals = nullptr;
    __try {
        if (frame) {
            uintptr_t f = reinterpret_cast<uintptr_t>(frame);
            *c_mrpa = *reinterpret_cast<void**>(f + 0x38);
            void* locals = *reinterpret_cast<void**>(f + 0x28);
            if (locals) *c_locals = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(locals) + 8);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
}

void capture_talk(void* result, void* frame) {
    void* mrpa = nullptr; void* locals8 = nullptr;
    read_frame_cands(frame, &mrpa, &locals8);
    void* cands[3] = { result, mrpa, locals8 };
    wchar_t wbuf[2048];
    int wlen = 0, src = 0;
    for (int i = 0; i < 3; i++) {
        if (cands[i]) {
            wlen = read_talktext_raw(cands[i], wbuf, 2048);
            if (wlen > 0) { src = i + 1; break; }   // 1=result 2=mrpa 3=locals+8
        }
    }
    if (wlen <= 0) return;
    wbuf[wlen] = L'\0';

    // Dedup consecutive identical lines (the game re-fetches the same line).
    // Only the hook calls this, so a static buffer is single-threaded.
    static wchar_t s_last[2048]; static int s_last_len = -1;
    if (wlen == s_last_len &&
        memcmp(wbuf, s_last, static_cast<size_t>(wlen) * sizeof(wchar_t)) == 0) return;
    memcpy(s_last, wbuf, (static_cast<size_t>(wlen) + 1) * sizeof(wchar_t));
    s_last_len = wlen;

    // Speak DIRECTLY from the native hook (game thread). This is independent of
    // the Lua poll loop, which intermittently dies after a chapter load -- when
    // it did, PollTalk never ran and dialogue was silent. The hook always fires.
    if (g_tolk_output) g_tolk_output(wbuf, true);

    // Also publish for the loop to LOG it (it no longer speaks -> no double-speak).
    char u8[6144];
    int u = WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, u8, sizeof(u8) - 1, nullptr, nullptr);
    if (u <= 0) return;
    std::lock_guard<std::mutex> lk(g_talk_mtx);
    g_last_talk.assign(u8, static_cast<size_t>(u));
    g_talk_src = src;
    g_talk_new = true;
}

void hk_gtt(void* ctx, void* frame, void* result) {
    InterlockedIncrement(&g_gtt_count);
    if (g_gtt_orig) g_gtt_orig(ctx, frame, result);
    capture_talk(result, frame);
}

// Diagnostic counters for the other localized-text statics, to learn which the
// prologue actually uses (and to confirm exec-hooking works at all -- the UI
// definitely calls one of these). Count only; no capture yet.
FnExec g_ggt_orig = nullptr, g_ggts_orig = nullptr;
volatile long g_ggt_count = 0, g_ggts_count = 0;
void hk_ggt(void* c, void* f, void* r)  { InterlockedIncrement(&g_ggt_count);  if (g_ggt_orig)  g_ggt_orig(c, f, r); }
void hk_ggts(void* c, void* f, void* r) { InterlockedIncrement(&g_ggts_count); if (g_ggts_orig) g_ggts_orig(c, f, r); }

std::wstring sibling_path(const wchar_t* name) {
    wchar_t buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameW(g_self, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return name;
    wchar_t* last_sep = wcsrchr(buf, L'\\');
    if (last_sep) *(last_sep + 1) = L'\0';
    std::wstring full = buf;
    full += name;
    return full;
}

void init_tolk() {
    // Add our Scripts directory to the DLL search path BEFORE loading
    // Tolk.dll. Tolk_Load() internally calls LoadLibrary on relative names
    // ("nvdaControllerClient64.dll", "SAAPI64.dll"); without our directory
    // in the search path those loads fail and Tolk has no active driver.
    {
        wchar_t buf[MAX_PATH] = {0};
        if (GetModuleFileNameW(g_self, buf, MAX_PATH) > 0) {
            wchar_t* last_sep = wcsrchr(buf, L'\\');
            if (last_sep) *last_sep = L'\0';
            SetDllDirectoryW(buf);
        }
    }

    auto path = sibling_path(L"Tolk.dll");
    g_tolk = LoadLibraryW(path.c_str());
    if (!g_tolk) return;
    g_tolk_load        = reinterpret_cast<FnTolk_Load>             (GetProcAddress(g_tolk, "Tolk_Load"));
    g_tolk_isloaded    = reinterpret_cast<FnTolk_IsLoaded>         (GetProcAddress(g_tolk, "Tolk_IsLoaded"));
    g_tolk_output      = reinterpret_cast<FnTolk_Output>           (GetProcAddress(g_tolk, "Tolk_Output"));
    g_tolk_silence     = reinterpret_cast<FnTolk_Silence>          (GetProcAddress(g_tolk, "Tolk_Silence"));
    g_tolk_has_speech  = reinterpret_cast<FnTolk_HasSpeech>        (GetProcAddress(g_tolk, "Tolk_HasSpeech"));
    g_tolk_detect      = reinterpret_cast<FnTolk_DetectScreenReader>(GetProcAddress(g_tolk, "Tolk_DetectScreenReader"));
    g_tolk_try_sapi    = reinterpret_cast<FnTolk_TrySAPI>          (GetProcAddress(g_tolk, "Tolk_TrySAPI"));
    g_tolk_prefer_sapi = reinterpret_cast<FnTolk_PreferSAPI>       (GetProcAddress(g_tolk, "Tolk_PreferSAPI"));
    if (g_tolk_try_sapi) g_tolk_try_sapi(true);
    if (g_tolk_load)     g_tolk_load();
}

int l_speak(lua_State* L) {
    std::call_once(g_init_once, init_tolk);

    luaL_checktype(L, 1, LUA_TSTRING);

    // Don't trust the length lua_tolstring/luaL_checklstring report — they
    // were observed to return 0 for long Lua strings even when #text on
    // the Lua side reports the right value. Likely an ABI mismatch
    // between our statically-linked Lua and UE4SS's runtime Lua. Lua
    // strings are null-terminated internally, so strlen gives the
    // correct byte count for any string without embedded NULs (game text
    // never has them).
    const char* s = lua_tolstring(L, 1, nullptr);
    size_t len = s ? strlen(s) : 0;

    bool interrupt = lua_isboolean(L, 2) ? (lua_toboolean(L, 2) != 0) : true;

    bool ok = false;
    if (g_tolk_output && len > 0) {
        // malloc rather than std::vector so the SEH __try below has no
        // C++ destructors in scope (MSVC C2712).
        wchar_t* buf = static_cast<wchar_t*>(malloc((len + 16) * sizeof(wchar_t)));
        if (buf) {
            __try {
                bool has_high_bit = false;
                for (size_t i = 0; i < len; i++) {
                    if (static_cast<unsigned char>(s[i]) >= 0x80) { has_high_bit = true; break; }
                }
                size_t actual_len = 0;
                if (!has_high_bit) {
                    for (size_t i = 0; i < len; i++) {
                        buf[i] = static_cast<wchar_t>(static_cast<unsigned char>(s[i]));
                    }
                    actual_len = len;
                } else {
                    int n = MultiByteToWideChar(CP_UTF8, 0, s, static_cast<int>(len), nullptr, 0);
                    if (n > 0 && static_cast<size_t>(n) + 1 < len + 16) {
                        MultiByteToWideChar(CP_UTF8, 0, s, static_cast<int>(len), buf, n);
                        actual_len = static_cast<size_t>(n);
                    }
                }
                buf[actual_len] = L'\0';
                ok = g_tolk_output(buf, interrupt);
            } __except(EXCEPTION_EXECUTE_HANDLER) {
                ok = false;
            }
            free(buf);
        }
    }
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

int l_silence(lua_State* L) {
    bool ok = (g_tolk_silence != nullptr) && g_tolk_silence();
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

int l_is_supported(lua_State* L) {
    std::call_once(g_init_once, init_tolk);
    bool ok = (g_tolk != nullptr)
           && (g_tolk_isloaded != nullptr)
           && g_tolk_isloaded()
           && (g_tolk_has_speech == nullptr || g_tolk_has_speech());
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

int l_detect(lua_State* L) {
    std::call_once(g_init_once, init_tolk);
    if (!g_tolk_detect) { lua_pushnil(L); return 1; }
    const wchar_t* w = g_tolk_detect();
    if (!w) { lua_pushnil(L); return 1; }
    int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) { lua_pushnil(L); return 1; }
    std::string s(static_cast<size_t>(len - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), len, nullptr, nullptr);
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

int l_prefer_sapi(lua_State* L) {
    std::call_once(g_init_once, init_tolk);
    bool prefer = lua_isboolean(L, 1) ? (lua_toboolean(L, 1) != 0) : true;
    if (g_tolk_prefer_sapi) g_tolk_prefer_sapi(prefer);
    lua_pushboolean(L, g_tolk_prefer_sapi != nullptr ? 1 : 0);
    return 1;
}

// PHASE 1 diagnostic: returns the QPC hook hit-count (and whether MinHook armed).
// Lua logs this after load; a climbing count proves native hooking works.
int l_hook_selftest(lua_State* L) {
    lua_pushinteger(L, static_cast<lua_Integer>(g_hook_count));
    lua_pushboolean(L, g_mh_ready ? 1 : 0);
    lua_pushinteger(L, static_cast<lua_Integer>(g_gtt_count));
    return 3;
}

// PHASE 2a: given a UFunction's address (from Lua's GetAddress()), scan its tail
// for a pointer into the main executable's image -- that's the native exec
// (UFunction::Func) we'll hook. Read-only; returns "+OFF=rva:RVA ..." so we can
// learn the Func member offset for this build. (No hooking here.)
int l_probe_ufunc(lua_State* L) {
    uintptr_t addr = static_cast<uintptr_t>(luaL_checkinteger(L, 1));
    if (addr < 0x10000) { lua_pushstring(L, "(bad addr)"); return 1; }
    HMODULE h = GetModuleHandleW(nullptr);
    uintptr_t base = reinterpret_cast<uintptr_t>(h), size = 0;
    if (h) {
        auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(h);
        auto nt  = reinterpret_cast<IMAGE_NT_HEADERS*>(reinterpret_cast<BYTE*>(h) + dos->e_lfanew);
        size = nt->OptionalHeader.SizeOfImage;
    }
    std::string out;
    char line[160];
    for (uintptr_t off = 0x40; off <= 0x108; off += 8) {
        uintptr_t v = *reinterpret_cast<uintptr_t*>(addr + off);
        if (size && v >= base && v < base + size) {
            // Dump the first bytes AT the pointer so we can tell a code prologue
            // (the native exec = Func) from a vtable (points at pointers).
            const unsigned char* p = reinterpret_cast<const unsigned char*>(v);
            char bytes[40]; int k = 0;
            for (int i = 0; i < 8 && k < (int)sizeof(bytes) - 4; i++)
                k += std::snprintf(bytes + k, sizeof(bytes) - k, "%02X ", p[i]);
            std::snprintf(line, sizeof(line), "+%llX=rva:%llX[%s] ",
                          (unsigned long long)off, (unsigned long long)(v - base), bytes);
            out += line;
        }
    }
    if (out.empty()) out = "(no in-image ptrs found)";
    lua_pushstring(L, out.c_str());
    return 1;
}

// PHASE 2b: install the GetTalkText hook. Lua passes the UFunction's address;
// Func is at +0xB0 (confirmed by prologue). Returns true if the hook armed.
static bool install_func_hook(uintptr_t ufunc, void* cb, void** orig) {
    if (ufunc < 0x10000) return false;
    void* func = *reinterpret_cast<void**>(ufunc + 0xB0);   // UFunction::Func (confirmed)
    return func && MH_CreateHook(func, cb, orig) == MH_OK && MH_EnableHook(func) == MH_OK;
}
int l_install_talk_hook(lua_State* L) {
    bool ok = install_func_hook(static_cast<uintptr_t>(luaL_checkinteger(L, 1)),
                                reinterpret_cast<void*>(&hk_gtt), reinterpret_cast<void**>(&g_gtt_orig));
    lua_pushboolean(L, ok ? 1 : 0); return 1;
}
int l_install_ggt_hook(lua_State* L) {
    bool ok = install_func_hook(static_cast<uintptr_t>(luaL_checkinteger(L, 1)),
                                reinterpret_cast<void*>(&hk_ggt), reinterpret_cast<void**>(&g_ggt_orig));
    lua_pushboolean(L, ok ? 1 : 0); return 1;
}
int l_install_ggts_hook(lua_State* L) {
    bool ok = install_func_hook(static_cast<uintptr_t>(luaL_checkinteger(L, 1)),
                                reinterpret_cast<void*>(&hk_ggts), reinterpret_cast<void**>(&g_ggts_orig));
    lua_pushboolean(L, ok ? 1 : 0); return 1;
}
int l_text_counts(lua_State* L) {
    lua_pushinteger(L, static_cast<lua_Integer>(g_gtt_count));
    lua_pushinteger(L, static_cast<lua_Integer>(g_ggt_count));
    lua_pushinteger(L, static_cast<lua_Integer>(g_ggts_count));
    return 3;
}

// Returns the last captured dialogue line(s) once, then clears (nil if nothing new).
int l_poll_talk(lua_State* L) {
    std::lock_guard<std::mutex> lk(g_talk_mtx);
    if (g_talk_new && !g_last_talk.empty()) {
        g_talk_new = false;
        lua_pushlstring(L, g_last_talk.data(), g_last_talk.size());
        lua_pushinteger(L, g_talk_src);
        return 2;
    }
    lua_pushnil(L);
    return 1;
}

const luaL_Reg op1access_funcs[] = {
    {"Speak",                l_speak},
    {"Silence",              l_silence},
    {"IsSpeakingSupported",  l_is_supported},
    {"DetectScreenReader",   l_detect},
    {"PreferSAPI",           l_prefer_sapi},
    {"HookSelfTest",         l_hook_selftest},
    {"ProbeUFunc",           l_probe_ufunc},
    {"InstallTalkHook",      l_install_talk_hook},
    {"InstallGameTextHook",  l_install_ggt_hook},
    {"InstallGameTextStrHook", l_install_ggts_hook},
    {"TextCounts",           l_text_counts},
    {"PollTalk",             l_poll_talk},
    {nullptr, nullptr},
};

} // namespace

extern "C" __declspec(dllexport) int luaopen_OP1AccessShim(lua_State* L) {
    std::call_once(g_hooks_once, init_hooks);
    luaL_newlib(L, op1access_funcs);
    return 1;
}

extern "C" BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) g_self = hinst;
    return TRUE;
}
