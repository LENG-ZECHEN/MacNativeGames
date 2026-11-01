/*
 * ns2pad.h — Nintendo Switch 2 Pro 手柄（Pro Controller 2）驱动库的对外接口。
 *
 * 纯 C 头文件，C、C++、Objective-C、Swift（通过桥接头文件或 module.modulemap）都能直接用。
 *
 * 用法概览：
 *   1. 填好一个 ns2pad_callbacks，调用 ns2pad_start()。库会自己扫描、连接、握手、开启体感。
 *   2. 每收到一帧输入，state 回调会被调用一次（在库自己的后台队列上，不在主线程）。
 *      不想用回调的话，也可以随时调用 ns2pad_get_state() 取最新一帧（线程安全）。
 *   3. 用 ns2pad_set_rumble() 等函数控制震动、指示灯。
 *   4. 结束时调用 ns2pad_stop()。
 *
 * 线程：所有函数都可以在任意线程调用。回调在库内部的一条串行队列上依次触发，
 *       回调里不要做耗时的事，也不要在回调里调用 ns2pad_stop()。
 *
 * 坐标系（和苹果 GCMotion 一致）：
 *   x 朝手柄右侧，y 朝手柄上沿（肩键那一侧），z 垂直于手柄正面向外（朝向玩家脸）。
 *   加速度单位 G，包含重力，且按"重力方向"记：手柄正面朝上平放时 accel = (0, 0, -1)。
 *   角速度用右手定则：绕某轴逆时针转（从该轴正方向往回看）为正。
 *
 * 摇杆：校准后范围 -1..1，x 向右为正，y 向上为正。
 *
 * 时间：本文件里所有 *_time_ns 都是"主机单调时钟"的纳秒数。
 *       在苹果平台上就是 mach_absolute_time() 换算成纳秒（和 clock_gettime_nsec_np(CLOCK_UPTIME_RAW) 相同）。
 *
 * 本库是 MIT 许可证，见仓库根目录 LICENSE。
 */
#ifndef NS2PAD_H
#define NS2PAD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NS2PAD_VERSION_STRING "0.1.0"

/* 同时支持的手柄数量上限。手柄编号（pad）取值 0 .. NS2PAD_MAX_PADS-1。 */
#define NS2PAD_MAX_PADS 8

/* ------------------------------------------------------------------------- */
/* 按键位                                                                     */
/* ------------------------------------------------------------------------- */
/*
 * ns2pad_state.buttons 的每一位对应一个按键，按下为 1。
 * 位的排列和手柄蓝牙输入报告 0x05 偏移 0x4 的 4 字节小端位域完全相同（ndeadly hid_reports.md），
 * 所以库不做任何重排，原样给出。
 * 名字按任天堂的叫法：A 在右、B 在下、X 在上、Y 在左。
 */
enum {
    NS2PAD_BTN_Y       = 1u << 0,
    NS2PAD_BTN_X       = 1u << 1,
    NS2PAD_BTN_B       = 1u << 2,
    NS2PAD_BTN_A       = 1u << 3,
    NS2PAD_BTN_SR_R    = 1u << 4,  /* 右 Joy-Con 2 侧面 SR；Pro 手柄上不存在 */
    NS2PAD_BTN_SL_R    = 1u << 5,  /* 右 Joy-Con 2 侧面 SL；Pro 手柄上不存在 */
    NS2PAD_BTN_R       = 1u << 6,
    NS2PAD_BTN_ZR      = 1u << 7,
    NS2PAD_BTN_MINUS   = 1u << 8,
    NS2PAD_BTN_PLUS    = 1u << 9,
    NS2PAD_BTN_RSTICK  = 1u << 10, /* 右摇杆按下 */
    NS2PAD_BTN_LSTICK  = 1u << 11, /* 左摇杆按下 */
    NS2PAD_BTN_HOME    = 1u << 12,
    NS2PAD_BTN_CAPTURE = 1u << 13, /* 截图键 */
    NS2PAD_BTN_C       = 1u << 14, /* C 键（GameChat） */
    NS2PAD_BTN_DOWN    = 1u << 16,
    NS2PAD_BTN_UP      = 1u << 17,
    NS2PAD_BTN_RIGHT   = 1u << 18,
    NS2PAD_BTN_LEFT    = 1u << 19,
    NS2PAD_BTN_SR_L    = 1u << 20, /* 左 Joy-Con 2 侧面 SR；Pro 手柄上不存在 */
    NS2PAD_BTN_SL_L    = 1u << 21, /* 左 Joy-Con 2 侧面 SL；Pro 手柄上不存在 */
    NS2PAD_BTN_L       = 1u << 22,
    NS2PAD_BTN_ZL      = 1u << 23,
    NS2PAD_BTN_GR      = 1u << 24, /* 背键（右） */
    NS2PAD_BTN_GL      = 1u << 25, /* 背键（左） */
    NS2PAD_BTN_HEADSET = 1u << 28  /* 耳机线控键 */
};

/* 手柄型号（蓝牙广播里的 USB 产品 ID）。 */
enum {
    NS2PAD_PID_JOYCON2_L = 0x2066,
    NS2PAD_PID_JOYCON2_R = 0x2067,
    NS2PAD_PID_PRO2      = 0x2069,
    NS2PAD_PID_GC_NSO    = 0x2073
};

/* ------------------------------------------------------------------------- */
/* 数据结构                                                                   */
/* ------------------------------------------------------------------------- */

/* 每一帧的手柄状态。 */
typedef struct ns2pad_state {
    /* 按键位域，见 NS2PAD_BTN_*。 */
    uint32_t buttons;

    /* 校准后的摇杆，-1..1。x 向右为正，y 向上为正。
       有出厂校准（或用户校准）时按校准数据换算；读不到校准时按中心 2048、半程 1600 估算。 */
    float left_x, left_y;
    float right_x, right_y;

    /* 摇杆原始值，12 位（0..4095），没有校准。调试用。 */
    uint16_t raw_left_x, raw_left_y;
    uint16_t raw_right_x, raw_right_y;

    /* 下面的体感数据只有 imu_valid 为 true 时才有意义。
       刚连上、体感还没开启、或者报告里的体感时间戳为 0 时，imu_valid 为 false，数值全为 0。 */
    bool imu_valid;

    /* 加速度，单位 G，包含重力，GCMotion 坐标系（正面朝上平放时约为 (0, 0, -1)）。 */
    float accel_g[3];

    /* 角速度，GCMotion 坐标系，已减去出厂零偏。两种单位都给。 */
    float gyro_rad_s[3];
    float gyro_deg_s[3];

    /* 体感芯片温度（摄氏度）。 */
    float temperature_c;

    /* 手柄自己的体感时间戳，单位微秒，已展开成 64 位（不会每 71 分钟回绕）。
       相邻两帧的差值就是这两次采样之间真正经过的时间，积分角速度时应该用它，不要假设固定频率。 */
    uint64_t imu_timestamp_us;

    /* 这一帧体感数据的采样时刻，换算到主机时钟（纳秒）。
       由手柄时间戳加上一个持续估计的时钟偏移得到，比 received_time_ns 平滑，
       不受蓝牙批量到达、回调排队的影响。体感无效时等于 received_time_ns。 */
    uint64_t sample_time_ns;

    /* 库收到这一帧的主机时间（纳秒）。 */
    uint64_t received_time_ns;

    /* 手柄报告计数器（原始 32 位值）。实测大约每毫秒加 1。 */
    uint32_t report_counter;

    /* 和上一帧相比计数器增加了多少。蓝牙下通常是 15~25（每 15~25 ms 收到一帧）。
       某一帧突然变大，说明中间丢了帧或蓝牙卡顿。第一帧为 0。 */
    uint32_t counter_delta;

    /* 从连上到现在收到的输入帧总数。 */
    uint32_t reports_received;

    /* 电池电压（毫伏）。 */
    uint16_t battery_mv;

    /* 按电压粗略估算的电量百分比，0..100；无法估算时为 -1。只是估计值。 */
    int8_t battery_percent;

    /* 接着外部电源（USB）时为 true。按文档推断（报告偏移 0x21 非零），待真机确认。 */
    bool external_power;

    /* 报告偏移 0x21 的原始充电状态字节。文档说接上 USB 后会升到约 0x34，充满时为 0x20。 */
    uint8_t charge_state_raw;
} ns2pad_state;

/* 校准数据来源标志（ns2pad_info.calibration_flags）。 */
enum {
    NS2PAD_CAL_LEFT_STICK_FACTORY  = 1u << 0, /* 读到了左摇杆出厂校准 */
    NS2PAD_CAL_RIGHT_STICK_FACTORY = 1u << 1, /* 读到了右摇杆出厂校准 */
    NS2PAD_CAL_LEFT_STICK_USER     = 1u << 2, /* 读到了左摇杆用户校准（优先于出厂校准） */
    NS2PAD_CAL_RIGHT_STICK_USER    = 1u << 3, /* 读到了右摇杆用户校准（优先于出厂校准） */
    NS2PAD_CAL_GYRO_BIAS           = 1u << 4, /* 读到了陀螺仪出厂零偏 */
    NS2PAD_CAL_IMU_TIMING_CHECKED  = 1u << 5  /* 已用主机时钟核对过体感时间戳的单位（连上后约 2 秒） */
};

/* 手柄信息。连上时通过 connected 回调给出，之后也可用 ns2pad_get_info() 查询。 */
typedef struct ns2pad_info {
    uint16_t product_id;          /* NS2PAD_PID_* */
    char     name[32];            /* 例如 "Pro Controller 2" */
    char     serial[17];          /* 序列号（闪存 0x13002），读不到时为空字符串 */
    char     identifier[40];      /* 主机给这个蓝牙设备的标识（苹果平台是 CBPeripheral 的 UUID 字符串） */
    uint8_t  body_color[3];       /* 机身颜色 RGB（闪存 0x13019），读不到时全 0 */
    uint8_t  button_color[3];     /* 按键颜色 RGB（闪存 0x1301C） */
    uint32_t calibration_flags;   /* NS2PAD_CAL_* */
    bool     imu_enabled;         /* 握手时开启体感（功能位 2）的命令得到了确认 */
    bool     imu_timestamp_quirk; /* 时间戳不是微秒的那类手柄（SDL 观察到的现象），库已自动换算 */
    int      player_index;        /* 库给它点亮的玩家灯序号，0 起 */
} ns2pad_info;

/* 日志级别。 */
enum {
    NS2PAD_LOG_ERROR = 0,
    NS2PAD_LOG_WARN  = 1,
    NS2PAD_LOG_INFO  = 2,
    NS2PAD_LOG_DEBUG = 3
};

/* 回调。不需要的回调留 NULL。所有回调都在库内部的同一条串行队列上触发。 */
typedef struct ns2pad_callbacks {
    /* 手柄完成握手、可以使用了。info 只在回调期间有效，需要的话自己复制。 */
    void (*connected)(void *user, int pad, const ns2pad_info *info);

    /* 手柄断开。之后 pad 编号可能会给下一个连上的手柄用。 */
    void (*disconnected)(void *user, int pad);

    /* 每收到一帧输入调用一次。state 只在回调期间有效。 */
    void (*state)(void *user, int pad, const ns2pad_state *state);

    /* 日志。msg 是一行 UTF-8 文本，不带换行。为 NULL 时库不输出日志。 */
    void (*log)(void *user, int level, const char *msg);
} ns2pad_callbacks;

/* 启动选项。用 ns2pad_config_default() 取默认值后再改。 */
typedef struct ns2pad_config {
    /* 日志详细程度，NS2PAD_LOG_*。默认 NS2PAD_LOG_INFO。 */
    int log_level;

    /* 断开后自动重连同一个手柄。默认 true。 */
    bool auto_reconnect;

    /* 连上后播放一下"连接成功"的短震动（手柄内置样本 3）。默认 true。 */
    bool connect_vibration;

    /* 摇杆内圈死区，0..0.5，默认 0（不加死区，留给上层处理）。 */
    float stick_deadzone;

    /* 发命令用的通道：false 用 0x0014（纯命令，默认，和体感抓包里的做法一致）；
       true 用 0x0016（震动 + 命令合并，任天堂主机的做法）。真机测试时如果命令没反应可以切换试试。 */
    bool use_combined_command_channel;

    /* 连接手柄的型号白名单，以 0 结尾。默认只连 Pro 2（{NS2PAD_PID_PRO2, 0}）。
       Joy-Con 2 等其他型号的输入格式这一版没有适配，连上也只有按键和摇杆是对的。 */
    uint16_t accept_product_ids[8];
} ns2pad_config;

/* 一条 HD 震动"帧"的原始参数。 */
typedef struct ns2pad_rumble_frame {
    /* 两个频段，各自一个频率码和一个振幅码，都是 10 位（0..1023）。
       频率码的物理单位还不清楚（SDL 和 Linux 内核也都标注 "units unknown"），
       SDL/内核模拟普通震动用的默认值是高频 0x187、低频 0x112。
       振幅码 1023 非常强，长时间可能损伤马达；SDL 和 Linux 内核都把上限压到约 450。 */
    uint16_t high_freq, high_amp;
    uint16_t low_freq, low_amp;
} ns2pad_rumble_frame;

/* ------------------------------------------------------------------------- */
/* 函数                                                                       */
/* ------------------------------------------------------------------------- */

/* 库版本字符串。 */
const char *ns2pad_version(void);

/* 填入默认选项。 */
void ns2pad_config_default(ns2pad_config *config);

/* 启动：创建蓝牙管理器并开始扫描。callbacks 内容会被复制；user 原样传给每个回调。
   config 为 NULL 时用默认选项。
   返回 0 成功；已经启动过返回 -1；当前平台不支持返回 -2。
   第一次调用时系统会弹出蓝牙权限请求（App 和命令行工具都需要 NSBluetoothAlwaysUsageDescription）。 */
int ns2pad_start(const ns2pad_callbacks *callbacks, void *user, const ns2pad_config *config);

/* 停止：断开所有手柄、停止扫描、释放资源。返回后不会再有回调。不要在回调里调用。 */
void ns2pad_stop(void);

/* 打开或关闭扫描新手柄（已连接的不受影响）。ns2pad_start 之后默认是打开的。 */
void ns2pad_set_scanning(bool on);

/* 蓝牙当前是否可用（已开启且有权限）。 */
bool ns2pad_bluetooth_ready(void);

/* pad 当前是否已连接并完成握手。 */
bool ns2pad_is_connected(int pad);

/* 取最新一帧状态。返回 true 表示 pad 已连接且至少收到过一帧（out 已填写）。 */
bool ns2pad_get_state(int pad, ns2pad_state *out);

/* 取手柄信息。返回 true 表示 pad 已连接（out 已填写）。 */
bool ns2pad_get_info(int pad, ns2pad_info *out);

/* 简单震动：low、high 是低频、高频两个马达的强度，0..1。两侧马达同时震动。
   设一次会一直震，直到再设成 0。库会按约 100 次/秒持续发送震动帧（手柄需要连续的帧）。
   强度 1 对应振幅码约 450（和 SDL、Linux 内核一样的安全上限）。返回 false 表示 pad 未连接。 */
bool ns2pad_set_rumble(int pad, float low, float high);

/* HD 震动：左右两侧分别给原始参数。right 为 NULL 时两侧相同。
   传 NULL/NULL 或振幅全为 0 等于停止。会一直保持，直到再次设置。 */
bool ns2pad_set_rumble_hd(int pad, const ns2pad_rumble_frame *left, const ns2pad_rumble_frame *right);

/* 播放手柄内置的震动样本（命令 0x0A/0x02）。sample 取 1..7，0 为停止。
   3 是任天堂连接时的"咔哒"声。 */
bool ns2pad_play_vibration_sample(int pad, uint8_t sample);

/* 设置四个玩家指示灯，mask 的低 4 位分别对应 1~4 号灯。 */
bool ns2pad_set_player_leds(int pad, uint8_t mask);

/* 断开某个手柄。设置了 auto_reconnect 时，这个手柄之后不会自动重连，直到再次被扫描到并发起连接。 */
void ns2pad_disconnect(int pad);

/* 震动参数换算：把 0..1 的强度换成振幅码（含 450 的安全上限）。 */
uint16_t ns2pad_rumble_amp_from_unit(float unit);

#ifdef __cplusplus
}
#endif

#endif /* NS2PAD_H */
