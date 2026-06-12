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
#include <thread>
#include <vector>

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

// --- NPC probe ------------------------------------------------------------
// Answers "can this NPC be talked to, and what is it called?" from data, not
// guessing: GetPlacementData (a BLUEPRINT function -- unreachable from Lua,
// struct out-params hard-crash there) is invoked natively via ProcessEvent,
// and the placement's TextLabel is then looked up in the talk database by
// calling the GetTalkText IMPL directly (bypasses our own hook -> silent, no
// speech, no PollTalk pollution). ProcessEvent itself is found by scanning the
// object's vtable for the virtual that dispatches `call [reg+0xB0]` -- 0xB0 is
// UFunction::Func, the offset this build already confirmed for the talk hook.
using FnProcessEvent = void (*)(void*, void*, void*);
using FnTalkImpl     = void (*)(uint64_t /*FName Label*/, void* /*TalkText* out*/);
FnProcessEvent g_pe           = nullptr;
int            g_pe_idx       = -1;
bool           g_pe_searched  = false;
void*          g_pe_cands[24] = { nullptr };   // candidate ProcessEvent slots
int            g_pe_cand_idx[24] = { 0 };
int            g_pe_cand_n   = 0;
bool           g_pe_validated = false;
uintptr_t      g_gtt_cands[16] = { 0 };   // GetTalkText impl candidates (pre-hook)
int            g_gtt_cand_n   = 0;
FnTalkImpl     g_gtt_impl     = nullptr;
bool           g_gtt_id_done  = false;
uint64_t       g_known_label  = 0;        // an FName label seen in REAL dialogue
alignas(16) unsigned char g_place_buf[0x1000];   // PlacementInfoData out-buffer
alignas(16) unsigned char g_talk_buf[0x400];     // TalkText out-buffer (reused)

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
std::string  g_last_name;          // UTF-8, last resolved speaker display name
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
    char nu8[384]; int nu = 0;
    if (nlen > 0) nu = WideCharToMultiByte(CP_UTF8, 0, namebuf, nlen, nu8, sizeof(nu8) - 1, nullptr, nullptr);
    std::lock_guard<std::mutex> lk(g_talk_mtx);
    g_last_talk.assign(u8, static_cast<size_t>(u));
    if (nu > 0) g_last_name.assign(nu8, static_cast<size_t>(nu));
    g_talk_new = true;
}

// SEH-guarded read of the Label param (FName, 8 bytes at Locals+0) from the
// GetTalkText call frame -- a label KNOWN to have text, used once to identify
// the GetTalkText impl among the disassembly candidates.
static uint64_t read_frame_label(void* frame) {
    uint64_t v = 0;
    __try {
        if (frame) {
            uintptr_t f = reinterpret_cast<uintptr_t>(frame);
            void* locals = *reinterpret_cast<void**>(f + 0x28);
            if (locals) v = *reinterpret_cast<uint64_t*>(locals);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { v = 0; }
    return v;
}

// Hunt the UFunction dispatch `call qword ptr [reg+0xB0]` in a code path:
// linear HDE walk, following up to 3 unconditional rel32 JMPs. POD-only so the
// caller's SEH guard covers it.
static bool scan_for_b0(uintptr_t p, uintptr_t base, uintptr_t size, int maxInstr) {
    int jumps = 0;
    int call_watch = 0;   // >0: saw `mov r64,[r+0xB0]`; expect a `call r64` shortly
    for (int i = 0; i < maxInstr; i++) {
        hde64s hs;
        unsigned int len = hde64_disasm(reinterpret_cast<void*>(p), &hs);
        if ((hs.flags & F_ERROR) || len == 0) return false;
        const bool disp_b0 = (hs.flags & F_DISP32) && hs.disp.disp32 == 0xB0;
        const unsigned mod = (hs.modrm >> 6) & 3;
        const unsigned reg = (hs.modrm >> 3) & 7;
        if (disp_b0 && hs.opcode == 0xFF && reg == 2) return true;        // call [r+0xB0]
        if (disp_b0 && hs.opcode == 0x8B) call_watch = 8;                 // mov r64,[r+0xB0]
        if (call_watch > 0) {
            if (hs.opcode == 0xFF && reg == 2 && mod == 3) return true;   // ... call r64
            call_watch--;
        }
        // do NOT stop at RET: ProcessEvent is branchy with many early returns
        // and the dispatch sits deep. INT3 padding marks the true function end.
        if (hs.opcode == 0xCC) return false;
        if (hs.opcode == 0xE9 && jumps < 3) {
            uintptr_t t = p + len + static_cast<int>(hs.imm.imm32);
            if (t < base || t >= base + size) return false;
            p = t; jumps++; continue;
        }
        p += len;
    }
    return false;
}

// A UE4SS-hooked function begins with an unconditional jump OUT of the game
// module (UE4SS hooks ProcessEvent to power Blueprint RegisterHooks -- which
// our pump tick hooks guarantee exist). That fingerprint identifies the
// ProcessEvent vtable entry without any body pattern-matching.
static bool entry_hook_jump(void* fn, uintptr_t base, uintptr_t size) {
    bool out = false;
    __try {
        uintptr_t p = reinterpret_cast<uintptr_t>(fn);
        if (p >= base && p < base + size) {
            hde64s hs;
            unsigned int len = hde64_disasm(reinterpret_cast<void*>(p), &hs);
            if (!(hs.flags & F_ERROR) && len > 0) {
                uintptr_t t = 0;
                if (hs.opcode == 0xE9) {
                    t = p + len + static_cast<int>(hs.imm.imm32);
                } else if (hs.opcode == 0xFF && ((hs.modrm >> 3) & 7) == 4 && hs.modrm == 0x25) {
                    uintptr_t slot = p + len + static_cast<int>(hs.disp.disp32);
                    t = *reinterpret_cast<uintptr_t*>(slot);
                }
                if (t && (t < base || t >= base + size)) out = true;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { out = false; }
    return out;
}

// vtable scan for ProcessEvent: the virtual that performs (or whose direct
// callee performs) the `call [reg+0xB0]` UFunction dispatch -- shipping builds
// may keep it in a non-inlined UFunction::Invoke, so direct CALL targets are
// searched one level deep too. SEH-guarded, runs once.
static bool pe_scan_entry(void* fn, uintptr_t base, uintptr_t size) {
    bool found = false;
    __try {
        uintptr_t p = reinterpret_cast<uintptr_t>(fn);
        if (p >= base && p < base + size) {
            if (scan_for_b0(p, base, size, 1200)) {
                found = true;
            } else {
                uintptr_t q = p;
                for (int i = 0; i < 1200 && !found; i++) {
                    hde64s hs;
                    unsigned int len = hde64_disasm(reinterpret_cast<void*>(q), &hs);
                    if ((hs.flags & F_ERROR) || len == 0) break;
                    if (hs.opcode == 0xE8) {
                        uintptr_t t = q + len + static_cast<int>(hs.imm.imm32);
                        if (t >= base && t < base + size && scan_for_b0(t, base, size, 600)) found = true;
                    }
                    if (hs.opcode == 0xCC) break;
                    q += len;
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { found = false; }
    return found;
}

static void pe_find(void* sampleObj) {
    g_pe_searched = true;
    __try {
        HMODULE h = GetModuleHandleW(nullptr);
        auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(h);
        auto nt  = reinterpret_cast<IMAGE_NT_HEADERS*>(reinterpret_cast<BYTE*>(h) + dos->e_lfanew);
        uintptr_t base = reinterpret_cast<uintptr_t>(h);
        uintptr_t size = nt->OptionalHeader.SizeOfImage;
        void** vt = *reinterpret_cast<void***>(sampleObj);
        g_pe_cand_n = 0;
        // gather ALL candidates -- the right ProcessEvent is picked later by
        // RESULT (whichever makes GetNpcLabel return a real value). UE4SS hooks
        // several virtuals, so the entry-jump fingerprint alone is ambiguous;
        // identify-by-result is what cracked the name resolver too.
        for (int i = 0; i < 150 && g_pe_cand_n < 24; i++) {            // pass 1: hook fingerprint
            if (entry_hook_jump(vt[i], base, size)) {
                g_pe_cand_idx[g_pe_cand_n] = i;
                g_pe_cands[g_pe_cand_n++] = vt[i];
            }
        }
        for (int i = 0; i < 150 && g_pe_cand_n < 24; i++) {            // pass 2: Func-dispatch body
            if (pe_scan_entry(vt[i], base, size)) {
                bool dup = false;
                for (int j = 0; j < g_pe_cand_n; j++) if (g_pe_cand_idx[j] == i) dup = true;
                if (!dup) { g_pe_cand_idx[g_pe_cand_n] = i; g_pe_cands[g_pe_cand_n++] = vt[i]; }
            }
        }
        // pass 3: known ProcessEvent vtable index for this build (location-validated
        // 2026-06-12). Vtable layout is fixed per binary, so seeding the exact index
        // means we NEVER call arbitrary slots (the slot-40..62 brute force corrupted
        // state and crashed on exit). Only this index + fingerprint hits get the
        // safe location validation; nothing else is ever invoked.
        const int knownPE[] = { 63 };
        for (int ki = 0; ki < (int)(sizeof(knownPE) / sizeof(knownPE[0])) && g_pe_cand_n < 24; ki++) {
            int idx = knownPE[ki];
            bool dup = false;
            for (int j = 0; j < g_pe_cand_n; j++) if (g_pe_cand_idx[j] == idx) dup = true;
            if (!dup) { g_pe_cand_idx[g_pe_cand_n] = idx; g_pe_cands[g_pe_cand_n++] = vt[idx]; }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { g_pe = nullptr; }
}

static bool pe_call(void* obj, void* fn, void* parms) {
    bool ok = false;
    __try { g_pe(obj, fn, parms); ok = true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { ok = false; }
    return ok;
}

static bool pe_try(void* pe, void* obj, void* fn, void* parms) {
    bool ok = false;
    __try { reinterpret_cast<FnProcessEvent>(pe)(obj, fn, parms); ok = true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { ok = false; }
    return ok;
}

// Validate a ProcessEvent candidate UNAMBIGUOUSLY: call K2_GetActorLocation
// through it and check the returned FVector is the actor's real (non-origin)
// world position. Unlike an FName (whose valid "empty" is 0, indistinguishable
// from a dead call), a placed actor's location is never origin -- so this tells
// "call works" from "call broken" with certainty.
static bool pe_loc_ok(void* pe, void* actor, void* locFn) {
    bool ok = false;
    __try {
        unsigned char buf[0x20];
        memset(buf, 0, sizeof(buf));
        reinterpret_cast<FnProcessEvent>(pe)(actor, locFn, buf);
        float x = *reinterpret_cast<float*>(buf + 0);
        float y = *reinterpret_cast<float*>(buf + 4);
        float z = *reinterpret_cast<float*>(buf + 8);
        float m = (x < 0 ? -x : x) + (y < 0 ? -y : y) + (z < 0 ? -z : z);
        if (m > 1.0f && m < 1.0e9f) ok = true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { ok = false; }
    return ok;
}

// Pick the real ProcessEvent from candidates by location result. SEH per try.
static bool pe_validate(void* actor, void* locFn) {
    if (g_pe) return true;
    if (!locFn) return false;
    for (int i = 0; i < g_pe_cand_n; i++) {
        if (pe_loc_ok(g_pe_cands[i], actor, locFn)) {
            g_pe = reinterpret_cast<FnProcessEvent>(g_pe_cands[i]);
            g_pe_idx = g_pe_cand_idx[i];
            g_pe_validated = true;
            return true;
        }
    }
    return false;
}

// Identify the GetTalkText impl among the pre-hook candidates by calling each
// with a label that REAL dialogue used; the one producing readable text wins.
static void gtt_identify(uint64_t lbl) {
    if (g_gtt_impl) return;
    if (lbl == 0) lbl = g_known_label;     // fall back to a label seen in real dialogue
    if (lbl == 0) return;
    for (int i = 0; i < g_gtt_cand_n; i++) {
        __try {
            memset(g_talk_buf, 0, sizeof(g_talk_buf));
            reinterpret_cast<FnTalkImpl>(g_gtt_cands[i])(lbl, g_talk_buf);
            wchar_t tmp[256];
            if (read_talktext_raw(g_talk_buf, tmp, 256) > 0) {
                g_gtt_impl = reinterpret_cast<FnTalkImpl>(g_gtt_cands[i]);
                break;
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {}
    }
}

void hk_gtt(void* ctx, void* frame, void* result) {
    if (g_gtt_orig) g_gtt_orig(ctx, frame, result);
    if (g_known_label == 0) {
        uint64_t lb = read_frame_label(frame);
        if (lb) g_known_label = lb;
    }
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
    uintptr_t ufunc = static_cast<uintptr_t>(luaL_checkinteger(L, 1));
    // collect GetTalkText impl candidates BEFORE MinHook patches the exec: the
    // NPC probe calls the impl directly (silent -- our hook never fires for it)
    if (ufunc >= 0x10000 && g_gtt_cand_n == 0) {
        void* exec = nullptr;
        __try { exec = *reinterpret_cast<void**>(ufunc + 0xB0); }
        __except (EXCEPTION_EXECUTE_HANDLER) { exec = nullptr; }
        uintptr_t rvas[16]; int cnt = 0;
        if (exec) find_impl_call(exec, rvas, &cnt, 16);
        uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
        for (int i = 0; i < cnt; i++) {
            int c = 0;
            for (int j = 0; j < cnt; j++) if (rvas[j] == rvas[i]) c++;
            if (c == 1 && g_gtt_cand_n < 16) g_gtt_cands[g_gtt_cand_n++] = base + rvas[i];
        }
    }
    bool ok = install_func_hook(ufunc,
                                reinterpret_cast<void*>(&hk_gtt), reinterpret_cast<void**>(&g_gtt_orig));
    lua_pushboolean(L, ok ? 1 : 0); return 1;
}

// NpcProbe(actorAddr, getPlacementDataUFuncAddr)
//   -> ok(bool), talkable(bool), name(string|nil), debug(string)
// Reads the NPC's placement row natively (TextLabel/EventLabels/path actions)
// and, when a TextLabel exists, asks the talk database for its entry to fetch
// the localized speaker name via the existing resolver. Fully SEH-guarded.
// NpcName(actorAddr) -> localized speaker name | nil. Reads the actor's cached
// PlacementData.TextLabel FName (actor + 0xA00 placement + 0x10 TextLabel) and
// resolves it through the talk database -> speaker handle -> localized name. All
// native, SEH-guarded, no contact required. The talk-DB and name resolvers
// self-arm by result on first use (no prior dialogue needed).
int l_npc_name(lua_State* L) {
    void* actor = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_checkinteger(L, 1)));
    uint64_t lbl = 0; int tlen = 0, nlen = 0;
    wchar_t namew[128]; namew[0] = L'\0';
    if (actor) {
        __try { lbl = *reinterpret_cast<uint64_t*>(reinterpret_cast<uintptr_t>(actor) + 0xA10); }
        __except (EXCEPTION_EXECUTE_HANDLER) { lbl = 0; }
    }
    // call KSTextStatics:GetTalkText as a real BP function through the VERIFIED
    // ProcessEvent (pe=63), not the disassembled-impl guess (impl=0 was that
    // guess failing). Params: Label(FName)@0, OutText(FTalkText)@8.
    void* cdo   = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_optinteger(L, 2, 0)));
    void* gtt   = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_optinteger(L, 3, 0)));
    void* locfn = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_optinteger(L, 4, 0)));
    if (actor && !g_pe_searched) pe_find(actor);
    if (actor && !g_pe) pe_validate(actor, locfn);
    int nnum = -1, tnum = -1;
    if ((uint32_t)(lbl & 0xFFFFFFFFu) != 0 && g_pe && cdo && gtt) {
        __try {
            memset(g_place_buf, 0, 0x400);
            *reinterpret_cast<uint64_t*>(g_place_buf) = lbl;     // Label @ 0
            g_pe(cdo, gtt, g_place_buf);                         // fills OutText @ 8
            void* tt = g_place_buf + 8;
            wchar_t tmp[256];
            tlen = read_talktext_raw(tt, tmp, 256);
            nnum = *reinterpret_cast<int*>(g_place_buf + 8 + 0x48);   // OutText.Names count
            tnum = *reinterpret_cast<int*>(g_place_buf + 8 + 0x58);   // OutText.Text count
            nlen = read_speaker(tt, namew, 128);                 // try the speaker even if text is empty
        } __except (EXCEPTION_EXECUTE_HANDLER) { tlen = 0; nlen = 0; }
    }
    if (nlen > 0) {
        char u8[256];
        int u = WideCharToMultiByte(CP_UTF8, 0, namew, nlen, u8, sizeof(u8) - 1, nullptr, nullptr);
        if (u > 0) lua_pushlstring(L, u8, static_cast<size_t>(u)); else lua_pushnil(L);
    } else {
        lua_pushnil(L);
    }
    char dbg[160];
    std::snprintf(dbg, sizeof(dbg), "lblidx=%u pe=%d tlen=%d nnum=%d tnum=%d nlen=%d",
                  (unsigned)(lbl & 0xFFFFFFFFu), g_pe ? 1 : 0, tlen, nnum, tnum, nlen);
    lua_pushstring(L, dbg);
    return 2;
}

int l_npc_probe(lua_State* L) {
    void* actor = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_checkinteger(L, 1)));
    void* pfn   = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_checkinteger(L, 2)));
    void* lfn   = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_optinteger(L, 3, 0)));
    void* locfn = reinterpret_cast<void*>(static_cast<uintptr_t>(luaL_optinteger(L, 4, 0)));
    if (!actor || !pfn) {
        lua_pushboolean(L, 0); lua_pushboolean(L, 0); lua_pushnil(L); lua_pushstring(L, "bad args");
        return 4;
    }
    if (!g_pe_searched) pe_find(actor);
    if (!g_pe) pe_validate(actor, locfn);   // identify the real ProcessEvent by KNOWN location
    if (!g_pe) {
        char dbg[96];
        std::snprintf(dbg, sizeof(dbg), "ProcessEvent unvalidated (cands=%d)", g_pe_cand_n);
        lua_pushboolean(L, 0); lua_pushboolean(L, 0); lua_pushnil(L); lua_pushstring(L, dbg);
        return 4;
    }
    memset(g_place_buf, 0, 0x400);
    if (!pe_call(actor, pfn, g_place_buf)) {
        lua_pushboolean(L, 0); lua_pushboolean(L, 0); lua_pushnil(L); lua_pushstring(L, "PE call faulted");
        return 4;
    }
    // PlacementInfoData offsets from the object dump (stable for this build):
    // TextLabel FName @0x10, InvalidRadarIcon @0x28, FCmd ids @0xA8..0xC0,
    // EventLabel_A..E FNames @0x128/0x190/0x1F8/0x260/0x2C8.
    int      textIdx   = *reinterpret_cast<int*>(g_place_buf + 0x10);
    uint64_t textFname = *reinterpret_cast<uint64_t*>(g_place_buf + 0x10);
    static const int evoff[5] = { 0x128, 0x190, 0x1F8, 0x260, 0x2C8 };
    static const int fcoff[4] = { 0xA8, 0xB0, 0xB8, 0xC0 };
    int ev = 0, fc = 0;
    for (int i = 0; i < 5; i++) if (*reinterpret_cast<int*>(g_place_buf + evoff[i]) != 0) ev++;
    for (int i = 0; i < 4; i++) if (*reinterpret_cast<int*>(g_place_buf + fcoff[i]) > 0) fc++;
    int noicon = g_place_buf[0x28] ? 1 : 0;
    // the NPC's own label (GetNpcLabel: a single FName out -- placement proved
    // all-zero on real maps, but the label keys the talk database directly)
    uint64_t nlabel = 0;
    if (lfn) {
        memset(g_place_buf, 0, 0x40);
        if (pe_call(actor, lfn, g_place_buf)) nlabel = *reinterpret_cast<uint64_t*>(g_place_buf);
    }
    // talk-database probe: prefer the placement TextLabel, else the npc label
    uint64_t probeLabel = (textIdx != 0) ? textFname : nlabel;
    int tlen = 0, nlen = 0;
    wchar_t namew[128]; namew[0] = L'\0';
    if ((int)(probeLabel & 0xFFFFFFFFu) != 0) {
        gtt_identify(probeLabel);
        if (g_gtt_impl) {
            __try {
                g_gtt_impl(probeLabel, g_talk_buf);
                wchar_t tmp[512];
                tlen = read_talktext_raw(g_talk_buf, tmp, 512);
                if (tlen > 0) nlen = read_speaker(g_talk_buf, namew, 128);
            } __except (EXCEPTION_EXECUTE_HANDLER) { tlen = 0; nlen = 0; }
        }
    }
    bool talkable = (textIdx != 0) || ev > 0 || fc > 0 || tlen > 0;
    lua_pushboolean(L, 1);
    lua_pushboolean(L, talkable ? 1 : 0);
    if (nlen > 0) {
        char u8[512];
        int u = WideCharToMultiByte(CP_UTF8, 0, namew, nlen, u8, sizeof(u8) - 1, nullptr, nullptr);
        if (u > 0) lua_pushlstring(L, u8, static_cast<size_t>(u)); else lua_pushnil(L);
    } else {
        lua_pushnil(L);
    }
    char dbg[224];
    std::snprintf(dbg, sizeof(dbg), "pe=%d cands=%d text=%d ev=%d fc=%d icon=%d lbl=%d tlen=%d nlen=%d gtt=%d",
                  g_pe_idx, g_pe_cand_n, textIdx, ev, fc, noicon, (int)(nlabel & 0xFFFFFFFFu), tlen, nlen, g_gtt_cand_n);
    lua_pushstring(L, dbg);
    return 4;
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
// Last resolved speaker display name (persists; nil until any dialogue spoke).
int l_last_speaker(lua_State* L) {
    std::lock_guard<std::mutex> lk(g_talk_mtx);
    if (!g_last_name.empty()) lua_pushlstring(L, g_last_name.data(), g_last_name.size());
    else lua_pushnil(L);
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
int l_audio_load_cue(lua_State* L) {
    lua_pushboolean(L, SA_LoadCue((int)luaL_checkinteger(L, 1), luaL_checkstring(L, 2)));
    return 1;
}
int l_audio_play_cue(lua_State* L) {
    SA_PlayCue((int)luaL_checkinteger(L, 1));
    return 0;
}

// ===== Keyboard guard: a low-level hook that OWNS our hotkey combos =====
// SetWindowsHookEx(WH_KEYBOARD_LL) sees every keystroke before the game's input
// layer. Registered combos (e.g. Ctrl+Enter, Ctrl+arrows) are swallowed -- the
// game never receives them (no more characters stepping on Ctrl+arrow, no NPC
// dialogue on Ctrl+Enter) -- and queued for Lua, which polls and dispatches.
// Scope-limited: only while the game window is foreground; our own SendInput
// arrows carry LLKHF_INJECTED and always pass; everything else passes to the
// next hook in the chain (screen readers keep their own hotkeys).
namespace keyguard {

// POD-only state guarded by a critical section: the hook proc runs on every
// keystroke system-wide, so it must be exception-armored (SEH) and free of C++
// unwinding -- no std containers in the hot path.
struct Combo { int vk; int ctrl, shift, alt; int id; };

CRITICAL_SECTION g_kcs;
LONG             g_kcs_init = 0;
Combo            g_combos[32];
int              g_combo_n = 0;
int              g_queue[64];
int              g_queue_n = 0;

void ensure_cs() {
    if (InterlockedCompareExchange(&g_kcs_init, 1, 0) == 0) {
        InitializeCriticalSection(&g_kcs);
        InterlockedExchange(&g_kcs_init, 2);
    }
    while (g_kcs_init != 2) Sleep(0);
}

bool game_foreground() {
    HWND fg = GetForegroundWindow();
    if (!fg) return false;
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);
    return pid == GetCurrentProcessId();
}

// POD body so the SEH wrapper below is legal; returns 1 to swallow, 0 to pass.
static int ll_match(WPARAM wp, LPARAM lp) {
    const KBDLLHOOKSTRUCT* k = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lp);
    if (k->flags & LLKHF_INJECTED) return 0;
    const int down = (wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN) ? 1 : 0;
    const int up   = (wp == WM_KEYUP   || wp == WM_SYSKEYUP) ? 1 : 0;
    if (!down && !up) return 0;
    if (!game_foreground()) return 0;
    const int ctrl  = (GetAsyncKeyState(VK_CONTROL) & 0x8000) ? 1 : 0;
    const int shift = (GetAsyncKeyState(VK_SHIFT)   & 0x8000) ? 1 : 0;
    const int alt   = ((GetAsyncKeyState(VK_MENU)   & 0x8000) != 0 || (k->flags & LLKHF_ALTDOWN) != 0) ? 1 : 0;
    int swallow = 0;
    EnterCriticalSection(&g_kcs);
    for (int i = 0; i < g_combo_n; i++) {
        const Combo& c = g_combos[i];
        if (c.vk == (int)k->vkCode && c.ctrl == ctrl && c.shift == shift && c.alt == alt) {
            if (down && g_queue_n < 64) g_queue[g_queue_n++] = c.id;
            swallow = 1;
            break;
        }
    }
    LeaveCriticalSection(&g_kcs);
    return swallow;
}

LRESULT CALLBACK ll_proc(int code, WPARAM wp, LPARAM lp) {
    int swallow = 0;
    if (code == HC_ACTION && g_kcs_init == 2) {
        __try { swallow = ll_match(wp, lp); }
        __except (EXCEPTION_EXECUTE_HANDLER) { swallow = 0; }
    }
    if (swallow) return 1;
    return CallNextHookEx(nullptr, code, wp, lp);
}

DWORD WINAPI thread_main(LPVOID) {
    SetWindowsHookExW(WH_KEYBOARD_LL, ll_proc, GetModuleHandleW(nullptr), 0);
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

void ensure_started() {
    static std::once_flag once;
    std::call_once(once, [] {
        ensure_cs();
        HANDLE h = CreateThread(nullptr, 0, thread_main, nullptr, 0, nullptr);
        if (h) CloseHandle(h);
    });
}

} // namespace keyguard

// Hold/release the arrow keys via synthesized hardware input (SendInput), so the
// auto-walk drives the game through its OWN input path: native walk speed,
// footstep sounds, animations, encounters. Args: up, down, left, right (booleans).
// Diff-based: events are only sent on state transitions; all keys must be
// released by calling with four falses (the Lua walker does this on every stop).
void send_arrow_key(WORD vk, bool down) {
    INPUT in{};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.wScan = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    in.ki.dwFlags = KEYEVENTF_EXTENDEDKEY | (down ? 0 : KEYEVENTF_KEYUP);
    SendInput(1, &in, sizeof(INPUT));
}
int l_hold_keys(lua_State* L) {
    static bool held[4] = { false, false, false, false };
    static const WORD vks[4] = { VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT };
    for (int i = 0; i < 4; ++i) {
        bool want = lua_toboolean(L, i + 1) != 0;
        if (want != held[i]) {
            send_arrow_key(vks[i], want);
            held[i] = want;
        }
    }
    return 0;
}

// GuardCombo(id, vk, ctrl, shift, alt): register a combo to swallow + queue.
int l_guard_combo(lua_State* L) {
    keyguard::ensure_started();
    keyguard::Combo c;
    c.id    = (int)luaL_checkinteger(L, 1);
    c.vk    = (int)luaL_checkinteger(L, 2);
    c.ctrl  = lua_toboolean(L, 3) ? 1 : 0;
    c.shift = lua_toboolean(L, 4) ? 1 : 0;
    c.alt   = lua_toboolean(L, 5) ? 1 : 0;
    EnterCriticalSection(&keyguard::g_kcs);
    if (keyguard::g_combo_n < 32) keyguard::g_combos[keyguard::g_combo_n++] = c;
    LeaveCriticalSection(&keyguard::g_kcs);
    return 0;
}

// GuardPoll() -> array of combo ids pressed since the last poll.
int l_guard_poll(lua_State* L) {
    int ids[64]; int n = 0;
    if (keyguard::g_kcs_init == 2) {
        EnterCriticalSection(&keyguard::g_kcs);
        n = keyguard::g_queue_n;
        for (int i = 0; i < n; ++i) ids[i] = keyguard::g_queue[i];
        keyguard::g_queue_n = 0;
        LeaveCriticalSection(&keyguard::g_kcs);
    }
    lua_createtable(L, n, 0);
    for (int i = 0; i < n; ++i) {
        lua_pushinteger(L, ids[i]);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
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
    {"AudioLoadCue",         l_audio_load_cue},
    {"AudioPlayCue",         l_audio_play_cue},
    {"HoldKeys",             l_hold_keys},
    {"GuardCombo",           l_guard_combo},
    {"GuardPoll",            l_guard_poll},
    {"NpcProbe",             l_npc_probe},
    {"NpcName",              l_npc_name},
    {"LastSpeakerName",      l_last_speaker},
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
