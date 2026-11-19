// The Rust core's C interface: core/src/ffi.rs. Keep the two in step.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct SPExtras SPExtras;
typedef struct SPSfx SPSfx;

typedef struct {
    float dt;
    float cursor_x, cursor_y;
    uint8_t has_cursor, button, magic, padding;
    float daylight;
    float top_inset;
} SPInput;

typedef struct {
    /// 0 snow, 1 leaves, 2 petals, 3 rain, 4 hail.
    uint8_t weather, blizzard, fog, stars, garland, frost, creatures, padding;
    float intensity;
} SPSettings;

typedef struct { float x, y, width, height; } SPRect;

typedef struct {
    int64_t id;
    SPRect frame;
    uint32_t fronts_offset, fronts_count;
    uint8_t ledge_only;
} SPWindow;

/// The core's sprite: 17 floats, the same fields as the Mac's own in another stride.
typedef struct {
    float position[2], velocity[2];
    float size, alpha, soft, tint_amount;
    float tint[3];
    float lump;
    float leaf[3];
    float spin[2];
} SPSprite;

typedef struct { uint32_t kind; float value; } SPCue;

typedef struct {
    const float *values;
    uint32_t columns, rows;
    float cell, reach;
    uint8_t changed, mist;
} SPFrost;

SPExtras *sp_extras_new(float width, float height);
void sp_extras_free(SPExtras *extras);
void sp_extras_resize(SPExtras *extras, float width, float height);
void sp_extras_settings(SPExtras *extras, SPSettings settings);
void sp_extras_ground(SPExtras *extras, const float *heights, size_t count);
void sp_extras_windows(SPExtras *extras, const SPWindow *windows, size_t count, const SPRect *fronts, size_t front_count);
void sp_extras_covers(SPExtras *extras, const float *covers, size_t count);
void sp_extras_step(SPExtras *extras, SPInput input);
void sp_extras_flurry(SPExtras *extras);
void sp_extras_fireworks(SPExtras *extras, float seconds);
void sp_extras_clear(SPExtras *extras);
uint8_t sp_extras_active(const SPExtras *extras);
uint8_t sp_extras_smooth(const SPExtras *extras);
size_t sp_extras_sprite_count(const SPExtras *extras);
size_t sp_extras_write(const SPExtras *extras, SPSprite *out, size_t capacity);
SPFrost sp_extras_frost(SPExtras *extras);
size_t sp_extras_take_cues(SPExtras *extras, SPCue *out, size_t capacity);

SPSfx *sp_sfx_new(float sample_rate);
void sp_sfx_free(SPSfx *sfx);
void sp_sfx_set(const SPSfx *sfx, float sample_rate, float volume, float rain, float hail);
void sp_sfx_play(const SPSfx *sfx, uint32_t kind, float value);
uint8_t sp_sfx_audible(const SPSfx *sfx);
void sp_sfx_mix(const SPSfx *sfx, float *left, float *right, size_t frames);
