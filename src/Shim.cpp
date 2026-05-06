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

const luaL_Reg op1access_funcs[] = {
    {"Speak",                l_speak},
    {"Silence",              l_silence},
    {"IsSpeakingSupported",  l_is_supported},
    {"DetectScreenReader",   l_detect},
    {"PreferSAPI",           l_prefer_sapi},
    {nullptr, nullptr},
};

} // namespace

extern "C" __declspec(dllexport) int luaopen_OP1AccessShim(lua_State* L) {
    luaL_newlib(L, op1access_funcs);
    return 1;
}

extern "C" BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) g_self = hinst;
    return TRUE;
}
