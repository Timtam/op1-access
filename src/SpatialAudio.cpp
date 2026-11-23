// SpatialAudio.cpp -- HRTF-positioned audio cues for OP1Access.
//
// Steam Audio (phonon) does the binaural DSP; miniaudio owns the output device.
// Each beacon is a mono cue source; in the audio thread we generate its samples,
// run Steam Audio's binaural effect for its current listener-relative direction,
// and mix all sources to stereo. A fixed-block renderer bridges miniaudio's
// variable callback size to Steam Audio's fixed 1024-sample frame.
//
// Cues are PERIODIC PINGS (a short enveloped tone repeating every CYCLE_LEN), with
// a per-category frequency, so many simultaneous beacons stay legible instead of
// blurring into a drone. Pings are staggered by source slot (a phase offset on a
// global sample clock) so they don't all fire at once. The test tone is a
// continuous tone (ping=false) for clean HRTF debugging.
//
// Threading: the game thread calls SA_SetListener / SA_SetSource (writes a few
// fields + an active flag under a short mutex). The audio thread reads a snapshot
// each block. Each source's oscillator phase + binaural effect are audio-thread
// only. Effects/HRTF/context are created on the game thread in SA_Init and unused
// after SA_Shutdown stops the device.
//
// Coordinate mapping (screen-fixed, since the overworld camera doesn't rotate):
//   game world X = the UP/DOWN screen axis (UP = +X)    -> Steam Audio front (-Z)
//   game world Y = the LEFT/RIGHT screen axis (RIGHT=+Y) -> Steam Audio right (+X)
//   game world Z = vertical                              -> Steam Audio up   (+Y)

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <windows.h>   // GetForegroundWindow (miniaudio already pulls it in on Windows)

extern "C" {
#include "phonon.h"
}

#include <mutex>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <vector>

#include "SpatialAudio.h"

namespace {

constexpr int    SR  = 48000;   // sample rate
constexpr int    FS  = 1024;    // Steam Audio frame size (samples/channel)
constexpr int    MAX_SOURCES = 32;
constexpr double TWO_PI = 6.283185307179586;

constexpr int    ATTACK    = (int)(0.012 * SR);  // ping attack ramp
constexpr int    PING_FAST = (int)(0.22 * SR);   // cycle length when near (fast pings)
constexpr int    PING_SLOW = (int)(1.50 * SR);   // cycle length when far (slow pings)
constexpr int    CUE_MAX   = (int)(0.13 * SR);   // max ping (cue) duration
constexpr float  PING_NEAR = 100.0f;             // distance (units) at/below which an object pings fastest
                                                 // (slowest at the edge of its range, g_objRange)
constexpr int    PING_STAGGER = 4000;            // per-slot phase offset so pings don't all align
constexpr int    PING_MINGAP  = (int)(0.05 * SR); // min silence after a loaded cue before it repeats

IPLContext       g_ctx   = nullptr;
IPLHRTF          g_hrtf  = nullptr;
IPLAudioSettings g_audio = { SR, FS };

IPLAudioBuffer   g_inBuf  = {};   // 1 channel x FS (mono source input)
IPLAudioBuffer   g_outBuf = {};   // 2 channels x FS (binaural output)

ma_device        g_device = {};
bool             g_deviceOk = false;
bool             g_running  = false;

char             g_status[256] = "uninitialized";

struct Source {
    bool   active       = false;
    bool   listenerSpace = false;  // true: (x,y,z) is already a listener-space dir (test tone)
    bool   ping         = true;    // true: periodic ping; false: continuous tone (test)
    int    cueType      = 0;       // category -> ping frequency (see cue_freq)
    float  x = 0, y = 0, z = 0;    // world position (or listener-space dir if listenerSpace)
    float  gain = 0.7f;
    double phase = 0.0;            // oscillator phase (audio-thread only)
    float  env = 0.0f;            // smoothed on/off gain (declick fade; audio-thread only)
    float  lpL = 0.0f, lpR = 0.0f; // rear-darkening LPF state (audio-thread only)
    // smoothing and the ping clock (audio-thread only; see render_block)
    long long cyclePos = -1;       // position in its ping cycle (-1: not started)
    int    pingLen = 0;            // the ping playing now: its length and cue, latched at its start
    int    pingCue = -1;
    float  rateDist = 0.0f;        // the distance the ping rate follows, smoothed
    float  dryS = 0.0f, sendS = 0.0f;               // smoothed gains
    float  dryPrev = 0.0f, sendPrev = 0.0f, dkPrev = 0.0f;   // the last block's, ramped from
    float  dirX = 0.0f, dirY = 0.0f, dirZ = -1.0f;  // smoothed direction
    bool   warm = false;           // the smoothers hold values (cleared once fully silent)
    IPLBinauralEffect effect = nullptr;
};

Source     g_src[MAX_SOURCES];
float      g_lx = 0, g_ly = 0, g_lz = 0;   // listener world position
std::mutex g_mtx;

constexpr int NUM_CUES = 10;                // cue types 0..9 (chest/exit/npc/building/shop/wall/bump/door/pathaction/talk)
float* g_cueBuf[NUM_CUES] = { nullptr };    // decoded mono @ SR samples per category (null = generated tone)
int    g_cueLen[NUM_CUES] = { 0 };

// one-shot (non-looping, 2D) cue, e.g. the wall-bump. -1 = nothing playing.
constexpr int THUD_LEN  = (int)(0.15 * SR);  // generated fallback thud length (bump)
constexpr int SWEEP_LEN = (int)(0.28 * SR);  // generated fallback chirp length (door)
constexpr int CHIME_LEN = (int)(0.26 * SR);  // generated fallback chime length (path action available)
constexpr int TALK_LEN  = (int)(0.15 * SR);  // generated fallback pop length (someone to talk to)
int g_osCue = -1;
int g_osPos = 0;

float g_block[FS * 2];              // one rendered stereo block, interleaved L,R,...
int   g_blockPos = FS;             // frames consumed; start "empty" so first callback renders
unsigned long long g_clock = 0;    // global sample clock for ping staggering (audio thread)

// Silent while another app is in front, as the game is: UE4 mutes it then
// (UnfocusedVolumeMultiplier 0), "focused" meaning the foreground window belongs to this
// process (FWindowsPlatformProcess::IsThisApplicationForeground, the same test as the
// shim's IsForeground). The game went quiet when minimized and the radar kept pinging
// (user, 2026-11-16). Checked once per block (~21 ms) on the audio thread; the whole mix
// fades out and in over MASTER_FADE.
float g_master = 1.0f;                  // focus gain (audio thread only)
constexpr float MASTER_FADE = 0.04f;    // seconds for a full fade

bool app_in_front() {
    HWND h = GetForegroundWindow();
    if (!h) return false;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    return pid == GetCurrentProcessId();
}

void set_status(const char* s) { std::snprintf(g_status, sizeof(g_status), "%s", s); }

float cue_freq(int cueType) {
    switch (cueType) {
        case 0:  return 523.0f;  // chest
        case 1:  return 392.0f;  // exit / area transition
        case 2:  return 698.0f;  // npc
        case 3:  return 294.0f;  // building entrance (low "doorway")
        case 4:  return 880.0f;  // shop (high)
        case 5:  return 200.0f;  // wall (continuous low hum)
        default: return 523.0f;
    }
}

IPLVector3 normalize_or_front(float x, float y, float z) {
    IPLVector3 v{ x, y, z };
    float len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len < 1e-5f) { v.x = 0.0f; v.y = 0.0f; v.z = -1.0f; return v; }
    v.x /= len; v.y /= len; v.z /= len;
    return v;
}

IPLVector3 world_delta_to_sa(float ddx, float ddy, float ddz) {
    // Geometric mapping, anchored to TWO confirmed-by-ear ground truths: the
    // listener-space test tones verified the renderer (SA +X = right ear, -Z =
    // front), and the Ctrl+F8 walk calibration verified the world axes (+Y =
    // right-arrow side, +X = up-arrow side). Therefore: right-arrow side -> right
    // ear (x=+ddy), up-arrow side -> front (z=-ddx), world up -> SA up (y=+ddz).
    // (An earlier -ddy flip was chasing a wall report that was almost certainly a
    // perception artifact -- pure 200 Hz tones barely lateralize. The Ctrl+F7
    // world-relative test phases are the ground-truth arbiter for this mapping.)
    // WIDEN exaggerates azimuth to separate close-together sources, but it WARPS the
    // angle field: walking straight toward an off-axis source makes it swing sideways
    // faster than geometry, which reads as "diagonal drift". Keep 1.0 (pure geometry)
    // unless separation proves more important than consistency.
    constexpr float WIDEN = 1.0f;
    return normalize_or_front(ddy * WIDEN, ddz, -ddx);
}

// Audible ranges (world units; SA_SetRanges): objects fade out over g_objRange, walls
// over g_wallRange, and the ping rate spans the same distances (fast near, slow at the
// edge). Written on the game thread under g_mtx, read once per block.
float g_objRange  = 1500.0f;
float g_wallRange = 450.0f;

// VOLUME OVER DISTANCE (2026-11-23, user: walls were only loud or very loud, never quiet,
// and objects could be heard only 4-5 steps away). It was (1 - d/550)^1.5 for objects
// (silent past ~450) and 120/d capped to 0.25..1.6 for walls traced only to 175, so a wall
// was always 0.69..1.6. Now inverse distance -- each doubling of the distance 6 dB
// quieter, which the ear reads as distance -- from a reference distance on (full volume
// closer in; a wall you are pressed against up to +4 dB), and a linear fade to silence
// over the last 30 % (objects) / 40 % (walls) of the range:
//   objects (ref 150, range 1500): 150 0 dB, 300 -6, 600 -12, 1000 -16, 1200 -22, 1400 -32
//   walls   (ref 80,  range 450):  50 +4 dB, 80 0, 160 -6, 270 -11, 320 -15, 400 -25
float dist_attenuation(float dist, bool wall, float range) {
    if (dist >= range) return 0.0f;
    const float ref = wall ? 80.0f : 150.0f;
    const float cap = wall ? 1.6f : 1.0f;
    float g = ref / (dist > 1.0f ? dist : 1.0f);
    if (g > cap) g = cap;
    const float fadeFrom = (wall ? 0.6f : 0.7f) * range;
    if (dist > fadeFrom) g *= 1.0f - (dist - fadeFrom) / (range - fadeFrom);
    return g;
}

// --- light Freeverb-style stereo reverb: room ambience to externalize the cues
// (sounds outside the head are easier to localize + tell apart). Applied to the
// whole mix; dry stays at full level so cues never get quieter from it.
constexpr int   RV_COMB = 4, RV_AP = 2;
constexpr int   rvCombL[RV_COMB] = { 1214, 1293, 1390, 1476 };
constexpr int   rvCombR[RV_COMB] = { 1237, 1316, 1413, 1499 };
constexpr int   rvApL[RV_AP]     = { 605, 480 };
constexpr int   rvApR[RV_AP]     = { 628, 503 };
constexpr float RV_FB = 0.80f, RV_DAMP = 0.25f, RV_APFB = 0.5f;
float g_rvWet = 0.10f;            // master wet level (tunable)
// reverb SEND rises with distance: the direct sound drops (attenuation) while the
// room's reverberant field stays ~constant, so the wet/dry ratio grows with
// distance -- the natural "farther = more reverberant" cue.
constexpr float REV_NEAR = 150.0f, REV_FAR = 2500.0f;
constexpr float REV_SEND_MIN = 0.10f, REV_SEND_MAX = 0.80f;
inline float send_factor(float dist) {
    float t = (dist - REV_NEAR) / (REV_FAR - REV_NEAR);
    if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
    return REV_SEND_MIN + t * (REV_SEND_MAX - REV_SEND_MIN);
}
float rvCombBufL[RV_COMB][1600], rvCombBufR[RV_COMB][1600];
int   rvCombPosL[RV_COMB] = {0},  rvCombPosR[RV_COMB] = {0};
float rvCombStL[RV_COMB]  = {0},  rvCombStR[RV_COMB]  = {0};
float rvApBufL[RV_AP][700], rvApBufR[RV_AP][700];
int   rvApPosL[RV_AP] = {0}, rvApPosR[RV_AP] = {0};

inline float rv_comb(float in, float* buf, int len, int& pos, float& st) {
    float out = buf[pos];
    st = out * (1.0f - RV_DAMP) + st * RV_DAMP;
    buf[pos] = in + st * RV_FB;
    if (++pos >= len) pos = 0;
    return out;
}
inline float rv_ap(float in, float* buf, int len, int& pos) {
    float bo = buf[pos];
    float out = bo - in;
    buf[pos] = in + bo * RV_APFB;
    if (++pos >= len) pos = 0;
    return out;
}
void reverb_process(float* L, float* R) {
    for (int i = 0; i < FS; ++i) {
        float input = (L[i] + R[i]) * 0.5f;
        float wL = 0.0f, wR = 0.0f;
        for (int c = 0; c < RV_COMB; ++c) wL += rv_comb(input, rvCombBufL[c], rvCombL[c], rvCombPosL[c], rvCombStL[c]);
        for (int c = 0; c < RV_COMB; ++c) wR += rv_comb(input, rvCombBufR[c], rvCombR[c], rvCombPosR[c], rvCombStR[c]);
        for (int a = 0; a < RV_AP; ++a)   wL = rv_ap(wL, rvApBufL[a], rvApL[a], rvApPosL[a]);
        for (int a = 0; a < RV_AP; ++a)   wR = rv_ap(wR, rvApBufR[a], rvApR[a], rvApPosR[a]);
        L[i] = wL * g_rvWet;   // output the WET only (caller adds it to the dry mix)
        R[i] = wR * g_rvWet;
    }
}

void render_block() {
    static float mixL[FS];
    static float mixR[FS];
    static float revSendL[FS];
    static float revSendR[FS];
    const bool front = app_in_front();
    if (!front && g_master <= 0.0f) {
        // in the background and faded out: nothing to render. A one-shot cue fired
        // meanwhile is dropped, not kept for later.
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            g_osCue = -1;
        }
        std::memset(g_block, 0, sizeof(g_block));
        g_clock += (unsigned long long)FS;
        g_blockPos = 0;
        return;
    }
    std::memset(mixL, 0, sizeof(mixL));
    std::memset(mixR, 0, sizeof(mixR));
    std::memset(revSendL, 0, sizeof(revSendL));
    std::memset(revSendR, 0, sizeof(revSendR));

    if (g_running && g_ctx && g_hrtf) {
        float objRange, wallRange;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            objRange = g_objRange; wallRange = g_wallRange;
        }
        for (int i = 0; i < MAX_SOURCES; ++i) {
            Source& S = g_src[i];   // (its audio-thread-only fields are read and written freely)
            bool active, lspace, ping; int cueType; float sx, sy, sz, gain, lx, ly, lz;
            const float* cueBuf = nullptr; int cueBufLen = 0;     // the source's cue now
            const float* pBuf = nullptr; int pBufLen = 0;         // the cue of the ping playing
            {
                std::lock_guard<std::mutex> lk(g_mtx);
                active  = S.active;
                lspace  = S.listenerSpace;
                ping    = S.ping;
                cueType = S.cueType;
                sx = S.x; sy = S.y; sz = S.z;
                gain = S.gain;
                lx = g_lx; ly = g_ly; lz = g_lz;
                if (cueType >= 0 && cueType < NUM_CUES) { cueBuf = g_cueBuf[cueType]; cueBufLen = g_cueLen[cueType]; }
                if (S.pingCue >= 0 && S.pingCue < NUM_CUES) { pBuf = g_cueBuf[S.pingCue]; pBufLen = g_cueLen[S.pingCue]; }
            }
            if (!S.effect) continue;
            if (!active && S.env <= 0.0005f) {
                // fully faded out: silent, and the next activation starts afresh
                S.warm = false; S.cyclePos = -1; S.pingLen = 0; S.pingCue = -1;
                S.dryPrev = 0.0f; S.sendPrev = 0.0f;
                continue;
            }

            // direction + distance FIRST: distance drives both attenuation and the
            // ping rate (closer = faster pings).
            float ddx = 0.0f, ddy = 0.0f, ddz = 0.0f, dist = 0.0f, atten = 1.0f;
            const bool wall = (cueType == 5);
            IPLVector3 dir;
            if (lspace) {
                dir = normalize_or_front(sx, sy, sz);
            } else {
                ddx = sx - lx; ddy = sy - ly; ddz = sz - lz;
                dist = std::sqrt(ddx * ddx + ddy * ddy + ddz * ddz);
                dir = world_delta_to_sa(ddx, ddy, ddz);
                atten = dist_attenuation(dist, wall, wall ? wallRange : objRange);
            }

            // SMOOTHED (2026-11-23, user: the walls crackled while walking, fine standing).
            // Gain, direction and the distance the ping rate follows used to change in
            // steps, once per block (21 ms) -- and a wall's point jumps where its trace
            // meets another surface. Now each follows its target smoothly (one-pole, per
            // block), and the gains are ramped sample by sample within the block.
            const float dryT  = gain * atten;               // direct sound: drops with distance
            const float sendT = gain * send_factor(dist);   // reverb send: rises with distance
            if (!S.warm) {
                S.rateDist = dist; S.dryS = dryT; S.sendS = sendT;
                S.dirX = dir.x; S.dirY = dir.y; S.dirZ = dir.z;
                S.warm = true;
            } else {
                constexpr float K_RATE = 0.13f;   // ~150 ms: the rhythm eases into a new distance
                constexpr float K_GAIN = 0.35f;   // ~50 ms
                constexpr float K_DIR  = 0.41f;   // ~40 ms
                S.rateDist += (dist - S.rateDist) * K_RATE;
                S.dryS     += (dryT - S.dryS) * K_GAIN;
                S.sendS    += (sendT - S.sendS) * K_GAIN;
                S.dirX += (dir.x - S.dirX) * K_DIR;
                S.dirY += (dir.y - S.dirY) * K_DIR;
                S.dirZ += (dir.z - S.dirZ) * K_DIR;
                dir = normalize_or_front(S.dirX, S.dirY, S.dirZ);
            }

            // mono cue: a ping whose RATE encodes distance (near=fast, far=slow);
            // pitch encodes category (cue_freq). Or a continuous tone (test). The
            // envelope keeps pings click-free though the oscillator runs continuously.
            double ph  = S.phase;
            double inc = TWO_PI * (double)cue_freq(cueType) / (double)SR;
            if (ping) {
                // (the rate spans the cue's own range: walls 40..wallRange, objects
                // PING_NEAR..objRange -- within the old 500 the objects always pinged fast)
                const float pNear = wall ? 40.0f : PING_NEAR;
                const float pFar  = wall ? wallRange : objRange;
                float t = (pFar > pNear) ? (S.rateDist - pNear) / (pFar - pNear) : 0.0f;
                if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
                int cycleLen = PING_FAST + (int)(t * (float)(PING_SLOW - PING_FAST));
                if (cycleLen < 2) cycleLen = 2;
                // never repeat a loaded cue faster than it can fully play -> no clipping
                // even for long sounds; distance then sets the GAP, not the rate.
                if (cueBuf && cueBufLen + PING_MINGAP > cycleLen) cycleLen = cueBufLen + PING_MINGAP;
                // THE PING CLOCK runs on per source. It was (clock + slot offset) MODULO the
                // cycle, and walking changes the cycle every block: the remainder jumped,
                // a ping was cut off mid-way or began in its middle -- the crackle. Now a
                // ping always plays to its end (its length and cue latched at its start);
                // the distance only moves when the next one starts. A source starts in the
                // silent gap at its slot's stagger, so its first ping begins at the start.
                long long pos = S.cyclePos;
                if (pos < 0) { pos = ((long long)i * PING_STAGGER) % cycleLen; S.pingLen = 0; }
                for (int n = 0; n < FS; ++n) {
                    if (pos >= cycleLen && pos >= S.pingLen) {   // the next ping, from its start
                        pos = 0;
                        S.pingCue = cueType;
                        pBuf = cueBuf; pBufLen = cueBufLen;
                        if (pBuf && pBufLen > 0) {
                            S.pingLen = pBufLen;
                        } else {
                            int cl = cycleLen / 2; if (cl > CUE_MAX) cl = CUE_MAX;
                            S.pingLen = cl;
                        }
                    }
                    float s = 0.0f;
                    if (pos < S.pingLen) {
                        if (pBuf && pBufLen > 0) {
                            if (pos < pBufLen) s = pBuf[(size_t)pos];   // play the LOADED cue
                        } else {
                            // generated tone: sine + short envelope (fallback when no asset file)
                            const int cl = S.pingLen;
                            float penv;
                            if (pos < ATTACK) penv = (float)pos / (float)ATTACK;
                            else              penv = (cl > ATTACK) ? 1.0f - (float)(pos - ATTACK) / (float)(cl - ATTACK) : 0.0f;
                            if (penv < 0.0f) penv = 0.0f;
                            // harmonics (2f, 3f) so even low cues lateralize -- pure low
                            // sines carry almost no left/right information to the ear
                            s = (float)(std::sin(ph) + 0.4 * std::sin(2.0 * ph) + 0.2 * std::sin(3.0 * ph)) * 0.35f * penv;
                        }
                    }
                    if (!(pBuf && pBufLen > 0)) ph += inc;
                    g_inBuf.data[0][n] = s;
                    ++pos;
                }
                S.cyclePos = pos;
            } else {
                for (int n = 0; n < FS; ++n) {
                    g_inBuf.data[0][n] = (float)(std::sin(ph) + 0.4 * std::sin(2.0 * ph) + 0.2 * std::sin(3.0 * ph)) * 0.35f;
                    ph += inc;
                }
            }
            S.phase = std::fmod(ph, TWO_PI);

            // per-source fade env declicks activate/deactivate (~30ms ramp).
            float env = S.env;
            const float target = active ? 1.0f : 0.0f;
            const float step = 1.0f / (0.015f * (float)SR);   // ~15ms declick fade

            // HRTF binaural for ALL cues (walls + objects); reverb (below) adds the
            // room ambience, sent more strongly the farther the source is.
            IPLBinauralEffectParams p = {};
            p.direction     = dir;
            p.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
            p.spatialBlend  = 1.0f;
            p.hrtf          = g_hrtf;
            iplBinauralEffectApply(S.effect, &p, &g_inBuf, &g_outBuf);
            // rear darkening: sources BEHIND get low-passed (duller); front stays
            // bright. An exaggerated version of the natural cue, to fight HRTF
            // front/back reversal (ambiguous sources tend to read as "behind").
            float rear = dir.z > 0.0f ? dir.z : 0.0f;   // 0 = front .. 1 = fully behind
            const float dk = rear * 0.75f;
            // ramped over the block from the last block's values (no steps at its edge)
            const float d0 = S.dryPrev, d1 = S.dryS, s0 = S.sendPrev, s1 = S.sendS;
            const float k0 = (env > 0.0005f) ? S.dkPrev : dk, k1 = dk;
            float lpL = S.lpL, lpR = S.lpR;
            for (int n = 0; n < FS; ++n) {
                const float a = (float)(n + 1) / (float)FS;
                const float dryG = d0 + (d1 - d0) * a, sendG = s0 + (s1 - s0) * a, dkn = k0 + (k1 - k0) * a;
                if (env < target)      { env += step; if (env > target) env = target; }
                else if (env > target) { env -= step; if (env < target) env = target; }
                float l = g_outBuf.data[0][n] * env;
                float r = g_outBuf.data[1][n] * env;
                lpL += 0.12f * (l - lpL);
                lpR += 0.12f * (r - lpR);
                l = l * (1.0f - dkn) + lpL * dkn;
                r = r * (1.0f - dkn) + lpR * dkn;
                mixL[n]     += l * dryG;
                mixR[n]     += r * dryG;
                revSendL[n] += l * sendG;
                revSendR[n] += r * sendG;
            }
            S.env = env;
            S.lpL = lpL; S.lpR = lpR;
            S.dryPrev = d1; S.sendPrev = s1; S.dkPrev = k1;
        }
        // one-shot bump (2D, dry): a brief non-looping cue, or a generated thud fallback
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            if (g_osCue >= 0 && g_osCue < NUM_CUES) {
                const float* buf = g_cueBuf[g_osCue];
                int len = buf ? g_cueLen[g_osCue]
                              : (g_osCue == 7 ? SWEEP_LEN : (g_osCue == 8 ? CHIME_LEN
                                 : (g_osCue == 9 ? TALK_LEN : THUD_LEN)));
                for (int n = 0; n < FS && g_osPos < len; ++n, ++g_osPos) {
                    float s;
                    if (buf) s = buf[g_osPos] * 0.85f;
                    else if (g_osCue == 9) {
                        // talk fallback: a soft "pop" -- one short note gliding 700 -> 500 Hz
                        // with a touch of 2nd harmonic, quick decay. Lower than the two-note
                        // path-action chime, so the two never sound alike. Level: it had
                        // ~6.5 dB less energy than the chime (0.30, decay 30/s, 0.12 s) and
                        // risked going unheard; now ~2.7 dB below it (0.42, 24/s, 0.15 s).
                        const double t = (double)g_osPos / (double)SR;
                        const double T = (double)TALK_LEN / (double)SR;
                        const double phs = TWO_PI * (700.0 * t - 0.5 * (200.0 / T) * t * t);
                        float e = (float)std::exp(-t * 24.0);
                        if (g_osPos < (int)(0.003 * SR)) e *= (float)g_osPos / (float)(0.003 * SR);
                        s = (float)(std::sin(phs) + 0.25 * std::sin(2.0 * phs)) * 0.42f * e;
                    }
                    else if (g_osCue == 8) {
                        // path-action fallback: two-note chime G5 -> D6, each note with
                        // a fast attack and exponential decay (a "something to do here" ding)
                        const int half = CHIME_LEN * 2 / 5;
                        const bool second = g_osPos >= half;
                        const int  pos = second ? g_osPos - half : g_osPos;
                        const double f = second ? 1174.7 : 784.0;
                        const double t = (double)pos / (double)SR;
                        float e = (float)std::exp(-t * (second ? 14.0 : 22.0));
                        if (pos < (int)(0.004 * SR)) e *= (float)pos / (float)(0.004 * SR);   // de-click attack
                        s = (float)std::sin(TWO_PI * f * t) * 0.35f * e;
                    }
                    else if (g_osCue == 7) {
                        // door/transition fallback: rising chirp 280->720 Hz, half-sine envelope
                        double t = (double)g_osPos / (double)SR;
                        double T = (double)SWEEP_LEN / (double)SR;
                        double phs = TWO_PI * (280.0 * t + 0.5 * (440.0 / T) * t * t);
                        float  e = (float)std::sin(3.14159265 * (double)g_osPos / (double)SWEEP_LEN);
                        s = (float)std::sin(phs) * 0.5f * e;
                    }
                    else { float e = 1.0f - (float)g_osPos / (float)THUD_LEN;
                           s = (float)std::sin(TWO_PI * 140.0 * (double)g_osPos / (double)SR) * e * e * 0.6f; }
                    mixL[n] += s; mixR[n] += s;
                }
                if (g_osPos >= len) g_osCue = -1;
            }
        }
    }

    reverb_process(revSendL, revSendR);   // revSend buffers now hold the wet signal
    const float mtarget = front ? 1.0f : 0.0f;
    const float mstep = 1.0f / (MASTER_FADE * (float)SR);
    for (int n = 0; n < FS; ++n) {
        if (g_master < mtarget)      { g_master += mstep; if (g_master > mtarget) g_master = mtarget; }
        else if (g_master > mtarget) { g_master -= mstep; if (g_master < mtarget) g_master = mtarget; }
        float l = (mixL[n] + revSendL[n]) * g_master, r = (mixR[n] + revSendR[n]) * g_master;
        if (l > 1.0f) l = 1.0f; else if (l < -1.0f) l = -1.0f;
        if (r > 1.0f) r = 1.0f; else if (r < -1.0f) r = -1.0f;
        g_block[2 * n]     = l;
        g_block[2 * n + 1] = r;
    }
    g_clock += (unsigned long long)FS;
    g_blockPos = 0;
}

void data_callback(ma_device* /*dev*/, void* out, const void* /*in*/, ma_uint32 frameCount) {
    float* o = (float*)out;
    ma_uint32 done = 0;
    while (done < frameCount) {
        if (g_blockPos >= FS) render_block();
        ma_uint32 take = (ma_uint32)(FS - g_blockPos);
        if (take > frameCount - done) take = frameCount - done;
        std::memcpy(o + done * 2, g_block + g_blockPos * 2, (size_t)take * 2 * sizeof(float));
        g_blockPos += (int)take;
        done += take;
    }
}

} // namespace

extern "C" {

int SA_MaxSources(void) { return MAX_SOURCES; }
const char* SA_Status(void) { return g_status; }

int SA_Init(void) {
    if (g_running) return 1;

    IPLContextSettings cs = {};
    cs.version = STEAMAUDIO_VERSION;
    if (iplContextCreate(&cs, &g_ctx) != IPL_STATUS_SUCCESS) { set_status("iplContextCreate failed"); return 0; }

    IPLHRTFSettings hs = {};
    hs.type   = IPL_HRTFTYPE_DEFAULT;
    hs.volume = 1.0f;
    if (iplHRTFCreate(g_ctx, &g_audio, &hs, &g_hrtf) != IPL_STATUS_SUCCESS) {
        set_status("iplHRTFCreate failed"); SA_Shutdown(); return 0;
    }

    if (iplAudioBufferAllocate(g_ctx, 1, FS, &g_inBuf)  != IPL_STATUS_SUCCESS ||
        iplAudioBufferAllocate(g_ctx, 2, FS, &g_outBuf) != IPL_STATUS_SUCCESS) {
        set_status("iplAudioBufferAllocate failed"); SA_Shutdown(); return 0;
    }

    for (int i = 0; i < MAX_SOURCES; ++i) {
        IPLBinauralEffectSettings es = {};
        es.hrtf = g_hrtf;
        if (iplBinauralEffectCreate(g_ctx, &g_audio, &es, &g_src[i].effect) != IPL_STATUS_SUCCESS) {
            set_status("iplBinauralEffectCreate failed"); SA_Shutdown(); return 0;
        }
    }

    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format   = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate        = SR;
    cfg.dataCallback      = data_callback;
    if (ma_device_init(NULL, &cfg, &g_device) != MA_SUCCESS) {
        set_status("ma_device_init failed"); SA_Shutdown(); return 0;
    }
    g_deviceOk = true;

    g_running = true;
    if (ma_device_start(&g_device) != MA_SUCCESS) {
        g_running = false; set_status("ma_device_start failed"); SA_Shutdown(); return 0;
    }

    set_status("ok");
    return 1;
}

void SA_Shutdown(void) {
    g_running = false;
    if (g_deviceOk) { ma_device_uninit(&g_device); g_deviceOk = false; }
    for (int i = 0; i < MAX_SOURCES; ++i) {
        if (g_src[i].effect) { iplBinauralEffectRelease(&g_src[i].effect); g_src[i].effect = nullptr; }
        g_src[i].active = false;
        g_src[i].env = 0.0f;
        g_src[i].warm = false; g_src[i].cyclePos = -1; g_src[i].pingLen = 0; g_src[i].pingCue = -1;
        g_src[i].dryPrev = 0.0f; g_src[i].sendPrev = 0.0f;
    }
    for (int i = 0; i < NUM_CUES; ++i) { delete[] g_cueBuf[i]; g_cueBuf[i] = nullptr; g_cueLen[i] = 0; }
    g_osCue = -1; g_osPos = 0;
    if (g_inBuf.data)  { iplAudioBufferFree(g_ctx, &g_inBuf);  g_inBuf  = {}; }
    if (g_outBuf.data) { iplAudioBufferFree(g_ctx, &g_outBuf); g_outBuf = {}; }
    if (g_hrtf) { iplHRTFRelease(&g_hrtf); g_hrtf = nullptr; }
    if (g_ctx)  { iplContextRelease(&g_ctx); g_ctx = nullptr; }
    set_status("shut down");
}

void SA_SetListener(float x, float y, float z) {
    std::lock_guard<std::mutex> lk(g_mtx);
    g_lx = x; g_ly = y; g_lz = z;
}

void SA_SetRanges(float objRange, float wallRange) {
    std::lock_guard<std::mutex> lk(g_mtx);
    if (objRange >= 100.0f && objRange <= 20000.0f) g_objRange = objRange;
    if (wallRange >= 50.0f && wallRange <= 5000.0f) g_wallRange = wallRange;
}

void SA_SetSource(int id, int active, float x, float y, float z, int cueType) {
    if (id < 0 || id >= MAX_SOURCES) return;
    std::lock_guard<std::mutex> lk(g_mtx);
    g_src[id].active = (active != 0);
    g_src[id].listenerSpace = false;
    g_src[id].ping = true;                            // all cues ping; the rate encodes distance
    g_src[id].gain = (cueType == 5) ? 0.55f : 0.7f;   // walls a touch under objects (steeper rolloff below)
    g_src[id].cueType = cueType;
    g_src[id].x = x; g_src[id].y = y; g_src[id].z = z;
}

int SA_LoadCue(int cueType, const char* path) {
    if (cueType < 0 || cueType >= NUM_CUES || !path) return 0;
    // miniaudio decodes WAV / FLAC / MP3 (built-in) -> mono f32 at our sample rate.
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 1, SR);
    ma_decoder dec;
    if (ma_decoder_init_file(path, &cfg, &dec) != MA_SUCCESS) return 0;
    std::vector<float> samples;
    samples.reserve(SR);
    float tmp[4096];
    for (;;) {
        ma_uint64 got = 0;
        if (ma_decoder_read_pcm_frames(&dec, tmp, 4096, &got) != MA_SUCCESS) break;
        if (got == 0) break;
        samples.insert(samples.end(), tmp, tmp + (size_t)got);
        if (samples.size() > (size_t)SR * 10) break;   // cap a cue at 10 seconds
    }
    ma_decoder_uninit(&dec);
    if (samples.empty()) return 0;
    // peak-normalize so cue files of any export loudness play at a consistent level
    float peak = 0.0f;
    for (size_t k = 0; k < samples.size(); ++k) { float a = std::fabs(samples[k]); if (a > peak) peak = a; }
    if (peak > 1e-4f) { float sc = 0.9f / peak; for (size_t k = 0; k < samples.size(); ++k) samples[k] *= sc; }
    float* buf = new float[samples.size()];
    std::memcpy(buf, samples.data(), samples.size() * sizeof(float));
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        delete[] g_cueBuf[cueType];
        g_cueBuf[cueType] = buf;
        g_cueLen[cueType] = (int)samples.size();
    }
    return 1;
}

void SA_PlayCue(int cueType) {
    std::lock_guard<std::mutex> lk(g_mtx);
    g_osCue = cueType; g_osPos = 0;
}

void SA_TestTone(int dir) {
    std::lock_guard<std::mutex> lk(g_mtx);
    Source& s = g_src[0];
    if (dir == 4) { s.active = false; return; }
    s.active = true;
    s.listenerSpace = true;
    s.ping = false;   // continuous tone for HRTF debugging
    switch (dir) {
        case 0: s.x =  1; s.y = 0; s.z =  0; break;  // right
        case 1: s.x = -1; s.y = 0; s.z =  0; break;  // left
        case 2: s.x =  0; s.y = 0; s.z = -1; break;  // front
        case 3: s.x =  0; s.y = 0; s.z =  1; break;  // back
        default: s.x = 0; s.y = 0; s.z = -1; break;
    }
}

} // extern "C"
