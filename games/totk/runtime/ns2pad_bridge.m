/* A Nintendo Switch 2 Pro Controller over Bluetooth LE, on macOS and iOS (third_party/ns2pad).

   GameController does not adopt this controller, so ns2pad reads it in our own process with CoreBluetooth: it scans,
   connects, turns the sensors on and calls back on its own serial queue with each input report (about 30 a second on a
   Mac, the Bluetooth connection interval's limit). Only one program can hold the controller at a time; to pair it, hold
   the small button on its top edge until the four lights sweep.

   - Buttons and sticks: runtime_gamepad_ns2pad (gamepad.m) as the same physical bits gamepad_buttons() produces, face
     buttons by position (B bottom, A right, Y left, X top), so controls.txt and the key bindings apply unchanged.
     HOME is physical button 16 ("touchpad"), which the settings panel can pick as its button; capture, C and the back
     buttons GL / GR drive nothing.
   - Motion: runtime_motion_feed in GCMotion's frame (x right, y top edge, z out of the face; acceleration in G with
     gravity, face up z = -1 G; rotation in rad/s), which is ns2pad's own, at each sample's time on the controller's clock
     brought to ours (sample_time_ns, the same clock as runtime_now_ns), so reports that arrive bunched together still
     integrate at their real spacing. While it is connected, gamepad_feedback.m takes no motion from other controllers.
   - Rumble: gamepad_feedback.m sends the game's two bands as two motor strengths (ns2pad_set_rumble).
   - Battery: the HUD's controller battery (an estimate from the voltage).

   TOTK_NS2PAD=0 leaves Bluetooth alone (no scan, no permission prompt). */
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"
#include "gamepad_layout.h"
#include "ns2pad.h"

static _Atomic int activePad = -1;   /* the controller in use; others connected meanwhile are ignored */
static uint64_t sentButtons;          /* ns2pad's queue */
static float sentSticks[4];
static int sentBattery = -2;

int runtime_ns2pad_connected(void) { return atomic_load(&activePad) >= 0; }
static void ns2_changed(void) {   /* the iPhone's touch controls, gyro and haptics step aside for a controller */
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:RUNTIME_NS2PAD_CHANGED object:nil]; });
}

static void ns2_rumble(float low, float high) {   /* the rumble queue (gamepad_feedback.m) */
    int pad = atomic_load(&activePad);
    if (pad >= 0) ns2pad_set_rumble(pad, low, high);
}

static uint64_t ns2_physical(uint32_t b) {
    uint64_t bits = gamepad_face_positions(!!(b & NS2PAD_BTN_B), !!(b & NS2PAD_BTN_A), !!(b & NS2PAD_BTN_Y), !!(b & NS2PAD_BTN_X), 1);
    if (b & NS2PAD_BTN_LSTICK) bits |= 1ULL << 4;
    if (b & NS2PAD_BTN_RSTICK) bits |= 1ULL << 5;
    if (b & NS2PAD_BTN_L) bits |= 1ULL << 6;
    if (b & NS2PAD_BTN_R) bits |= 1ULL << 7;
    if (b & NS2PAD_BTN_ZL) bits |= 1ULL << 8;
    if (b & NS2PAD_BTN_ZR) bits |= 1ULL << 9;
    if (b & NS2PAD_BTN_PLUS) bits |= 1ULL << 10;
    if (b & NS2PAD_BTN_MINUS) bits |= 1ULL << 11;
    if (b & NS2PAD_BTN_LEFT) bits |= 1ULL << 12;
    if (b & NS2PAD_BTN_UP) bits |= 1ULL << 13;
    if (b & NS2PAD_BTN_RIGHT) bits |= 1ULL << 14;
    if (b & NS2PAD_BTN_DOWN) bits |= 1ULL << 15;
    if (b & NS2PAD_BTN_HOME) bits |= 1ULL << 16;
    return bits;
}

static void ns2_state(void *user, int pad, const ns2pad_state *s) {   /* ns2pad's queue, every input report */
    (void)user;
    if (pad != atomic_load(&activePad)) return;
    if (s->imu_valid) {
        const double acc[3] = {s->accel_g[0], s->accel_g[1], s->accel_g[2]};
        const double gyro[3] = {s->gyro_rad_s[0], s->gyro_rad_s[1], s->gyro_rad_s[2]};
        if (runtime_gyro_enabled()) runtime_motion_feed(acc, gyro, s->sample_time_ns);
    }
    uint64_t buttons = ns2_physical(s->buttons);
    const float sticks[4] = {s->left_x, s->left_y, s->right_x, s->right_y};
    if (buttons != sentButtons || memcmp(sticks, sentSticks, sizeof sticks)) {
        sentButtons = buttons; memcpy(sentSticks, sticks, sizeof sticks);
        runtime_gamepad_ns2pad(1, buttons, sticks[0], sticks[1], sticks[2], sticks[3]);
    }
    if (s->battery_percent != sentBattery) {
        sentBattery = s->battery_percent;
        runtime_gamepad_hid_battery(0, s->battery_percent);
    }
}

static void ns2_connected(void *user, int pad, const ns2pad_info *info) {   /* ns2pad's queue */
    (void)user;
    int none = -1;
    if (!atomic_compare_exchange_strong(&activePad, &none, pad)) {
        fprintf(stderr, "[ns2pad] %s connected as a second controller: not used\n", info->name);
        return;
    }
    sentButtons = 0; memset(sentSticks, 0, sizeof sentSticks); sentBattery = -2;
    runtime_gamepad_ns2pad(1, 0, 0, 0, 0, 0);
    runtime_feedback_ns2pad(1, ns2_rumble);
    ns2_changed();
    fprintf(stderr, "[totk-input] %s connected over Bluetooth LE (ns2pad), face buttons by position\n", info->name);
    if (runtime_gyro_enabled()) fprintf(stderr, "[gyro] %s: motion sensors on (gyro, gravity)%s\n", info->name, info->imu_enabled ? "" : " -- the controller did not confirm turning them on");
}

static void ns2_disconnected(void *user, int pad) {   /* ns2pad's queue */
    (void)user;
    int was = pad;
    if (!atomic_compare_exchange_strong(&activePad, &was, -1)) return;
    runtime_feedback_ns2pad(0, NULL);
    runtime_gamepad_ns2pad(0, 0, 0, 0, 0, 0);
    runtime_gamepad_hid_battery(0, -1);
    ns2_changed();
    fprintf(stderr, "[totk-input] Switch 2 controller disconnected (ns2pad)\n");
}

static void ns2_log(void *user, int level, const char *msg) {
    (void)user;
    fprintf(stderr, "[ns2pad]%s %s\n", level == NS2PAD_LOG_ERROR ? " error:" : level == NS2PAD_LOG_WARN ? " warning:" : "", msg);
}

void runtime_ns2pad_scan(int on) { ns2pad_set_scanning(on); }   /* any thread; nothing before ns2pad_start */

void runtime_ns2pad_start(void) {   /* main thread, once */
    static int started;
    if (started) return;
    started = 1;
    const char *env = getenv("TOTK_NS2PAD");
    if (env && (!strcmp(env, "0") || !strcmp(env, "off"))) { fprintf(stderr, "[ns2pad] off (TOTK_NS2PAD=%s)\n", env); return; }
    ns2pad_callbacks cb = {ns2_connected, ns2_disconnected, ns2_state, ns2_log};
    ns2pad_config cfg;
    ns2pad_config_default(&cfg);
    int r = ns2pad_start(&cb, NULL, &cfg);
    if (r) fprintf(stderr, "[ns2pad] did not start (%d)\n", r);
    else fprintf(stderr, "[ns2pad] %s: looking for a Switch 2 Pro Controller over Bluetooth LE\n", ns2pad_version());
}
