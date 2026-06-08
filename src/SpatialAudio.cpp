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

extern "C" {
#include "phonon.h"
}

#include <mutex>
#include <cmath>
#include <cstring>
#include <cstdio>

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
constexpr float  PING_NEAR = 100.0f;             // distance (units) at/below which rate is fastest
constexpr float  PING_FAR  = 2500.0f;            // distance at/above which rate is slowest
constexpr int    PING_STAGGER = 4000;            // per-slot phase offset so pings don't all align

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
    IPLBinauralEffect effect = nullptr;
};

Source     g_src[MAX_SOURCES];
float      g_lx = 0, g_ly = 0, g_lz = 0;   // listener world position
std::mutex g_mtx;

float g_block[FS * 2];              // one rendered stereo block, interleaved L,R,...
int   g_blockPos = FS;             // frames consumed; start "empty" so first callback renders
unsigned long long g_clock = 0;    // global sample clock for ping staggering (audio thread)

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
    // X = -ddy: world +Y is the RIGHT-arrow direction, so a +Y object must pan to the
    // RIGHT ear to match the key the player presses / the spoken direction. (Confirmed
    // by ear: the un-negated form put walls on the opposite side from the speech.)
    // up = +Z; front (-Z) = +X (screen up).
    constexpr float WIDEN = 1.6f;   // exaggerate azimuth so close-together sources separate in stereo
    return normalize_or_front(-ddy * WIDEN, ddz, -ddx);
}

float dist_attenuation(float dist) {
    constexpr float FALLOFF = 550.0f;   // volume reaches ~0 here (keep ~= the radar range)
    float a = 1.0f - dist / FALLOFF;
    if (a < 0.0f) a = 0.0f;
    return a * a;                        // steep quadratic rolloff: loud near, ~silent at FALLOFF
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
    std::memset(mixL, 0, sizeof(mixL));
    std::memset(mixR, 0, sizeof(mixR));
    std::memset(revSendL, 0, sizeof(revSendL));
    std::memset(revSendR, 0, sizeof(revSendR));

    if (g_running && g_ctx && g_hrtf) {
        for (int i = 0; i < MAX_SOURCES; ++i) {
            bool active, lspace, ping; int cueType; float sx, sy, sz, gain, lx, ly, lz;
            {
                std::lock_guard<std::mutex> lk(g_mtx);
                active  = g_src[i].active;
                lspace  = g_src[i].listenerSpace;
                ping    = g_src[i].ping;
                cueType = g_src[i].cueType;
                sx = g_src[i].x; sy = g_src[i].y; sz = g_src[i].z;
                gain = g_src[i].gain;
                lx = g_lx; ly = g_ly; lz = g_lz;
            }
            if (!g_src[i].effect) continue;
            if (!active && g_src[i].env <= 0.0005f) continue;   // fully faded out -> silent

            // direction + distance FIRST: distance drives both attenuation and the
            // ping rate (closer = faster pings).
            float ddx = 0.0f, ddy = 0.0f, ddz = 0.0f, dist = 0.0f, atten = 1.0f;
            IPLVector3 dir;
            if (lspace) {
                dir = normalize_or_front(sx, sy, sz);
            } else {
                ddx = sx - lx; ddy = sy - ly; ddz = sz - lz;
                dist = std::sqrt(ddx * ddx + ddy * ddy + ddz * ddz);
                dir = world_delta_to_sa(ddx, ddy, ddz);
                atten = dist_attenuation(dist);
                if (cueType == 5) {
                    // walls: steeper rolloff so they get clearly louder up close
                    float wa = 120.0f / (dist > 1.0f ? dist : 1.0f);
                    if (wa > 1.6f) wa = 1.6f; else if (wa < 0.25f) wa = 0.25f;
                    atten = wa;
                }
            }

            // mono cue: a ping whose RATE encodes distance (near=fast, far=slow);
            // pitch encodes category (cue_freq). Or a continuous tone (test). The
            // envelope keeps pings click-free though the oscillator runs continuously.
            double ph  = g_src[i].phase;
            double inc = TWO_PI * (double)cue_freq(cueType) / (double)SR;
            if (ping) {
                float t = (dist - PING_NEAR) / (PING_FAR - PING_NEAR);
                if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
                int cycleLen = PING_FAST + (int)(t * (float)(PING_SLOW - PING_FAST));
                if (cycleLen < 2) cycleLen = 2;
                int cueLen = cycleLen / 2; if (cueLen > CUE_MAX) cueLen = CUE_MAX;
                long long base = (long long)g_clock + (long long)i * PING_STAGGER;
                for (int n = 0; n < FS; ++n) {
                    long long cyc = (base + n) % cycleLen;
                    float penv = 0.0f;
                    if (cyc < cueLen) {
                        if (cyc < ATTACK) penv = (float)cyc / (float)ATTACK;
                        else              penv = 1.0f - (float)(cyc - ATTACK) / (float)(cueLen - ATTACK);
                        if (penv < 0.0f) penv = 0.0f;
                    }
                    g_inBuf.data[0][n] = (float)std::sin(ph) * 0.5f * penv;
                    ph += inc;
                }
            } else {
                for (int n = 0; n < FS; ++n) { g_inBuf.data[0][n] = (float)std::sin(ph) * 0.5f; ph += inc; }
            }
            g_src[i].phase = std::fmod(ph, TWO_PI);

            // per-source fade env declicks activate/deactivate (~30ms ramp).
            float env = g_src[i].env;
            const float target = active ? 1.0f : 0.0f;
            const float step = 1.0f / (0.015f * (float)SR);   // ~15ms declick fade
            const float dryG  = gain * atten;               // direct sound: drops with distance
            const float sendG = gain * send_factor(dist);   // reverb send: rises with distance

            // HRTF binaural for ALL cues (walls + objects); reverb (below) adds the
            // room ambience, sent more strongly the farther the source is.
            IPLBinauralEffectParams p = {};
            p.direction     = dir;
            p.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
            p.spatialBlend  = 1.0f;
            p.hrtf          = g_hrtf;
            iplBinauralEffectApply(g_src[i].effect, &p, &g_inBuf, &g_outBuf);
            for (int n = 0; n < FS; ++n) {
                if (env < target)      { env += step; if (env > target) env = target; }
                else if (env > target) { env -= step; if (env < target) env = target; }
                float l = g_outBuf.data[0][n] * env;
                float r = g_outBuf.data[1][n] * env;
                mixL[n]     += l * dryG;
                mixR[n]     += r * dryG;
                revSendL[n] += l * sendG;
                revSendR[n] += r * sendG;
            }
            g_src[i].env = env;
        }
    }

    reverb_process(revSendL, revSendR);   // revSend buffers now hold the wet signal
    for (int n = 0; n < FS; ++n) {
        float l = mixL[n] + revSendL[n], r = mixR[n] + revSendR[n];
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
    }
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
