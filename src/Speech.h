#pragma once
// Screen-reader / TTS output through Prism (https://github.com/ethindp/prism,
// MPL-2.0), statically linked into OP1AccessShim.dll.
//
// All Prism calls run on one dedicated worker thread: callers (game thread,
// UE4SS Lua threads) only queue text, never block on a screen reader, and the
// backend is never touched from two threads at once.

#include <cstddef>
#include <string>

namespace speech {

// Queue UTF-8 text for speech (+ braille where the backend has it).
// interrupt=true cuts current speech
// and drops anything still queued (menu navigation); false speaks after what
// is already pending.
void output(const char* utf8, size_t len, bool interrupt);

// Stop speech and drop the queue.
void silence();

// True once a backend that can speak is active. Waits (at most 3 s) for the
// first backend selection, which the worker runs as soon as it starts.
bool is_supported();

// Active backend ("NVDA", "JAWS", "OneCore", "SAPI", ...); "" if none.
std::string backend_name();

// true: use SAPI even while a screen reader runs; false: automatic (default).
void prefer_sapi(bool prefer);

}  // namespace speech
