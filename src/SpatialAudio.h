#pragma once
// C API for the OP1Access spatial-audio module: Steam Audio (phonon) HRTF binaural
// rendering + miniaudio device output. Each "source" is a positioned beacon; the
// listener is the player. Orientation is screen-fixed (the overworld camera does
// not rotate), so world deltas map to a constant listener frame. Phase 4 / Pillar A.
#ifdef __cplusplus
extern "C" {
#endif

// Initialize the audio device + Steam Audio. Returns 1 on success, 0 on failure
// (call SA_Status for a message). Safe to call once; re-calling while running is a
// no-op that returns 1.
int  SA_Init(void);

// Stop + tear everything down. Safe to call repeatedly.
void SA_Shutdown(void);

// Set the listener (player) world position. Cheap; call every frame.
void SA_SetListener(float x, float y, float z);

// Set/update beacon source `id` (0..SA_MaxSources-1). active=0 silences it.
// (x,y,z) is a world position; direction + distance are derived vs the listener.
void SA_SetSource(int id, int active, float x, float y, float z);

// Quick isolation test independent of game data: play one continuous tone at a
// fixed listener-relative direction. dir: 0=right 1=left 2=front 3=back 4=off.
void SA_TestTone(int dir);

// Number of source slots.
int  SA_MaxSources(void);

// Last status / error message (never NULL).
const char* SA_Status(void);

#ifdef __cplusplus
}
#endif
