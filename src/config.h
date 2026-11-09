#pragma once

// Everything here is shared with the shader: main.cpp injects these values
// as #defines in front of intro.glsl (see shaderHeader in main.cpp).

#define XRES 1920
#define YRES 1080
#define DEBUG_XRES 1280         // Debug: the resolution it renders at instead (the window size too, it can be resized)...
#define DEBUG_YRES 720          // ...faster while tweaking. Keep 16:9 and multiples of 8

#define DURATION 114            // seconds, the intro and the soundtrack end there (the last camera plan runs until then)
#define SHOT_COUNT 10           // camera plans 0..9 (Debug camera tools, keys 0-9; plan 0 is the prologue before the scene clock, intro.glsl Prologue)...
#define SHOT_DURATION 10        // ...of this many seconds each...
#define PROLOGUE 20             // ...but plan 0, the prologue (credits, title): this many seconds before the scene clock starts
#define FORCE_DISCRETE_GPU 1    // Debug: export the NVIDIA Optimus / AMD PowerXpress flags (Release: not exported, 76 bytes)
#define DEBUG_FRAME_RATE 0     // Debug: frames per second cap, keeps a laptop cool (L toggles it; 0 = uncapped)
#define FULLSCREEN 1            // Release: a borderless window over the whole screen, the XRES x YRES picture scaled to fit it (black bars); 0 = an XRES x YRES window at the top left
#define RENDER_SCALE 1          // supersampling: the scene is rendered at RENDER_SCALE x the resolution (1, 2)

// Volumes (all cubic, each size must be a multiple of 8 = compute group size)
#define NOISE_SIZE 64          // tileable FBM noise, generated once
#define TEXTURE_SIZE 320        // procedural density: R = clouds, G = solids
#define BRICK_SIZE 8            // texels per brick (the AABB of the RTX versions)
#define BRICK_COUNT (TEXTURE_SIZE / BRICK_SIZE)
#define LIGHT_SIZE 64           // optical depth toward the light, covers the whole box

// Sound: the audio pass renders the whole soundtrack once, before the intro starts, into an
// AUDIO_WIDTH x AUDIO_ROWS RG32F texture (stereo). main.cpp reads it back as 16-bit PCM and
// plays it with waveOut; the play position is the intro clock.
#define SAMPLE_RATE 48000 //44100
#define AUDIO_WIDTH 4096        // samples per texture row
#define AUDIO_BLOCK 256         // samples per invocation of the audio pass
#define AUDIO_WARMUP 4096       // samples each invocation runs before its block, so the filters settle (blocks match a longer run within -90 dB)
#define AUDIO_ROWS ((DURATION * SAMPLE_RATE / AUDIO_WIDTH + 8) / 8 * 8)   // a multiple of 8, covers DURATION
#define AUDIO_SAMPLES (AUDIO_WIDTH * AUDIO_ROWS)

// Ray marching quality
#define STEP_SCALE 1.0          // samples per density texel along a ray
#define GODRAY_SAMPLES 32

static_assert((XRES * RENDER_SCALE) % 8 == 0 && (YRES * RENDER_SCALE) % 8 == 0, "render size must be a multiple of 8");
static_assert(AUDIO_WIDTH % (AUDIO_BLOCK * 8) == 0, "an audio row must hold a multiple of 8 blocks");
static_assert(NOISE_SIZE % 8 == 0 && TEXTURE_SIZE % 8 == 0 && BRICK_COUNT % 8 == 0 && LIGHT_SIZE % 8 == 0, "volume sizes must be multiples of 8");
static_assert(SHOT_COUNT >= 2 && SHOT_COUNT <= 10, "camera plans are selected with keys 0-9, plan 0 is the prologue");
static_assert(PROLOGUE + (SHOT_COUNT - 2) * SHOT_DURATION < DURATION, "the last camera plan must start before the end");
