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
//   InstallTalkHook(ufuncAddr) -> bool   (native-hook GetTalkText; speaks dialogue)
//   PollTalk()                 -> string|nil  (last captured line, for logging)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <mutex>
#include <string>
#include <cstdint>
#include <cstring>

#include "SpatialAudio.h"
#include <cstdio>

#include "MinHook.h"
extern "C" {
#include "hde64.h"   // HDE disassembler (bundled with MinHook) -- to locate a UFunction's native impl
}

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
// In-process native hooking lets us read struct-returning UFunctions (e.g.
// GetTalkText) that UE4SS's Lua RegisterHook crashes on -- in C++ we read the
// struct bytes directly, no Lua marshalling.
bool           g_mh_ready  = false;
std::once_flag g_hooks_once;

// Speaker names: TalkText.Names[0] is an FName HANDLE that is itself a GameText
// label ("ePLAYABLE_FULL_NAME_02" for a traveler, "CN_*" for chapter NPCs). To
// get the localized display name we must CALL
//   void KSTextStatics::GetGameTextString(FName Label, FString& OutText)
// Lua can't (its FString-return marshalling fails), so we call the native impl
// from C++: Lua hands us the UFunction address, we find the impl by disassembling
// the exec (the last in-image CALL), and invoke it (Label in RCX, &OutText in
// RDX). g_name_out is a reused output FString -- UE owns/reallocates its buffer.
struct FStringRaw { wchar_t* data; int num; int cap; };
using FnGetGameTextStr = void (*)(uint64_t /*FName by value*/, void* /*FString**/);
FnGetGameTextStr g_ggts_impl      = nullptr;   // resolved GetGameTextString impl
FStringRaw       g_name_out       = { nullptr, 0, 0 };
uintptr_t        g_ggts_cands[16] = { 0 };     // impl candidates (singly-called in-image targets)
int              g_ggts_cand_n    = 0;
bool             g_ggts_searched  = false;     // have we tried the candidates yet?

void init_hooks() {
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
using FnExec = void (*)(void*, void*, void*);
FnExec       g_gtt_orig = nullptr;

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

// Disassemble a native exec to find its implementation: the last CALL (E8) whose
// target lies inside the main module. HDE (bundled with MinHook) decodes the
// instructions. SEH-guarded; optionally records candidate RVAs for logging.
static void* find_impl_call(void* exec, uintptr_t* rvas, int* count, int maxr) {
    void* impl = nullptr;
    if (count) *count = 0;
    __try {
        HMODULE h = GetModuleHandleW(nullptr);
        uintptr_t base = reinterpret_cast<uintptr_t>(h), size = 0;
        if (h) {
            auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(h);
            auto nt  = reinterpret_cast<IMAGE_NT_HEADERS*>(reinterpret_cast<BYTE*>(h) + dos->e_lfanew);
            size = nt->OptionalHeader.SizeOfImage;
        }
        uintptr_t p = reinterpret_cast<uintptr_t>(exec);
        for (int i = 0; i < 100; i++) {
            hde64s hs;
            unsigned int len = hde64_disasm(reinterpret_cast<void*>(p), &hs);
            if ((hs.flags & F_ERROR) || len == 0) break;
            if (hs.opcode == 0xE8) {                                   // CALL rel32
                uintptr_t target = p + len + static_cast<int>(hs.imm.imm32);
                if (size && target >= base && target < base + size) {
                    impl = reinterpret_cast<void*>(target);            // keep the last in-image call
                    if (rvas && count && *count < maxr) rvas[(*count)++] = target - base;
                }
            }
            if (hs.opcode == 0xC3 || hs.opcode == 0xC2) break;         // RET
            p += len;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { impl = nullptr; }
    return impl;
}

// SEH-guarded read of the speaker FName (Names[0], 8 bytes) from a TalkText.
static uint64_t read_fname0(void* tt) {
    uint64_t fname = 0;
    __try {
        uintptr_t b   = reinterpret_cast<uintptr_t>(tt);
        void* arrData = *reinterpret_cast<void**>(b + 0x40);   // Names: TArray<FName> data
        int   arrNum  = *reinterpret_cast<int*>(b + 0x48);     // Names: element count
        if (arrData && arrNum > 0) fname = *reinterpret_cast<uint64_t*>(arrData);
    } __except (EXCEPTION_EXECUTE_HANDLER) { fname = 0; }
    return fname;
}

// Try calling a candidate as GetGameTextString(FName, FString&). Returns true +
// the resulting text iff it produced a readable string. SEH-guarded; the local
// out FString is leaked if allocated (only happens during the one-time search).
static bool try_candidate(uintptr_t cand, uint64_t fname, wchar_t* buf, int cap, int* outlen) {
    bool valid = false; *outlen = 0; if (cap > 0) buf[0] = L'\0';
    __try {
        FStringRaw lo = { nullptr, 0, 0 };
        reinterpret_cast<FnGetGameTextStr>(cand)(fname, &lo);
        if (lo.data && lo.num > 1 && lo.num < 200) {
            int m = lo.num - 1; if (m > cap - 1) m = cap - 1;
            bool printable = (m > 0);
            for (int j = 0; j < m; j++) { wchar_t c = lo.data[j]; buf[j] = c; if (c < 0x20) printable = false; }
            buf[m] = L'\0';
            valid = printable;
            *outlen = valid ? m : 0;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { valid = false; *outlen = 0; if (cap > 0) buf[0] = L'\0'; }
    return valid;
}

// Call the resolved impl into the persistent g_name_out (no per-call leak).
static int resolve_via(FnGetGameTextStr impl, uint64_t fname, wchar_t* nameBuf, int cap) {
    int wlen = 0; nameBuf[0] = L'\0';
    __try {
        impl(fname, &g_name_out);
        wchar_t* s = g_name_out.data;
        int      n = g_name_out.num;
        if (s && n > 1 && n < 256) {
            for (int j = 0; j < n - 1 && wlen < cap - 1; j++) nameBuf[wlen++] = s[j];
        }
        nameBuf[wlen] = L'\0';
    } __except (EXCEPTION_EXECUTE_HANDLER) { wlen = 0; nameBuf[0] = L'\0'; }
    return wlen;
}

// Resolve Names[0] to the localized display name. On the first real speaker,
// identify which disassembled candidate is GetGameTextString by trying each (the
// one returning readable text wins) and cache it. Empty -> no speaker.
static int read_speaker(void* tt, wchar_t* nameBuf, int cap) {
    uint64_t fname = read_fname0(tt);
    if (fname == 0) { nameBuf[0] = L'\0'; return 0; }
    if (!g_ggts_impl && !g_ggts_searched) {
        g_ggts_searched = true;
        wchar_t tmp[128]; int got = 0;
        for (int i = 0; i < g_ggts_cand_n; i++) {
            if (try_candidate(g_ggts_cands[i], fname, tmp, 128, &got)) {
                g_ggts_impl = reinterpret_cast<FnGetGameTextStr>(g_ggts_cands[i]);
                break;
            }
        }
    }
    if (g_ggts_impl) return resolve_via(g_ggts_impl, fname, nameBuf, cap);
    nameBuf[0] = L'\0';
    return 0;
}

void capture_talk(void* result, void* frame) {
    void* mrpa = nullptr; void* locals8 = nullptr;
    read_frame_cands(frame, &mrpa, &locals8);
    void* cands[3] = { result, mrpa, locals8 };   // OutText is usually at mrpa
    wchar_t wbuf[2048];
    int wlen = 0;
    void* talk_base = nullptr;
    for (int i = 0; i < 3; i++) {
        if (cands[i]) {
            wlen = read_talktext_raw(cands[i], wbuf, 2048);
            if (wlen > 0) { talk_base = cands[i]; break; }
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

    // Prepend the speaker (TalkText.Names[0]) as "Name: " when present.
    wchar_t namebuf[128];
    int nlen = read_speaker(talk_base, namebuf, 128);
    wchar_t out[2304];
    int olen = 0;
    if (nlen > 0) {
        for (int j = 0; j < nlen && olen < 2300; j++) out[olen++] = namebuf[j];
        out[olen++] = L':';
        out[olen++] = L' ';
    }
    for (int j = 0; j < wlen && olen < 2303; j++) out[olen++] = wbuf[j];
    out[olen] = L'\0';

    // Speak DIRECTLY from the native hook (game thread) -- independent of the Lua
    // poll loop, which intermittently dies after a chapter load (PollTalk would
    // then never run). The hook always fires.
    if (g_tolk_output) g_tolk_output(out, true);

    // Also publish for the loop to LOG it (it no longer speaks -> no double-speak).
    char u8[6144];
    int u = WideCharToMultiByte(CP_UTF8, 0, out, olen, u8, sizeof(u8) - 1, nullptr, nullptr);
    if (u <= 0) return;
    std::lock_guard<std::mutex> lk(g_talk_mtx);
    g_last_talk.assign(u8, static_cast<size_t>(u));
    g_talk_new = true;
}

void hk_gtt(void* ctx, void* frame, void* result) {
    if (g_gtt_orig) g_gtt_orig(ctx, frame, result);
    capture_talk(result, frame);
}

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

// Install the GetTalkText hook. Lua passes the UFunction's address; its native
// exec (Func) is at UFunction+0xB0 (verified by the function prologue there).
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

// Resolve GetGameTextString's native impl (for speaker-name lookup) from its
// UFunction address: read the exec (Func at +0xB0) and find its impl call.
// Returns a short diagnostic string (impl RVA + candidate count) for logging.
int l_install_gametext_resolver(lua_State* L) {
    uintptr_t ufunc = static_cast<uintptr_t>(luaL_checkinteger(L, 1));
    void* exec = nullptr;
    if (ufunc >= 0x10000) {
        __try { exec = *reinterpret_cast<void**>(ufunc + 0xB0); }
        __except (EXCEPTION_EXECUTE_HANDLER) { exec = nullptr; }
    }
    uintptr_t rvas[16]; int cnt = 0;
    if (exec) find_impl_call(exec, rvas, &cnt, 16);
    uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    // Keep only singly-called in-image targets as impl candidates: the param-read
    // machinery is called once per parameter (appears >=2x); the impl is called
    // exactly once. read_speaker tries these and keeps whichever returns a name.
    g_ggts_impl = nullptr; g_ggts_searched = false; g_ggts_cand_n = 0;
    for (int i = 0; i < cnt; i++) {
        int c = 0; for (int j = 0; j < cnt; j++) if (rvas[j] == rvas[i]) c++;
        if (c == 1 && g_ggts_cand_n < 16) g_ggts_cands[g_ggts_cand_n++] = base + rvas[i];
    }
    char buf[256]; int n = 0;
    n += std::snprintf(buf + n, sizeof(buf) - n, "calls=%d singles=%d [", cnt, g_ggts_cand_n);
    for (int i = 0; i < cnt && n < static_cast<int>(sizeof(buf)) - 16; i++)
        n += std::snprintf(buf + n, sizeof(buf) - n, "%llX ", static_cast<unsigned long long>(rvas[i]));
    std::snprintf(buf + n, sizeof(buf) - n, "]");
    lua_pushstring(L, buf);
    return 1;
}
// Returns the last captured dialogue line(s) once, then clears (nil if nothing new).
int l_poll_talk(lua_State* L) {
    std::lock_guard<std::mutex> lk(g_talk_mtx);
    if (g_talk_new && !g_last_talk.empty()) {
        g_talk_new = false;
        lua_pushlstring(L, g_last_talk.data(), g_last_talk.size());
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

// ---- Spatial audio (phase 4 / Pillar A): Steam Audio HRTF beacons ----
int l_audio_init(lua_State* L)     { lua_pushboolean(L, SA_Init()); return 1; }
int l_audio_shutdown(lua_State* L) { SA_Shutdown(); return 0; }
int l_audio_status(lua_State* L)   { lua_pushstring(L, SA_Status()); return 1; }
int l_audio_test(lua_State* L)     { SA_TestTone((int)luaL_checkinteger(L, 1)); return 0; }
int l_audio_set_listener(lua_State* L) {
    SA_SetListener((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
    return 0;
}
int l_audio_set_source(lua_State* L) {
    SA_SetSource((int)luaL_checkinteger(L, 1), lua_toboolean(L, 2),
                 (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5),
                 (int)luaL_optinteger(L, 6, 0));
    return 0;
}

const luaL_Reg op1access_funcs[] = {
    {"Speak",                l_speak},
    {"Silence",              l_silence},
    {"IsSpeakingSupported",  l_is_supported},
    {"DetectScreenReader",   l_detect},
    {"PreferSAPI",           l_prefer_sapi},
    {"InstallTalkHook",      l_install_talk_hook},
    {"InstallGameTextResolver", l_install_gametext_resolver},
    {"PollTalk",             l_poll_talk},
    {"AudioInit",            l_audio_init},
    {"AudioShutdown",        l_audio_shutdown},
    {"AudioStatus",          l_audio_status},
    {"AudioTest",            l_audio_test},
    {"AudioSetListener",     l_audio_set_listener},
    {"AudioSetSource",       l_audio_set_source},
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
