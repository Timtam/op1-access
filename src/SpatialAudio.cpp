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

constexpr int    CYCLE_LEN = (int)(1.4 * SR);    // ping period per source
constexpr int    CUE_LEN   = (int)(0.18 * SR);   // ping (cue) duration
constexpr int    ATTACK    = (int)(0.012 * SR);  // ping attack ramp

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
    return normalize_or_front(ddy, ddz, -ddx);   // right=+Y, up=+Z, front(-Z)=+X(screen up)
}

float dist_attenuation(float dist) {
    constexpr float ref = 250.0f;
    if (dist <= ref) return 1.0f;
    float g = ref / dist;
    return g < 0.04f ? 0.04f : g;
}

void render_block() {
    static float mixL[FS];
    static float mixR[FS];
    std::memset(mixL, 0, sizeof(mixL));
    std::memset(mixR, 0, sizeof(mixR));

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
            if (!active || !g_src[i].effect) continue;

            // mono cue: a periodic ping (per-category freq, staggered by slot) or a
            // continuous tone (test). The envelope keeps pings click-free even
            // though the oscillator phase runs continuously.
            double ph  = g_src[i].phase;
            double inc = TWO_PI * (double)cue_freq(cueType) / (double)SR;
            if (ping) {
                long long base = (long long)g_clock + (long long)i * (CYCLE_LEN / MAX_SOURCES);
                for (int n = 0; n < FS; ++n) {
                    long long cyc = (base + n) % CYCLE_LEN;
                    float env = 0.0f;
                    if (cyc < CUE_LEN) {
                        if (cyc < ATTACK) env = (float)cyc / (float)ATTACK;
                        else              env = 1.0f - (float)(cyc - ATTACK) / (float)(CUE_LEN - ATTACK);
                        if (env < 0.0f) env = 0.0f;
                    }
                    g_inBuf.data[0][n] = (float)std::sin(ph) * 0.5f * env;
                    ph += inc;
                }
            } else {
                for (int n = 0; n < FS; ++n) { g_inBuf.data[0][n] = (float)std::sin(ph) * 0.5f; ph += inc; }
            }
            g_src[i].phase = std::fmod(ph, TWO_PI);

            IPLVector3 dir; float atten = 1.0f;
            if (lspace) {
                dir = normalize_or_front(sx, sy, sz);
            } else {
                float ddx = sx - lx, ddy = sy - ly, ddz = sz - lz;
                float dist = std::sqrt(ddx * ddx + ddy * ddy + ddz * ddz);
                dir = world_delta_to_sa(ddx, ddy, ddz);
                atten = dist_attenuation(dist);
            }

            IPLBinauralEffectParams p = {};
            p.direction     = dir;
            p.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
            p.spatialBlend  = 1.0f;
            p.hrtf          = g_hrtf;
            iplBinauralEffectApply(g_src[i].effect, &p, &g_inBuf, &g_outBuf);

            float g = gain * atten;
            for (int n = 0; n < FS; ++n) {
                mixL[n] += g_outBuf.data[0][n] * g;
                mixR[n] += g_outBuf.data[1][n] * g;
            }
        }
    }

    for (int n = 0; n < FS; ++n) {
        float l = mixL[n], r = mixR[n];
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
    g_src[id].ping = true;
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
