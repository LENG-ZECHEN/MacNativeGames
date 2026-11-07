/*
 * ns2_core.c — Switch 2 手柄协议核心（纯 C99，无平台依赖）。说明见 ns2_core.h 和 docs/protocol.md。
 */
#include "ns2_core.h"

#include <math.h>
#include <string.h>

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static float rdf32(const uint8_t *p) {
    uint32_t u = rd32(p);
    float f;
    memcpy(&f, &u, sizeof f);
    return f;
}

/* ------------------------------------------------------------------------- */
/* 广播                                                                       */
/* ------------------------------------------------------------------------- */

uint16_t ns2_adv_product_id(const uint8_t *mfg, size_t len) {
    /* 53 05 | 01 00 03 | 7e 05 | 69 20 ... （bluetooth_interface.md "Manufacturer Data Format"） */
    if (!mfg || len < 9) return 0;
    if (rd16(mfg) != NS2_ADV_COMPANY_ID) return 0;
    if (rd16(mfg + 5) != NS2_VENDOR_ID) return 0;
    uint16_t pid = rd16(mfg + 7);
    if (pid < 0x2060 || pid > 0x207F) return 0;
    return pid;
}

const char *ns2_product_name(uint16_t pid) {
    switch (pid) {
    case NS2PAD_PID_JOYCON2_L: return "Joy-Con 2 (L)";
    case NS2PAD_PID_JOYCON2_R: return "Joy-Con 2 (R)";
    case NS2PAD_PID_PRO2: return "Pro Controller 2";
    case NS2PAD_PID_GC_NSO: return "NSO GameCube Controller";
    default: return "Switch 2 controller";
    }
}

/* ------------------------------------------------------------------------- */
/* 命令                                                                       */
/* ------------------------------------------------------------------------- */

size_t ns2_build_command(uint8_t *out, size_t cap, uint8_t cmd, uint8_t sub,
                         const uint8_t *data, uint8_t data_len) {
    size_t total = 8u + data_len;
    if (!out || cap < total) return 0;
    out[0] = cmd;
    out[1] = NS2_DIR_REQUEST;
    out[2] = NS2_TRANSPORT_BLE;
    out[3] = sub;
    out[4] = 0x00;
    out[5] = data_len;
    out[6] = 0x00;
    out[7] = 0x00;
    if (data_len) memcpy(out + 8, data, data_len);
    return total;
}

size_t ns2_build_flash_read(uint8_t *out, size_t cap, uint32_t address, uint8_t len) {
    /* 0x02/0x04 数据：长度、0x7E、00 00、地址（小端） */
    uint8_t d[8] = {len, 0x7E, 0x00, 0x00,
                    (uint8_t)address, (uint8_t)(address >> 8), (uint8_t)(address >> 16), (uint8_t)(address >> 24)};
    return ns2_build_command(out, cap, NS2_CMD_FLASH, 0x04, d, sizeof d);
}

size_t ns2_build_feature(uint8_t *out, size_t cap, uint8_t sub, uint8_t flags) {
    uint8_t d[4] = {flags, 0, 0, 0};
    return ns2_build_command(out, cap, NS2_CMD_FEATURE, sub, d, sizeof d);
}

size_t ns2_build_player_leds(uint8_t *out, size_t cap, uint8_t mask) {
    uint8_t d[8] = {(uint8_t)(mask & 0x0F), 0, 0, 0, 0, 0, 0, 0};
    return ns2_build_command(out, cap, NS2_CMD_LED, 0x07, d, sizeof d);
}

size_t ns2_build_vibration_sample(uint8_t *out, size_t cap, uint8_t sample) {
    uint8_t d[4] = {sample, 0, 0, 0};
    return ns2_build_command(out, cap, NS2_CMD_VIBRATION, 0x02, d, sizeof d);
}

size_t ns2_wrap_combined(uint8_t *out, size_t cap, const uint8_t *cmd, size_t cmd_len) {
    size_t total = NS2_COMBINED_PREFIX_PRO + cmd_len;
    if (!out || cap < total) return 0;
    memmove(out + NS2_COMBINED_PREFIX_PRO, cmd, cmd_len);
    memset(out, 0, NS2_COMBINED_PREFIX_PRO);
    return total;
}

bool ns2_parse_response(const uint8_t *p, size_t n, size_t prefix, ns2_response *out) {
    if (!p || !out || n < prefix + 8) return false;
    const uint8_t *h = p + prefix;
    if (h[1] != NS2_DIR_RESPONSE) return false;
    out->cmd = h[0];
    out->sub = h[3];
    out->status = h[4];
    out->ack = h[5];
    out->data = h + 8;
    out->data_len = n - prefix - 8;
    return true;
}

bool ns2_response_ok(const ns2_response *r) { return r && (r->ack & 0x7F) == 0x78; }

bool ns2_parse_flash_read(const ns2_response *r, uint32_t *address, const uint8_t **bytes, size_t *len) {
    /* 响应数据：长度(1) 填充(3) 地址(4) 内容 */
    if (!r || r->cmd != NS2_CMD_FLASH || (r->sub != 0x04 && r->sub != 0x01) || r->data_len < 8) return false;
    size_t n = r->data[0];
    if (n == 0 || r->data_len < 8 + n) return false;
    if (address) *address = rd32(r->data + 4);
    if (bytes) *bytes = r->data + 8;
    if (len) *len = n;
    return true;
}

/* ------------------------------------------------------------------------- */
/* 输入报告                                                                   */
/* ------------------------------------------------------------------------- */

void ns2_unpack12(const uint8_t p[3], uint16_t *x, uint16_t *y) {
    if (x) *x = (uint16_t)(p[0] | ((p[1] & 0x0F) << 8));
    if (y) *y = (uint16_t)((p[1] >> 4) | (p[2] << 4));
}

bool ns2_parse_input05(const uint8_t *p, size_t n, ns2_input05 *o) {
    if (!p || !o || n < 0x3C) return false;
    memset(o, 0, sizeof *o);
    o->counter = rd32(p + 0x00);
    o->buttons = rd32(p + 0x04);
    ns2_unpack12(p + 0x0A, &o->left[0], &o->left[1]);
    ns2_unpack12(p + 0x0D, &o->right[0], &o->right[1]);
    for (int i = 0; i < 3; i++) o->magnetometer[i] = (int16_t)rd16(p + 0x19 + 2 * i);
    o->battery_mv = rd16(p + 0x1F);
    o->charge_state = p[0x21];
    o->imu_timestamp = rd32(p + 0x2A);
    o->temperature = (int16_t)rd16(p + 0x2E);
    for (int i = 0; i < 3; i++) {
        o->accel[i] = (int16_t)rd16(p + 0x30 + 2 * i);
        o->gyro[i] = (int16_t)rd16(p + 0x36 + 2 * i);
    }
    return true;
}

/* ------------------------------------------------------------------------- */
/* 校准                                                                       */
/* ------------------------------------------------------------------------- */

static bool axis_ok(const ns2_axis_cal *a) {
    return a->center >= 1000 && a->center <= 3000 &&
           a->positive >= 500 && a->positive <= 2047 &&
           a->negative >= 500 && a->negative <= 2047;
}

bool ns2_parse_stick_cal(const uint8_t p[9], ns2_stick_cal *out) {
    ns2_stick_cal c;
    memset(&c, 0, sizeof c);
    ns2_unpack12(p + 0, &c.x.center, &c.y.center);
    ns2_unpack12(p + 3, &c.x.positive, &c.y.positive);
    ns2_unpack12(p + 6, &c.x.negative, &c.y.negative);
    c.valid = axis_ok(&c.x) && axis_ok(&c.y);
    if (out) *out = c;
    return c.valid;
}

bool ns2_parse_user_stick_cal(const uint8_t p[11], ns2_stick_cal *out) {
    /* 标记是小端 0xA1B2，内存里是 B2 A1（SDL、内核一致） */
    if (p[0] != 0xB2 || p[1] != 0xA1) return false;
    return ns2_parse_stick_cal(p + 2, out);
}

void ns2_stick_cal_default(ns2_stick_cal *out) {
    out->x.center = out->y.center = 2048;
    out->x.positive = out->x.negative = 1600;
    out->y.positive = out->y.negative = 1600;
    out->valid = false;
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

float ns2_stick_axis(const ns2_axis_cal *cal, uint16_t raw, float deadzone) {
    float v = (float)raw - (float)cal->center;
    float range = v >= 0 ? (float)cal->positive : (float)cal->negative;
    if (range < 1) range = 1;
    v = clampf(v / range, -1.0f, 1.0f);
    if (deadzone > 0) {
        float a = fabsf(v);
        if (a <= deadzone) return 0.0f;
        v = (v < 0 ? -1.0f : 1.0f) * (a - deadzone) / (1.0f - deadzone);
    }
    return v;
}

void ns2_stick_apply(const ns2_stick_cal *cal, uint16_t raw_x, uint16_t raw_y, float deadzone,
                     float *out_x, float *out_y) {
    float x = ns2_stick_axis(&cal->x, raw_x, 0);
    float y = ns2_stick_axis(&cal->y, raw_y, 0);
    if (deadzone > 0) {
        float m = sqrtf(x * x + y * y);
        if (m <= deadzone) {
            x = y = 0;
        } else {
            float k = (m - deadzone) / (1.0f - deadzone) / m;
            x = clampf(x * k, -1.0f, 1.0f);
            y = clampf(y * k, -1.0f, 1.0f);
        }
    }
    *out_x = x;
    *out_y = y;
}

bool ns2_parse_gyro_bias(const uint8_t p[16], float bias[3], float *cal_temperature) {
    float t = rdf32(p);
    float b[3] = {rdf32(p + 4), rdf32(p + 8), rdf32(p + 12)};
    for (int i = 0; i < 3; i++) {
        /* 没写过的闪存是 FF FF FF FF（NaN）；零偏超过 0.2 rad/s（约 11 °/s）也不合理 */
        if (!(b[i] == b[i]) || fabsf(b[i]) > 0.2f) return false;
    }
    for (int i = 0; i < 3; i++) bias[i] = b[i];
    if (cal_temperature) *cal_temperature = t;
    return true;
}

/* ------------------------------------------------------------------------- */
/* 体感                                                                       */
/* ------------------------------------------------------------------------- */

void ns2_imu_to_gcmotion(const int16_t ra[3], const int16_t rg[3], float dps_per_lsb, const float bias[3],
                         float accel_g[3], float gyro_rad_s[3]) {
    const float deg2rad = 0.017453292519943295f;
    for (int i = 0; i < 3; i++) {
        /* 原始轴已经是 x 右、y 上沿、z 正面向外，只需要把加速度从"支撑力"翻成"重力方向" */
        accel_g[i] = -(float)ra[i] * NS2_ACCEL_G_PER_LSB;
        float w = (float)rg[i] * dps_per_lsb * deg2rad;
        if (bias) w -= bias[i];
        gyro_rad_s[i] = w;
    }
}

int ns2_battery_percent(uint16_t mv) {
    /* 单节锂电池静置电压的粗略曲线。手柄负载下电压会低一些，所以只是估计。 */
    static const uint16_t v[] = {3300, 3500, 3600, 3700, 3750, 3800, 3900, 4000, 4100, 4200};
    static const uint8_t pc[] = {0, 5, 10, 25, 40, 50, 65, 80, 92, 100};
    if (mv == 0) return -1;
    if (mv <= v[0]) return 0;
    for (int i = 1; i < (int)(sizeof v / sizeof v[0]); i++) {
        if (mv <= v[i]) return pc[i - 1] + (pc[i] - pc[i - 1]) * (mv - v[i - 1]) / (v[i] - v[i - 1]);
    }
    return 100;
}

/* ------------------------------------------------------------------------- */
/* 震动                                                                       */
/* ------------------------------------------------------------------------- */

static uint16_t c10(uint16_t v) { return v > 1023 ? 1023 : v; }

void ns2_rumble_encode(const ns2pad_rumble_frame *f, uint8_t out[5]) {
    /* 40 位：高频率[0..9] 高振幅[10..19] 低频率[20..29] 低振幅[30..39]，小端 */
    uint64_t bits = (uint64_t)c10(f->high_freq) |
                    ((uint64_t)c10(f->high_amp) << 10) |
                    ((uint64_t)c10(f->low_freq) << 20) |
                    ((uint64_t)c10(f->low_amp) << 30);
    for (int i = 0; i < 5; i++) out[i] = (uint8_t)(bits >> (8 * i));
}

size_t ns2_build_rumble_output(uint8_t out[NS2_OUTPUT02_SIZE], uint8_t seq,
                               const ns2pad_rumble_frame *left, const ns2pad_rumble_frame *right) {
    static const ns2pad_rumble_frame silent = {NS2_RUMBLE_DEFAULT_HIGH_FREQ, 0, NS2_RUMBLE_DEFAULT_LOW_FREQ, 0};
    if (!left) left = &silent;
    if (!right) right = left;
    memset(out, 0, NS2_OUTPUT02_SIZE);
    out[0x00] = 0x00; /* 蓝牙下"报告 ID"字节固定为 0 */
    out[0x01] = (uint8_t)(0x50 | (seq & 0x0F));
    ns2_rumble_encode(left, out + 0x02);
    out[0x11] = (uint8_t)(0x50 | (seq & 0x0F));
    ns2_rumble_encode(right, out + 0x12);
    return NS2_OUTPUT02_SIZE;
}

/* ------------------------------------------------------------------------- */
/* 会话                                                                       */
/* ------------------------------------------------------------------------- */

void ns2_session_options_default(ns2_session_options *o) {
    memset(o, 0, sizeof *o);
    o->player_leds = 0x01;
    o->connect_vibration = true;
    o->use_combined_channel = false;
    o->stick_deadzone = 0.0f;
    o->step_timeout_ns = 600ull * 1000 * 1000;
    o->max_retries = 2;
}

void ns2_session_init(ns2_session *s, const ns2_session_options *opts) {
    memset(s, 0, sizeof *s);
    if (opts) s->opts = *opts;
    else ns2_session_options_default(&s->opts);
    if (!s->opts.step_timeout_ns) s->opts.step_timeout_ns = 600ull * 1000 * 1000;
    ns2_stick_cal_default(&s->left_cal);
    ns2_stick_cal_default(&s->right_cal);
    s->gyro_dps_per_lsb = NS2_GYRO_DPS_PER_LSB;
    s->ts_scale = 1.0;
    s->info.product_id = NS2PAD_PID_PRO2;
    strncpy(s->info.name, ns2_product_name(NS2PAD_PID_PRO2), sizeof s->info.name - 1);
    s->info.player_index = 0;
    s->step = NS2_STEP_CMD07;
}

/* 每一步发什么、等哪个响应。 */
typedef struct step_desc {
    uint8_t cmd, sub;
    uint32_t address; /* 读闪存的步骤 */
    uint8_t len;
    bool required;    /* 失败会让 poll 最后返回 FAILED */
    bool no_retry;    /* 等一次超时就继续，不重发（两份抓包里 0x0C/0x02 都没有收到响应） */
    bool no_wait;     /* 发完就进下一步，不等响应 */
} step_desc;

static const step_desc k_steps[NS2_STEP_DONE] = {
    [NS2_STEP_CMD07]             = {NS2_CMD_07, 0x01, 0, 0, false, false, false},
    [NS2_STEP_READ_DEVICE_INFO]  = {NS2_CMD_FLASH, 0x04, 0x13000, 0x40, false, false, false},
    [NS2_STEP_CMD16]             = {NS2_CMD_16, 0x01, 0, 0, false, false, false},
    [NS2_STEP_CONNECT_VIBRATION] = {NS2_CMD_VIBRATION, 0x02, 0, 0, false, false, false},
    [NS2_STEP_PLAYER_LEDS]       = {NS2_CMD_LED, 0x07, 0, 0, false, false, false},
    [NS2_STEP_SET_FEATURE_MASK]  = {NS2_CMD_FEATURE, 0x02, 0, 0, false, true, false},
    [NS2_STEP_READ_LEFT_STICK]   = {NS2_CMD_FLASH, 0x04, 0x13080, 0x40, false, false, false},
    [NS2_STEP_READ_RIGHT_STICK]  = {NS2_CMD_FLASH, 0x04, 0x130C0, 0x40, false, false, false},
    [NS2_STEP_READ_USER_LEFT]    = {NS2_CMD_FLASH, 0x04, 0x1FC040, 0x0B, false, false, false},
    [NS2_STEP_READ_USER_RIGHT]   = {NS2_CMD_FLASH, 0x04, 0x1FC080, 0x0B, false, false, false},
    [NS2_STEP_READ_GYRO_BIAS]    = {NS2_CMD_FLASH, 0x04, 0x13040, 0x10, false, false, false},
    [NS2_STEP_CMD11]             = {NS2_CMD_11, 0x03, 0, 0, false, false, false},
    [NS2_STEP_VIBRATION_CONFIG]  = {NS2_CMD_VIBRATION, 0x08, 0, 0, false, false, false},
    [NS2_STEP_ENABLE_FEATURES]   = {NS2_CMD_FEATURE, 0x04, 0, 0, true, false, false},
    [NS2_STEP_USB_01_0C]         = {NS2_CMD_NFC, 0x0C, 0, 0, false, false, true},
    [NS2_STEP_USB_01_01]         = {NS2_CMD_NFC, 0x01, 0, 0, false, false, true},
    [NS2_STEP_USB_REPORT_FORMAT] = {NS2_CMD_INIT, 0x0A, 0, 0, false, false, true},
    [NS2_STEP_USB_START_OUTPUT]  = {NS2_CMD_INIT, 0x0D, 0, 0, false, false, true},
};

/* 这一步实际用的子命令：USB 下读闪存是 0x01，0x11 是 1。 */
static uint8_t step_sub(const ns2_session *s, ns2_init_step step) {
    if (s->opts.usb && k_steps[step].cmd == NS2_CMD_FLASH) return 0x01;
    if (s->opts.usb && step == NS2_STEP_CMD11) return 0x01;
    return k_steps[step].sub;
}

static size_t build_step(const ns2_session *s, ns2_init_step step, uint8_t *out, size_t cap) {
    const step_desc *d = &k_steps[step];
    switch (step) {
    case NS2_STEP_READ_DEVICE_INFO:
    case NS2_STEP_READ_LEFT_STICK:
    case NS2_STEP_READ_RIGHT_STICK:
    case NS2_STEP_READ_USER_LEFT:
    case NS2_STEP_READ_USER_RIGHT:
    case NS2_STEP_READ_GYRO_BIAS:
        if (s->opts.usb) {
            uint8_t a[8] = {NS2_USB_FLASH_LEN, 0x00, 0x00, 0x00, (uint8_t)d->address, (uint8_t)(d->address >> 8),
                            (uint8_t)(d->address >> 16), (uint8_t)(d->address >> 24)};
            return ns2_build_command(out, cap, NS2_CMD_FLASH, 0x01, a, sizeof a);
        }
        return ns2_build_flash_read(out, cap, d->address, d->len);
    case NS2_STEP_CONNECT_VIBRATION:
        return ns2_build_vibration_sample(out, cap, 0x03);
    case NS2_STEP_PLAYER_LEDS:
        return ns2_build_player_leds(out, cap, s->opts.player_leds);
    case NS2_STEP_SET_FEATURE_MASK:
        return ns2_build_feature(out, cap, 0x02, NS2_FEATURES_PRO);
    case NS2_STEP_ENABLE_FEATURES:
        return ns2_build_feature(out, cap, 0x04, NS2_FEATURES_PRO);
    case NS2_STEP_VIBRATION_CONFIG: {
        /* 任天堂主机（bluetooth_interface.md 初始化表）和 SDL 的 USB 初始化都发这段，含义未知 */
        static const uint8_t data[20] = {0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x35,
                                         0x00, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        return ns2_build_command(out, cap, NS2_CMD_VIBRATION, 0x08, data, sizeof data);
    }
    case NS2_STEP_USB_REPORT_FORMAT: {
        static const uint8_t data[4] = {0x05, 0x00, 0x00, 0x00};
        return ns2_build_command(out, cap, NS2_CMD_INIT, 0x0A, data, sizeof data);
    }
    case NS2_STEP_USB_START_OUTPUT: {
        static const uint8_t data[8] = {0x01, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
        return ns2_build_command(out, cap, NS2_CMD_INIT, 0x0D, data, sizeof data);
    }
    default:
        return ns2_build_command(out, cap, d->cmd, step_sub(s, step), NULL, 0);
    }
}

static void finish_tx(const ns2_session *s, ns2_tx *tx, const uint8_t *cmd, size_t len) {
    tx->channel = 0;
    if (s->opts.usb) {
        memcpy(tx->bytes, cmd, len);
        tx->len = len;
        if (len > 2) tx->bytes[2] = NS2_TRANSPORT_USB;
    } else if (s->opts.use_combined_channel) {
        tx->len = ns2_wrap_combined(tx->bytes, sizeof tx->bytes, cmd, len);
    } else {
        memcpy(tx->bytes, cmd, len);
        tx->len = len;
    }
}

static void advance(ns2_session *s) {
    s->step = (ns2_init_step)(s->step + 1);
    s->step_sent = false;
    s->retries = 0;
}

static bool step_skipped(const ns2_session *s, ns2_init_step step) {
    if (step >= NS2_STEP_USB_01_0C && !s->opts.usb) return true;
    return step == NS2_STEP_CONNECT_VIBRATION && !s->opts.connect_vibration;
}

ns2_poll_result ns2_session_poll(ns2_session *s, uint64_t now_ns, ns2_tx *tx) {
    uint8_t cmd[64];
    while (s->step < NS2_STEP_DONE) {
        if (step_skipped(s, s->step)) {
            advance(s);
            continue;
        }
        if (s->step_sent && k_steps[s->step].no_wait) {
            advance(s);
            continue;
        }
        if (!s->step_sent || now_ns - s->sent_at_ns > s->opts.step_timeout_ns) {
            if (s->step_sent) {
                if (s->retries >= s->opts.max_retries || k_steps[s->step].no_retry) {
                    if (k_steps[s->step].required) s->any_required_failed = true;
                    advance(s);
                    continue;
                }
                s->retries++;
            }
            size_t n = build_step(s, s->step, cmd, sizeof cmd);
            finish_tx(s, tx, cmd, n);
            s->step_sent = true;
            s->sent_at_ns = now_ns;
            return NS2_POLL_SEND;
        }
        return NS2_POLL_IDLE;
    }
    if (!s->ready_reported) {
        s->ready_reported = true;
        s->info.imu_enabled = s->imu_enabled;
        return s->any_required_failed ? NS2_POLL_FAILED : NS2_POLL_READY;
    }
    if (s->queue_count > 0) {
        int i = s->queue_head;
        finish_tx(s, tx, s->queue[i], s->queue_len[i]);
        s->queue_head = (s->queue_head + 1) % 8;
        s->queue_count--;
        return NS2_POLL_SEND;
    }
    return NS2_POLL_IDLE;
}

bool ns2_session_queue_command(ns2_session *s, const uint8_t *cmd, size_t len) {
    if (s->queue_count >= 8 || len == 0 || len > sizeof s->queue[0]) return false;
    int i = (s->queue_head + s->queue_count) % 8;
    memcpy(s->queue[i], cmd, len);
    s->queue_len[i] = (uint8_t)len;
    s->queue_count++;
    return true;
}

static void copy_serial(char *dst, size_t cap, const uint8_t *src, size_t n) {
    size_t j = 0;
    for (size_t i = 0; i < n && j + 1 < cap; i++) {
        if (src[i] == 0 || src[i] == 0xFF) break;
        dst[j++] = (src[i] >= 0x20 && src[i] < 0x7F) ? (char)src[i] : '?';
    }
    dst[j] = 0;
}

static void handle_flash(ns2_session *s, uint32_t addr, const uint8_t *b, size_t n) {
    switch (addr) {
    case 0x13000:
        if (n >= 0x25) {
            copy_serial(s->info.serial, sizeof s->info.serial, b + 0x02, 0x10);
            uint16_t pid = rd16(b + 0x14);
            if (rd16(b + 0x12) == NS2_VENDOR_ID && pid >= 0x2060 && pid <= 0x207F) {
                s->info.product_id = pid;
                memset(s->info.name, 0, sizeof s->info.name);
                strncpy(s->info.name, ns2_product_name(pid), sizeof s->info.name - 1);
            }
            memcpy(s->info.body_color, b + 0x19, 3);
            memcpy(s->info.button_color, b + 0x1C, 3);
        }
        break;
    case 0x13080:
        if (n >= 0x31 && !(s->info.calibration_flags & NS2PAD_CAL_LEFT_STICK_USER) &&
            ns2_parse_stick_cal(b + 0x28, &s->left_cal))
            s->info.calibration_flags |= NS2PAD_CAL_LEFT_STICK_FACTORY;
        break;
    case 0x130C0:
        if (n >= 0x31 && !(s->info.calibration_flags & NS2PAD_CAL_RIGHT_STICK_USER) &&
            ns2_parse_stick_cal(b + 0x28, &s->right_cal))
            s->info.calibration_flags |= NS2PAD_CAL_RIGHT_STICK_FACTORY;
        break;
    case 0x1FC040:
        if (n >= 11 && ns2_parse_user_stick_cal(b, &s->left_cal))
            s->info.calibration_flags |= NS2PAD_CAL_LEFT_STICK_USER;
        break;
    case 0x1FC080:
        if (n >= 11 && ns2_parse_user_stick_cal(b, &s->right_cal))
            s->info.calibration_flags |= NS2PAD_CAL_RIGHT_STICK_USER;
        break;
    case 0x13040:
        if (n >= 16 && ns2_parse_gyro_bias(b, s->gyro_bias, NULL))
            s->info.calibration_flags |= NS2PAD_CAL_GYRO_BIAS;
        break;
    default:
        break;
    }
}

bool ns2_session_on_response(ns2_session *s, const uint8_t *p, size_t n, size_t prefix, uint64_t now_ns) {
    (void)now_ns;
    ns2_response r;
    if (!ns2_parse_response(p, n, prefix, &r)) return false;
    if (s->step >= NS2_STEP_DONE || !s->step_sent) return true;
    const step_desc *d = &k_steps[s->step];
    if (r.cmd != d->cmd || r.sub != step_sub(s, s->step)) return true; /* 不是在等的那条（例如后来才到的重发响应） */

    if (d->cmd == NS2_CMD_FLASH) {
        uint32_t addr;
        const uint8_t *b;
        size_t len;
        if (!ns2_parse_flash_read(&r, &addr, &b, &len) || addr != d->address) {
            return true; /* 读失败或地址不对：等超时后重发 */
        }
        handle_flash(s, addr, b, len);
    } else if (s->step == NS2_STEP_ENABLE_FEATURES) {
        s->imu_enabled = ns2_response_ok(&r);
    }
    advance(s);
    return true;
}

size_t ns2_session_rumble_report(ns2_session *s, const ns2pad_rumble_frame *left,
                                 const ns2pad_rumble_frame *right, ns2_tx *tx) {
    tx->channel = 1;
    tx->len = ns2_build_rumble_output(tx->bytes, s->rumble_seq, left, right);
    s->rumble_seq = (uint8_t)((s->rumble_seq + 1) & 0x0F);
    return tx->len;
}

/* 设备时钟 → 主机时钟。收到时刻 = 采样时刻 + 传输延迟（≥0），所以"收到时刻 - 设备时间"的最小值最接近真正的偏移。
   取最小值，再允许它按 500 ppm 慢慢上升，跟上两个时钟之间剩下的漂移。 */
static uint64_t map_to_host(ns2_session *s, uint64_t dev_us, uint64_t now_ns) {
    int64_t cur = (int64_t)now_ns - (int64_t)(dev_us * 1000u);
    if (!s->have_offset || cur < s->offset_ns) {
        s->offset_ns = cur;
        s->have_offset = true;
    } else {
        uint64_t elapsed = now_ns - s->offset_updated_ns;
        int64_t allowed = (int64_t)(elapsed / 2000u); /* 500 ppm */
        int64_t diff = cur - s->offset_ns;
        s->offset_ns += diff < allowed ? diff : allowed;
    }
    s->offset_updated_ns = now_ns;
    int64_t t = (int64_t)(dev_us * 1000u) + s->offset_ns;
    if (t < 0) t = 0;
    if ((uint64_t)t > now_ns) t = (int64_t)now_ns;
    return (uint64_t)t;
}

/* 体感时钟校正（见 ns2_session 里的说明）。连上后跳过前 5 帧，之后每 50 帧更新一次比例。 */
static void track_timing(ns2_session *s, uint64_t dev_raw, uint32_t counter, uint64_t now_ns) {
    s->timing_samples++;
    if (s->timing_samples == 5) {
        s->timing_first_dev = dev_raw;
        s->timing_first_host = now_ns;
        s->timing_first_counter = counter;
        return;
    }
    if (s->timing_samples < 105 || (s->timing_samples - 105) % 50 != 0) return;
    double host_us = (double)(now_ns - s->timing_first_host) / 1000.0;
    double counter_us = (double)(uint32_t)(counter - s->timing_first_counter) * 1000.0;
    double dev = (double)(dev_raw - s->timing_first_dev);
    if (host_us < 500000.0 || dev <= 0) return; /* 不到 0.5 秒，继续等 */
    /* 计数器和主机时钟相差 5% 以内就用计数器（它没有蓝牙延迟的抖动），否则用主机时钟 */
    double ref = (counter_us > host_us * 0.95 && counter_us < host_us * 1.05) ? counter_us : host_us;
    double ratio = dev / ref;
    if (!s->timing_checked) {
        s->timing_checked = true;
        s->info.calibration_flags |= NS2PAD_CAL_IMU_TIMING_CHECKED;
        if (!(ratio > 0.9 && ratio < 1.1)) {
            s->gyro_dps_per_lsb = NS2_GYRO_DPS_PER_LSB_ALT;
            s->info.imu_timestamp_quirk = true;
        }
    }
    double scale = 1.0 / ratio;
    if (fabs(scale - s->ts_scale) > 0.001 * s->ts_scale) s->have_offset = false; /* 比例变了：重新估计时钟偏移 */
    s->ts_scale = scale;
}

bool ns2_session_on_input(ns2_session *s, const uint8_t *p, size_t n, uint64_t now_ns, ns2pad_state *out) {
    ns2_input05 in;
    if (!ns2_parse_input05(p, n, &in)) return false;

    ns2pad_state st;
    memset(&st, 0, sizeof st);
    st.buttons = in.buttons;
    st.raw_left_x = in.left[0];
    st.raw_left_y = in.left[1];
    st.raw_right_x = in.right[0];
    st.raw_right_y = in.right[1];
    ns2_stick_apply(&s->left_cal, in.left[0], in.left[1], s->opts.stick_deadzone, &st.left_x, &st.left_y);
    ns2_stick_apply(&s->right_cal, in.right[0], in.right[1], s->opts.stick_deadzone, &st.right_x, &st.right_y);

    st.battery_mv = in.battery_mv;
    st.battery_percent = (int8_t)ns2_battery_percent(in.battery_mv);
    st.charge_state_raw = in.charge_state;
    st.external_power = in.charge_state != 0;

    st.report_counter = in.counter;
    st.counter_delta = s->reports ? in.counter - s->last_counter : 0;
    s->last_counter = in.counter;
    s->reports++;
    st.reports_received = s->reports;
    st.received_time_ns = now_ns;
    st.sample_time_ns = now_ns;

    bool imu_data = in.accel[0] | in.accel[1] | in.accel[2] | in.gyro[0] | in.gyro[1] | in.gyro[2];
    if (in.imu_timestamp != 0 && imu_data) { /* 体感刚开启的第一帧时间戳有了，数据还全是 0 */
        /* 32 位时间戳展开成 64 位 */
        uint64_t prev_raw = s->ts_high + s->last_raw_ts;
        if (s->have_last_ts && in.imu_timestamp < s->last_raw_ts &&
            (s->last_raw_ts - in.imu_timestamp) > 0x80000000u)
            s->ts_high += 0x100000000ull;
        uint64_t dev_raw = s->ts_high + in.imu_timestamp;
        bool had = s->have_last_ts;
        s->have_last_ts = true;
        s->last_raw_ts = in.imu_timestamp;

        track_timing(s, dev_raw, in.counter, now_ns);

        /* 微秒累加：这样中途换算比例变了也不会跳 */
        uint64_t us = s->imu_us;
        if (had && dev_raw >= prev_raw) us += (uint64_t)((double)(dev_raw - prev_raw) * s->ts_scale + 0.5);
        else if (!had) us = (uint64_t)((double)dev_raw * s->ts_scale);
        s->imu_us = us;

        st.imu_valid = true;
        st.imu_timestamp_us = us;
        st.sample_time_ns = map_to_host(s, us, now_ns);
        st.temperature_c = 25.0f + (float)in.temperature / 126.9f;
        ns2_imu_to_gcmotion(in.accel, in.gyro, s->gyro_dps_per_lsb,
                            (s->info.calibration_flags & NS2PAD_CAL_GYRO_BIAS) ? s->gyro_bias : NULL,
                            st.accel_g, st.gyro_rad_s);
        for (int i = 0; i < 3; i++) st.gyro_deg_s[i] = st.gyro_rad_s[i] * 57.29577951308232f;
    }

    s->last = st;
    s->have_last = true;
    if (out) *out = st;
    return true;
}
