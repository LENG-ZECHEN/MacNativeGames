/*
 * ns2_core.h — Switch 2 手柄协议核心（纯 C99）。
 *
 * 这一层只处理字节：解析手柄发来的报告、生成要发给手柄的命令和震动报告、
 * 解析校准数据、把原始数值换算成物理单位，以及握手流程的状态机。
 * 不碰蓝牙、文件、线程、时钟——时间由调用方传进来。
 * 所以换成 Windows、Linux 或单片机上的蓝牙层，这一层可以原样复用。
 *
 * 协议出处见 docs/protocol.md（主要是 ndeadly/switch2_controller_research）。
 *
 * 典型用法（传输层要做的事）：
 *   ns2_session s; ns2_session_init(&s, &opts);
 *   连上手柄、打开命令响应通知（特征 0x001E）之后，定时（例如每 10 ms）调用 ns2_session_poll()：
 *     NS2_POLL_SEND  → 把 tx 里的字节写到命令特征（0x0014 或 0x0016，见 ns2_tx.channel）；
 *     NS2_POLL_READY → 握手完成：写 0x8500 到报告速率描述符，打开输入报告 0x05（0x000A）的通知；
 *     NS2_POLL_IDLE  → 什么都不用做。
 *   收到命令响应（0x001E / 0x001A）→ ns2_session_on_response()。
 *   收到输入报告（0x000A）→ ns2_session_on_input()，得到一帧 ns2pad_state。
 */
#ifndef NS2_CORE_H
#define NS2_CORE_H

#include "ns2pad.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------- */
/* GATT 常量（bluetooth_interface.md）                                         */
/* ------------------------------------------------------------------------- */

#define NS2_UUID_SERVICE           "ab7de9be-89fe-49ad-828f-118f09df7fd0"
#define NS2_UUID_INPUT_COMMON      "ab7de9be-89fe-49ad-828f-118f09df7fd2" /* 0x000A 输入报告 0x05（所有手柄） */
#define NS2_UUID_INPUT_PRO         "7492866c-ec3e-4619-8258-32755ffcc0f8" /* 0x000E 输入报告 0x09（Pro 2） */
#define NS2_UUID_OUTPUT_PRO        "cc483f51-9258-427d-a939-630c31f72b05" /* 0x0012 输出报告 0x02（Pro 2 震动） */
#define NS2_UUID_COMMAND           "649d4ac9-8eb7-4e6c-af44-1ea54fe5f005" /* 0x0014 命令（所有手柄） */
#define NS2_UUID_COMBINED_PRO      "3dacbc7e-6955-40b5-8eaf-6f9809e8b379" /* 0x0016 震动+命令（Pro 2） */
#define NS2_UUID_RESPONSE_BASIC    "c765a961-d9d8-4d36-a20a-5315b111836a" /* 0x001A 命令响应 #1 */
#define NS2_UUID_RESPONSE_PRO      "506d9f7d-4278-4e95-a549-326ba77657e0" /* 0x001E 命令响应 #2（Pro 2） */
#define NS2_UUID_REPORT_RATE_DESC  "679d5510-5a24-4dee-9557-95df80486ecb" /* "Set Report Rate?" 描述符 */

/* 握手完成后写到报告速率描述符的值（抓包里写的是 0x0010 句柄，即 0x09 输入特征下的那个描述符）。 */
#define NS2_REPORT_RATE_VALUE_0    0x85
#define NS2_REPORT_RATE_VALUE_1    0x00

/* 广播里的厂商数据（CoreBluetooth 的 manufacturer data 含开头 2 字节公司 ID）。 */
#define NS2_ADV_COMPANY_ID         0x0553
#define NS2_VENDOR_ID              0x057E

/* 功能位（commands.md 命令 0x0C）。 */
enum {
    NS2_FEATURE_BUTTONS  = 0x01,
    NS2_FEATURE_STICKS   = 0x02,
    NS2_FEATURE_IMU      = 0x04,
    NS2_FEATURE_MOUSE    = 0x10,
    NS2_FEATURE_RUMBLE   = 0x20,
    NS2_FEATURE_MAGNETO  = 0x80,
    NS2_FEATURES_PRO     = 0x2F  /* 任天堂给 Pro 2 用的组合：按键+摇杆+体感+震动 */
};

/* 命令编号（commands.md）。 */
enum {
    NS2_CMD_NFC       = 0x01,
    NS2_CMD_FLASH     = 0x02,
    NS2_CMD_INIT      = 0x03,
    NS2_CMD_07        = 0x07,
    NS2_CMD_LED       = 0x09,
    NS2_CMD_VIBRATION = 0x0A,
    NS2_CMD_BATTERY   = 0x0B,
    NS2_CMD_FEATURE   = 0x0C,
    NS2_CMD_FW_INFO   = 0x10,
    NS2_CMD_11        = 0x11,
    NS2_CMD_PAIRING   = 0x15,
    NS2_CMD_16        = 0x16
};

#define NS2_DIR_REQUEST      0x91
#define NS2_DIR_RESPONSE     0x01
#define NS2_TRANSPORT_USB    0x00
#define NS2_TRANSPORT_BLE    0x01

/* 命令响应在特征 0x001E 上前面有 14 个 0x00（抓包实测；文档表格写的是 0x0F，有出入，见 docs/protocol.md）。 */
#define NS2_RESPONSE_PREFIX_EXT    0x0E
/* 写到 0x0016 的命令前面要有 1 字节报告 ID（0）+ 左右两段各 16 字节震动数据 = 33 字节。 */
#define NS2_COMBINED_PREFIX_PRO    0x21

/* 输入报告 0x05 的长度（蓝牙下不带报告 ID）：0x3F = 63 字节，抓包实测。
   USB 下从 HID 接口读到的是 64 字节：报告 ID 0x05 + 同样的 63 字节。 */
#define NS2_INPUT05_SIZE           0x3F
/* USB 下读闪存用 0x02/0x01，每次固定 0x40 字节；响应 0x50 字节（8 字节头 + 长度/地址 8 字节 + 数据），分两个 64 字节包到。 */
#define NS2_USB_FLASH_LEN          0x40
/* Pro 2 震动输出报告 0x02 的长度：1 + 16 + 16 + 9 = 42 字节（hid_reports.md）。 */
#define NS2_OUTPUT02_SIZE          0x2A

/* ------------------------------------------------------------------------- */
/* 小工具                                                                      */
/* ------------------------------------------------------------------------- */

/* 解析广播厂商数据（含 2 字节公司 ID）。是 Switch 2 手柄就返回产品 ID（例如 0x2069），否则返回 0。 */
uint16_t ns2_adv_product_id(const uint8_t *mfg, size_t len);

/* 产品 ID 对应的名字，例如 "Pro Controller 2"。不认识时返回 "Switch 2 controller"。 */
const char *ns2_product_name(uint16_t product_id);

/* ------------------------------------------------------------------------- */
/* 命令                                                                       */
/* ------------------------------------------------------------------------- */

/* 组装一条命令：8 字节头 + data。返回总长度；cap 不够时返回 0。
   头：cmd, 0x91, 0x01(蓝牙), sub, 0x00, len, 0x00, 0x00。 */
size_t ns2_build_command(uint8_t *out, size_t cap, uint8_t cmd, uint8_t sub,
                         const uint8_t *data, uint8_t data_len);

/* 读闪存（命令 0x02/0x04）。len 最大 0x4F（蓝牙）。 */
size_t ns2_build_flash_read(uint8_t *out, size_t cap, uint32_t address, uint8_t len);

/* 设置功能掩码（0x0C/0x02）、开启功能（0x0C/0x04）、关闭功能（0x0C/0x05）。 */
size_t ns2_build_feature(uint8_t *out, size_t cap, uint8_t sub, uint8_t flags);

/* 设置玩家灯（0x09/0x07），mask 低 4 位。 */
size_t ns2_build_player_leds(uint8_t *out, size_t cap, uint8_t mask);

/* 播放内置震动样本（0x0A/0x02）。 */
size_t ns2_build_vibration_sample(uint8_t *out, size_t cap, uint8_t sample);

/* 把一条命令包装成写到 0x0016 的格式（前面补 33 字节 0）。返回总长度，cap 不够返回 0。 */
size_t ns2_wrap_combined(uint8_t *out, size_t cap, const uint8_t *cmd, size_t cmd_len);

/* 解析出来的命令响应。 */
typedef struct ns2_response {
    uint8_t cmd;          /* 命令编号 */
    uint8_t sub;          /* 子命令 */
    uint8_t status;       /* 头偏移 0x4，成功时实测为 0x10 */
    uint8_t ack;          /* 头偏移 0x5，成功时实测为 0x78 */
    const uint8_t *data;  /* 头后面的数据（指向输入缓冲区内部） */
    size_t data_len;
} ns2_response;

/* 解析一条命令响应。prefix 是前缀长度：特征 0x001E 用 NS2_RESPONSE_PREFIX_EXT，0x001A 用 0。
   返回 true 表示格式正确（方向字节是 0x01）。 */
bool ns2_parse_response(const uint8_t *p, size_t n, size_t prefix, ns2_response *out);

/* 响应是否表示成功（蓝牙下 ack == 0x78，USB 下实测是 0xF8）。 */
bool ns2_response_ok(const ns2_response *r);

/* 闪存读取（0x02/0x04）响应的数据部分：长度、地址、内容。成功返回 true。 */
bool ns2_parse_flash_read(const ns2_response *r, uint32_t *address, const uint8_t **bytes, size_t *len);

/* ------------------------------------------------------------------------- */
/* 输入报告 0x05                                                              */
/* ------------------------------------------------------------------------- */

/* 输入报告 0x05 的原始字段（全部未经换算）。 */
typedef struct ns2_input05 {
    uint32_t counter;          /* 0x00 */
    uint32_t buttons;          /* 0x04 */
    uint16_t left[2];          /* 0x0A 左摇杆 x、y，12 位 */
    uint16_t right[2];         /* 0x0D 右摇杆 x、y，12 位 */
    int16_t  magnetometer[3];  /* 0x19，需功能位 7 */
    uint16_t battery_mv;       /* 0x1F */
    uint8_t  charge_state;     /* 0x21 */
    uint32_t imu_timestamp;    /* 0x2A，通常是微秒；0 表示体感没开 */
    int16_t  temperature;      /* 0x2E，相对 25 °C，1/126.9 °C 每单位 */
    int16_t  accel[3];         /* 0x30 原始轴 x、y、z */
    int16_t  gyro[3];          /* 0x36 原始轴 x、y、z */
} ns2_input05;

/* 解析输入报告 0x05（蓝牙格式，不带报告 ID）。长度不足 0x3C 返回 false。 */
bool ns2_parse_input05(const uint8_t *p, size_t n, ns2_input05 *out);

/* 解析打包的 12 位双轴值（3 字节 → x、y）。摇杆和校准数据都用这种格式。 */
void ns2_unpack12(const uint8_t p[3], uint16_t *x, uint16_t *y);

/* ------------------------------------------------------------------------- */
/* 校准                                                                       */
/* ------------------------------------------------------------------------- */

typedef struct ns2_axis_cal {
    uint16_t center;   /* 中心原始值 */
    uint16_t positive; /* 从中心到正方向满程的原始值距离 */
    uint16_t negative; /* 从中心到负方向满程的原始值距离 */
} ns2_axis_cal;

typedef struct ns2_stick_cal {
    ns2_axis_cal x, y;
    bool valid;
} ns2_stick_cal;

/* 解析 9 字节的摇杆校准（出厂：闪存 0x130A8 / 0x130E8）：中心、正向距离、负向距离，各一对 12 位值。
   数值明显不合理（中心不在 1000..3000、距离不在 500..2047）时返回 false。 */
bool ns2_parse_stick_cal(const uint8_t p[9], ns2_stick_cal *out);

/* 解析 11 字节的用户摇杆校准（闪存 0x1FC040 / 0x1FC080）：2 字节标记 B2 A1 + 9 字节同上。
   没有标记（没做过用户校准，全是 FF）时返回 false。 */
bool ns2_parse_user_stick_cal(const uint8_t p[11], ns2_stick_cal *out);

/* 默认摇杆校准（读不到时用）：中心 2048，两个方向都 1600。 */
void ns2_stick_cal_default(ns2_stick_cal *out);

/* 用校准把原始值换算成 -1..1，并应用内圈死区（0 表示不加）。 */
float ns2_stick_axis(const ns2_axis_cal *cal, uint16_t raw, float deadzone);

/* 换算一个摇杆（含二维死区，按到中心的距离算）。y 向上为正。 */
void ns2_stick_apply(const ns2_stick_cal *cal, uint16_t raw_x, uint16_t raw_y, float deadzone,
                     float *out_x, float *out_y);

/* 陀螺仪零偏：闪存 0x13040 起 16 字节，4 个小端 float。
   SDL 用后 3 个（偏移 4、8、12）作为原始轴 x、y、z 的零偏，单位 rad/s；第 1 个推测是校准时的温度。 */
bool ns2_parse_gyro_bias(const uint8_t p[16], float bias_rad_s[3], float *cal_temperature);

/* ------------------------------------------------------------------------- */
/* 体感换算                                                                   */
/* ------------------------------------------------------------------------- */

/* 原始加速度满量程 ±8 G（hid_reports.md）。 */
#define NS2_ACCEL_G_PER_LSB      (8.0f / 32767.0f)
/* 原始角速度满量程 ±2000 °/s（hid_reports.md）。SDL 实际用 34.8 rad/s（约 1994 °/s）。 */
#define NS2_GYRO_DPS_PER_LSB     (2000.0f / 32767.0f)
/* SDL 发现：有些手柄时间戳不是微秒，这类手柄的陀螺仪满量程按 40 rad/s（约 2292 °/s）算。 */
#define NS2_GYRO_DPS_PER_LSB_ALT (40.0f * 57.29577951f / 32767.0f)

/* 原始轴 → GCMotion 坐标系。
   原始轴（按 SDL 的 USB 驱动推断）：x 朝右、y 朝上沿、z 垂直正面向外；
   加速度是"支撑力"方向（平放时 z = +1 G）。GCMotion 要的是重力方向（平放时 z = -1 G），所以加速度三轴取反，
   角速度不变。这是最需要真机确认的一点，见 docs/testing-checklist.md。 */
void ns2_imu_to_gcmotion(const int16_t raw_accel[3], const int16_t raw_gyro[3],
                         float gyro_dps_per_lsb, const float gyro_bias_rad_s[3],
                         float accel_g[3], float gyro_rad_s[3]);

/* 电压 → 电量百分比（锂电池放电曲线的粗略估计）。 */
int ns2_battery_percent(uint16_t mv);

/* ------------------------------------------------------------------------- */
/* 震动                                                                       */
/* ------------------------------------------------------------------------- */

/* 默认频率码（SDL、Linux 内核模拟普通震动用的值）。 */
#define NS2_RUMBLE_DEFAULT_HIGH_FREQ 0x187
#define NS2_RUMBLE_DEFAULT_LOW_FREQ  0x112
/* 振幅码安全上限（SDL 29000/65535、内核 450/1023，都约为 44%）。 */
#define NS2_RUMBLE_SAFE_MAX_AMP      450

/* 把一帧 HD 震动参数编码成 5 字节：四个 10 位字段依次小端打包（高频率、高振幅、低频率、低振幅）。 */
void ns2_rumble_encode(const ns2pad_rumble_frame *f, uint8_t out[5]);

/* 组装 Pro 2 的震动输出报告（写到 0x0012，42 字节）。
   每侧 16 字节的块：第 0 字节 0x50 | (seq & 0xF)，后面 5 字节是编码后的帧（SDL/内核的 USB 格式）。
   right 为 NULL 时两侧相同。返回长度。 */
size_t ns2_build_rumble_output(uint8_t out[NS2_OUTPUT02_SIZE], uint8_t seq,
                               const ns2pad_rumble_frame *left, const ns2pad_rumble_frame *right);

/* ------------------------------------------------------------------------- */
/* 会话：握手状态机 + 每帧换算                                                  */
/* ------------------------------------------------------------------------- */

typedef enum ns2_poll_result {
    NS2_POLL_IDLE = 0,   /* 现在没事做 */
    NS2_POLL_SEND = 1,   /* 把 tx 发出去 */
    NS2_POLL_READY = 2,  /* 握手完成（只返回一次）：打开输入通知 */
    NS2_POLL_FAILED = 3  /* 必需步骤多次超时（只返回一次）；仍可尝试打开输入通知 */
} ns2_poll_result;

/* 要发送的数据。 */
typedef struct ns2_tx {
    uint8_t bytes[96];
    size_t len;
    /* 写到哪个特征：0 = 命令特征（0x0014 或 0x0016，取决于 opts.use_combined_channel，已按需加好前缀）；
       1 = 震动输出特征 0x0012。 */
    int channel;
} ns2_tx;

typedef struct ns2_session_options {
    uint8_t player_leds;         /* 握手时点亮的玩家灯，默认 0x01 */
    bool connect_vibration;      /* 握手时播放样本 3 */
    bool use_combined_channel;   /* 命令写到 0x0016（加 33 字节前缀） */
    float stick_deadzone;
    uint64_t step_timeout_ns;    /* 每步等响应的时间，默认 600 ms */
    int max_retries;             /* 每步最多重发次数，默认 2 */
    bool usb;                    /* 走 USB：命令头的传输字节是 0x00，读闪存用 0x02/0x01，0x11 的子命令是 1，
                                    握手最后多几步（设报告格式 0x05、开始输出），见 docs/protocol.md 的 USB 一节 */
} ns2_session_options;

void ns2_session_options_default(ns2_session_options *o);

/* 握手步骤（顺序按抓包和官方流程整理，见 docs/protocol.md）。 */
typedef enum ns2_init_step {
    NS2_STEP_CMD07 = 0,
    NS2_STEP_READ_DEVICE_INFO,    /* 0x13000：序列号、产品 ID、颜色 */
    NS2_STEP_CMD16,
    NS2_STEP_CONNECT_VIBRATION,
    NS2_STEP_PLAYER_LEDS,
    NS2_STEP_SET_FEATURE_MASK,
    NS2_STEP_READ_LEFT_STICK,     /* 0x13080：+0x28 是左摇杆出厂校准 */
    NS2_STEP_READ_RIGHT_STICK,    /* 0x130C0：+0x28 是右摇杆出厂校准 */
    NS2_STEP_READ_USER_LEFT,      /* 0x1FC040 */
    NS2_STEP_READ_USER_RIGHT,     /* 0x1FC080（SDL、内核的地址；文档写 0x1FC060） */
    NS2_STEP_READ_GYRO_BIAS,      /* 0x13040 */
    NS2_STEP_CMD11,               /* 0x11/0x03，内核说震动要靠它才稳定 */
    NS2_STEP_VIBRATION_CONFIG,    /* 0x0A/0x08，任天堂主机和 SDL 都发的一段固定数据，含义未知 */
    NS2_STEP_ENABLE_FEATURES,
    NS2_STEP_USB_01_0C,           /* 以下只在 USB 下发（SDL 的 USB 初始化顺序），不等响应 */
    NS2_STEP_USB_01_01,           /* SDL 注释为 "Enable rumble" */
    NS2_STEP_USB_REPORT_FORMAT,   /* 0x03/0x0A：输入报告用 0x05 格式 */
    NS2_STEP_USB_START_OUTPUT,    /* 0x03/0x0D：开始从 HID 接口发输入报告 */
    NS2_STEP_DONE
} ns2_init_step;

/* 一次连接的全部状态。整块内存，可以直接放在结构体里，不需要释放。 */
typedef struct ns2_session {
    ns2_session_options opts;

    /* 握手 */
    ns2_init_step step;
    bool step_sent;
    int retries;
    uint64_t sent_at_ns;
    bool ready_reported;
    bool imu_enabled;          /* 0x0C/0x04 得到确认 */
    bool any_required_failed;

    /* 握手之后排队的命令（灯、震动样本等） */
    uint8_t queue[8][40];
    uint8_t queue_len[8];
    int queue_head, queue_count;

    /* 设备信息和校准 */
    ns2pad_info info;
    ns2_stick_cal left_cal, right_cal;
    float gyro_bias[3];
    float gyro_dps_per_lsb;

    /* 帧处理 */
    uint32_t reports;
    uint32_t last_counter;
    bool have_last_ts;
    uint32_t last_raw_ts;
    uint64_t ts_high;          /* 时间戳展开用的高位 */
    double ts_scale;           /* 设备时间戳 → 微秒 */
    uint64_t imu_us;           /* 累加出来的体感时间（微秒） */
    /* 体感时钟校正：体感时间戳的时钟不准（抓包实测慢 0.75%），报告计数器却很准（1 kHz，误差约 30 ppm）。
       所以拿计数器（必要时拿主机时钟）当尺子，持续估算体感时间戳的真实比例。
       顺带做 SDL 的检查：比例偏离 1 超过 10% 的就是"时间戳不是微秒"的那类手柄。 */
    int timing_samples;
    uint64_t timing_first_dev, timing_first_host;
    uint32_t timing_first_counter;
    bool timing_checked;
    /* 设备时钟 → 主机时钟的偏移估计（纳秒，有符号） */
    bool have_offset;
    int64_t offset_ns;
    uint64_t offset_updated_ns;

    /* 震动 */
    uint8_t rumble_seq;

    ns2pad_state last;
    bool have_last;
} ns2_session;

void ns2_session_init(ns2_session *s, const ns2_session_options *opts);

/* 推进握手，或取出排队的命令。now_ns 是主机单调时钟。 */
ns2_poll_result ns2_session_poll(ns2_session *s, uint64_t now_ns, ns2_tx *tx);

/* 交给会话一条命令响应。prefix 同 ns2_parse_response。返回 true 表示解析成功。 */
bool ns2_session_on_response(ns2_session *s, const uint8_t *p, size_t n, size_t prefix, uint64_t now_ns);

/* 交给会话一帧输入报告 0x05，得到换算后的状态。返回 false 表示报告无效。 */
bool ns2_session_on_input(ns2_session *s, const uint8_t *p, size_t n, uint64_t now_ns, ns2pad_state *out);

/* 握手完成后排队一条命令（例如设置指示灯）。cmd 是 ns2_build_* 生成的完整命令。队列满返回 false。 */
bool ns2_session_queue_command(ns2_session *s, const uint8_t *cmd, size_t len);

/* 生成一帧震动输出报告（自动递增序号）。 */
size_t ns2_session_rumble_report(ns2_session *s, const ns2pad_rumble_frame *left,
                                 const ns2pad_rumble_frame *right, ns2_tx *tx);

#ifdef __cplusplus
}
#endif

#endif /* NS2_CORE_H */
