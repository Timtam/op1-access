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

// Audible ranges in world units: objects fade from loud to silent over objRange, walls
// (cueType 5) over wallRange, and the ping rate spans the same distances. Defaults 1500
// and 450; values out of bounds are ignored.
void SA_SetRanges(float objRange, float wallRange);

// Set/update beacon source `id` (0..SA_MaxSources-1). active=0 silences it.
// (x,y,z) is a world position; direction + distance are derived vs the listener.
// cueType selects the per-category ping frequency (0=chest, 1=exit, 2=npc).
void SA_SetSource(int id, int active, float x, float y, float z, int cueType);

// Load a custom cue sound for a category (cueType 0..8) from a file. Format is
// auto-detected: WAV, FLAC, or MP3 (FLAC/MP3 keep files small). Decoded to mono at
// the engine rate and played per ping in place of the generated tone. Returns 1 on
// success, 0 if the file is missing or cannot be decoded.
int  SA_LoadCue(int cueType, const char* path);

// Play a cue once (non-looping, 2D / centred), e.g. a wall-bump. If that cueType has
// no loaded buffer, a generated fallback is played instead (6 bump: thud, 7 door:
// rising chirp, 8 path action available: two-note chime).
void SA_PlayCue(int cueType);

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
