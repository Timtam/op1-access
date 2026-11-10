// Speech output for OP1Access via Prism (https://github.com/ethindp/prism,
// MPL-2.0), statically linked. Replaces Tolk: nothing needs to sit next to the
// shim any more (no Tolk.dll / nvdaControllerClient64.dll / SAAPI64.dll) --
// Prism talks to NVDA through RPC stubs compiled into it.
//
// Threading: Prism backend instances are not thread-safe, and speech requests
// come from the game thread (native GetTalkText hook) and from UE4SS's Lua
// threads. So one worker thread owns the Prism context and backend; everyone
// else only pushes onto a queue. That also keeps NVDA RPC / JAWS COM calls off
// the game thread, and gives the COM-based backends a known apartment (MTA).
//
// Backend choice: prism_registry_create_best (NVDA > JAWS > ... > OneCore >
// UIA/SAPI). Prism never switches by itself, so we re-select when its
// availability poll reports that our backend went away or a better one appeared
// (screen reader started after the game), and when a speak call fails (NVDA
// restarted: Prism never re-binds the old RPC endpoint).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include <prism.h>

#include "Speech.h"

namespace speech {
namespace {

enum class Op { Output, Stop };

struct Item {
    Op          op;
    bool        interrupt;
    std::string text;
};

constexpr size_t kMaxQueue = 64;   // a stuck backend must not grow the queue forever

std::once_flag             g_start_once;
std::atomic<PrismContext*> g_ctx{nullptr};    // read by Prism's poll thread

std::mutex              g_mtx;                // guards everything below
std::condition_variable g_work_cv;            // worker: items queued / reselect requested
std::condition_variable g_ready_cv;           // is_supported(): first selection done
std::deque<Item>        g_queue;
bool                    g_reselect    = false;
bool                    g_prefer_sapi = false;
bool                    g_ready       = false;
bool                    g_can_speak   = false;
std::string             g_name;               // active backend, "" if none
PrismBackendId          g_cur_id      = 0;    // PRISM_BACKEND_INVALID if none
int                     g_cur_prio    = -1;

// Worker-thread only.
PrismBackend* w_backend     = nullptr;
uint64_t      w_features    = 0;
ULONGLONG     w_last_select = 0;

void request_reselect() {
    { std::lock_guard<std::mutex> lk(g_mtx); g_reselect = true; }
    g_work_cv.notify_one();
}

// Runs on Prism's availability poll thread. It MUST NOT block or call
// prism_shutdown, so it only decides whether the worker should re-select.
// Unrelated flapping (e.g. UIA listeners coming and going) is ignored:
// re-creating a speech engine would cut off the line being spoken.
void PRISM_CALL on_availability(void*, PrismBackendId id, const char*, bool available) {
    PrismContext* ctx = g_ctx.load();
    const int prio = (ctx && available) ? prism_registry_priority(ctx, id) : -1;
    bool need = false;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (!available)
            need = (id == g_cur_id);                    // our backend went away
        else
            need = !g_prefer_sapi && (g_cur_id == 0 || prio > g_cur_prio);
        if (need) g_reselect = true;
    }
    if (need) g_work_cv.notify_one();
}

void publish(PrismContext* ctx, const char* name, bool can_speak) {
    const std::string n = name ? name : "";
    const PrismBackendId id = (ctx && !n.empty()) ? prism_registry_id(ctx, n.c_str()) : 0;
    const int prio = (ctx && id != 0) ? prism_registry_priority(ctx, id) : -1;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_name = n;
        g_can_speak = can_speak;
        g_cur_id = id;
        g_cur_prio = prio;
        g_ready = true;
    }
    g_ready_cv.notify_all();
}

void select_backend() {
    w_last_select = GetTickCount64();
    w_features = 0;
    if (w_backend) { prism_backend_free(w_backend); w_backend = nullptr; }
    PrismContext* ctx = g_ctx.load();
    if (!ctx) { publish(nullptr, nullptr, false); return; }

    bool prefer = false;
    { std::lock_guard<std::mutex> lk(g_mtx); prefer = g_prefer_sapi; }
    if (prefer) {
        if (PrismBackend* b = prism_registry_create(ctx, PRISM_BACKEND_SAPI)) {
            if (prism_backend_initialize(b) == PRISM_OK) w_backend = b;
            else prism_backend_free(b);
        }
    }
    if (!w_backend) w_backend = prism_registry_create_best(ctx);   // already initialized
    if (!w_backend) { publish(ctx, nullptr, false); return; }

    w_features = prism_backend_get_features(w_backend);
    publish(ctx, prism_backend_name(w_backend), (w_features & PRISM_BACKEND_SUPPORTS_SPEAK) != 0);
}

// Game text is UTF-8, but Lua-side slicing can split a multi-byte character and
// Prism rejects the whole line on invalid UTF-8. Round-trip through UTF-16 the
// way Tolk's input path did: bad bytes become U+FFFD, the rest is still spoken.
std::string sanitize_utf8(const std::string& s) {
    bool ascii = true;
    for (unsigned char c : s) if (c >= 0x80) { ascii = false; break; }
    if (ascii) return s;
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (n <= 0) return std::string();
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    const int m = WideCharToMultiByte(CP_UTF8, 0, w.data(), n, nullptr, 0, nullptr, nullptr);
    if (m <= 0) return std::string();
    std::string out(static_cast<size_t>(m), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), n, out.data(), m, nullptr, nullptr);
    return out;
}

// Speech + braille, like Tolk_Output. Not prism_backend_output: that reports a
// braille failure after the line was already spoken, and our dead-backend
// retry would then say it twice. Braille is best effort.
PrismError say(const std::string& text, bool interrupt) {
    const PrismError e = prism_backend_speak(w_backend, text.c_str(), interrupt);
    if (e == PRISM_OK && (w_features & PRISM_BACKEND_SUPPORTS_BRAILLE))
        (void)prism_backend_braille(w_backend, text.c_str());
    return e;
}

void speak_one(const std::string& raw, bool interrupt) {
    if (!w_backend) {
        // Nothing usable last time: retry at most every 2 s, not once per line.
        if (GetTickCount64() - w_last_select < 2000) return;
        select_backend();
        if (!w_backend) return;
    }
    const std::string text = sanitize_utf8(raw);
    if (text.empty()) return;
    const PrismError e = say(text, interrupt);
    if (e == PRISM_OK || e == PRISM_ERROR_INVALID_UTF8 || e == PRISM_ERROR_INVALID_PARAM) return;
    // The backend died under us (NVDA restarted, ...). Pick again and give
    // this line one more try.
    select_backend();
    if (w_backend) (void)say(text, interrupt);
}

void worker_main() {
    SetThreadDescription(GetCurrentThread(), L"OP1Access speech");
    // JAWS / ZoomText / SenseReader are COM servers; Prism expects COM to be
    // initialized on the calling thread.
    (void)CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    PrismConfig cfg = prism_config_init();
    cfg.availability_callback = on_availability;   // starts Prism's poll thread
    g_ctx.store(prism_init(&cfg));
    select_backend();

    for (;;) {
        Item it{Op::Stop, false, {}};
        bool reselect = false;
        {
            std::unique_lock<std::mutex> lk(g_mtx);
            g_work_cv.wait(lk, [] { return g_reselect || !g_queue.empty(); });
            if (g_reselect) { g_reselect = false; reselect = true; }
            else { it = std::move(g_queue.front()); g_queue.pop_front(); }
        }
        try {
            if (reselect)                select_backend();
            else if (it.op == Op::Stop)  { if (w_backend) (void)prism_backend_stop(w_backend); }
            else                         speak_one(it.text, it.interrupt);
        } catch (...) {
            // bad_alloc while copying a line: drop it, keep the worker alive.
        }
    }
}

void start() {
    std::call_once(g_start_once, [] {
        // The worker and Prism's poll thread run our code for the rest of the
        // process, so the DLL must never be unloaded under them (e.g. when
        // UE4SS restarts the Lua mods). Pin it.
        HMODULE self = nullptr;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                           reinterpret_cast<LPCWSTR>(&worker_main), &self);
        try {
            std::thread(worker_main).detach();
        } catch (...) {
            publish(nullptr, nullptr, false);
        }
    });
}

void push(Item&& it) {
    start();
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        // Interrupting speech also discards what has not been spoken yet: the
        // screen reader would cut it off anyway.
        if (it.op == Op::Stop || it.interrupt) g_queue.clear();
        while (g_queue.size() >= kMaxQueue) g_queue.pop_front();
        g_queue.push_back(std::move(it));
    }
    g_work_cv.notify_one();
}

void wait_ready() {
    start();
    std::unique_lock<std::mutex> lk(g_mtx);
    g_ready_cv.wait_for(lk, std::chrono::seconds(3), [] { return g_ready; });
}

}  // namespace

void output(const char* utf8, size_t len, bool interrupt) {
    if (!utf8 || len == 0) return;
    push(Item{Op::Output, interrupt, std::string(utf8, len)});
}

void silence() {
    push(Item{Op::Stop, true, {}});
}

bool is_supported() {
    wait_ready();
    std::lock_guard<std::mutex> lk(g_mtx);
    return g_can_speak;
}

std::string backend_name() {
    wait_ready();
    std::lock_guard<std::mutex> lk(g_mtx);
    return g_name;
}

void prefer_sapi(bool prefer) {
    start();
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (g_prefer_sapi == prefer) return;
        g_prefer_sapi = prefer;
    }
    request_reselect();
}

}  // namespace speech
