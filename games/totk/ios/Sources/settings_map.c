#include "settings_map.h"
#include <string.h>

/* The picture mode owns the drawable, the output upscale and the operation: the game renders into a canvas, and the
   mode either matches the drawable to it (720 or 1080 rows) or hands the canvas to MetalFX and lets it fill the panel's
   own pixels. The 1080 mode uses the game's docked settings, as the pane's Full HD preset does. The output upscale only
   runs while the scene upscale's master switch is on, so the MetalFX entry turns that switch on itself: a pane switch
   left off would otherwise make the entry do nothing. */
static const struct { const char *mode; totk_picture_env env; } PICTURE[] = {
    {"720",  {"720",  "0", "handheld", NULL}},
    {"1080", {"1080", "0", "docked",   NULL}},
    {"mfx",  {"0",    "1", "handheld", "1"}},
};

int totk_picture_env_build(const char *mode, totk_picture_env *out) {
    if (!mode) return 0;
    for (unsigned i = 0; i < sizeof PICTURE / sizeof PICTURE[0]; i++) {
        if (strcmp(PICTURE[i].mode, mode)) continue;
        *out = PICTURE[i].env;
        return 1;
    }
    return 0;
}

/* A cap is the most the phone draws. 60 leaves the pacing to the uncapped path (ceiling 60, frontend_ios.m and hle_nvn.c
   uncapped_cap), exactly as the preset row's 60: the game's own 30 fps step is ignored there, so a busy moment costs
   a few frames instead of halving the rate. (Until 2026-11-01 the custom 60 fixed the display link at 60 through
   DM_PRESENT_HZ, which turned the uncapped path off: the game dropped to its 30 step and stayed there.) 30 and 40 are
   the phone's own hold (TOTK_PHONE_FPS), which keeps the game's frame interval in display units; pacing the clock at
   30 Hz instead raised the game's interval to 3 display units and the title ran at about 10 fps (hle_nvn.c
   phone_hold_fps). 40 needs the 120 Hz link (every third refresh); at 60 Hz it is paced by our own clock. */
int totk_frame_env_build(const char *cap, totk_frame_env *out) {
    if (!cap) return 0;
    totk_frame_env e;
    if (!strcmp(cap, "30")) e = (totk_frame_env){NULL, "30"};
    else if (!strcmp(cap, "40")) e = (totk_frame_env){NULL, "40"};
    else if (!strcmp(cap, "60")) e = (totk_frame_env){NULL, NULL};
    else return 0;
    *out = e;
    return 1;
}

/* The Full HD preset is the game's docked settings as the Vision Pro build uses them: 1920x1080 output on a 1080-row
   drawable with the scene at 1600x900. Off is the handheld default of the runtime (no drawable or scene override).
   Breath of the Wild sizes its docked scene through its own patch (game_patches_botw.c patch_render_phone, from the
   pane's TOTK_BOTW_SCENE row), so TOTK_RENDER_RES is left alone there. */
/* Tears of the Kingdom's docked scene (the pane's TOTK_DOCKED_SCENE row, the start screen's 1080p original / HD, as
   Breath of the Wild's TOTK_BOTW_SCENE): the Switch's 1600x900, or 1920x1080, the canvas's own size; anything else is
   the Switch's. main.m hands it over as TOTK_RENDER_RES when the preset is docked. */
const char *totk_docked_scene(const char *choice) {
    return choice && !strcmp(choice, "1920x1080") ? "1920x1080" : "1600x900";
}
int totk_preset_env_build(int docked, totk_preset_env *out) {
    *out = docked ? (totk_preset_env){"docked", "1080", "1600x900", "0"}
                  : (totk_preset_env){"handheld", NULL, NULL, "0"};
#ifdef GAME_BOTW
    out->scene = NULL;
#endif
    return 1;
}

/* The preset row: "60" the uncapped path (ceiling 60), "40" / "30" held. Since 2026-11-01 the same as the custom cap. */
int totk_preset_frame_env_build(const char *fps, totk_frame_env *out) {
    return totk_frame_env_build(fps, out);
}

/* The keys the pane's layers own. Every other pane row is handed over whichever layer is active. Only keys that have a
   row can appear here: main.m's loop walks the pane's own specs, so a key without one is never handed over at all. */
static const struct { const char *key; totk_key_layer layer; } LAYERS[] = {
    {"TOTK_DOCKED",           TOTK_KEY_PRESET},
    {"TOTK_BOTW_SCENE",       TOTK_KEY_PRESET},
    {"TOTK_DOCKED_SCENE",     TOTK_KEY_PRESET},
    {"TOTK_PHONE_FPS",        TOTK_KEY_PRESET},
    {"TOTK_IOS_PICTURE_MODE", TOTK_KEY_CUSTOM},
    {"TOTK_RENDER_RES",       TOTK_KEY_CUSTOM},
    {"TOTK_FPS_CAP",          TOTK_KEY_CUSTOM},
};
totk_key_layer totk_key_layer_of(const char *key) {
    if (key) for (unsigned i = 0; i < sizeof LAYERS / sizeof LAYERS[0]; i++) if (!strcmp(LAYERS[i].key, key)) return LAYERS[i].layer;
    return TOTK_KEY_ALWAYS;
}

const char *totk_frame_button_key(int custom) { return custom ? NULL : "TOTK_PHONE_FPS"; }
int totk_frame_button_target(int now) { return now == 60 ? 40 : 60; }   /* 60 <-> 40 (user 2026-11-06); 30, set in Settings, goes to 60 */

/* 720p with the 960x540 scene is the combination that keeps 60 fps the longest on an iPad before the SoC throttles,
   and it is the coolest (measured 2026-10-23: GPU 12.9 ms at 960x540 against 26.2 ms at 1280x720 on the same draw
   count). Must match Root.plist's DefaultValue; tests/test_ios_settings.py checks that. */
const char *totk_picture_mode_default(void) { return "720"; }
const char *totk_frame_cap_default(void) { return "60"; }
