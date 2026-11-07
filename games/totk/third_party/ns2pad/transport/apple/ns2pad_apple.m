/*
 * ns2pad_apple.m — 苹果平台（macOS、iOS 共用）的传输层：用 CoreBluetooth 直接连 Switch 2 手柄，
 * 实现 include/ns2pad.h 里的 C 接口。macOS 上还能走 USB 线（见文件后半的 "USB" 一节）：
 * 命令和响应走手柄的厂商 bulk 接口（接口 1，IOUSBHost），输入报告和震动走 HID 接口（接口 0，IOHIDManager），
 * 约 250 帧/秒。同一只手柄同时连着蓝牙和 USB 时只留 USB。
 *
 * 这一层只负责蓝牙：扫描、连接、发现服务和特征、订阅通知、把字节在手柄和协议核心（core/ns2_core.c）之间搬运、
 * 断线重连、多手柄管理。协议本身（命令格式、握手顺序、换算）全在协议核心里。
 *
 * 线程：所有 CoreBluetooth 回调、握手推进、震动发送都在一条私有串行队列 g.queue 上。
 *       对外函数可以在任意线程调用；读最新状态用 os_unfair_lock 保护。
 *
 * 需要 ARC（-fobjc-arc）。最低系统版本：macOS 12 / iOS 15。
 */
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#define NS2_HAVE_USB 1
#import <IOKit/hid/IOHIDManager.h>
#import <IOUSBHost/IOUSBHost.h>
#endif
#include <os/lock.h>
#include <stdarg.h>
#include <time.h>

#include "ns2_core.h"
#include "ns2pad.h"

#if !__has_feature(objc_arc)
#error "ns2pad_apple.m must be compiled with -fobjc-arc"
#endif

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/* ------------------------------------------------------------------------- */
/* 一个手柄                                                                   */
/* ------------------------------------------------------------------------- */

typedef enum { PAD_CONNECTING, PAD_DISCOVERING, PAD_HANDSHAKE, PAD_SUBSCRIBING, PAD_READY } PadPhase;

@interface NS2Pad : NSObject
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic) int slot;
@property(nonatomic) PadPhase phase;
@property(nonatomic) uint16_t productId;
@property(nonatomic, strong) CBCharacteristic *input;      /* 0x000A 输入报告 0x05 */
@property(nonatomic, strong) CBCharacteristic *proInput;   /* 0x000E 输入报告 0x09（只用它下面的速率描述符） */
@property(nonatomic, strong) CBCharacteristic *command;    /* 0x0014 */
@property(nonatomic, strong) CBCharacteristic *combined;   /* 0x0016 */
@property(nonatomic, strong) CBCharacteristic *rumbleOut;  /* 0x0012 */
@property(nonatomic, strong) CBCharacteristic *respExt;    /* 0x001E */
@property(nonatomic, strong) CBCharacteristic *respBasic;  /* 0x001A */
@property(nonatomic, strong) CBDescriptor *rateDesc;       /* 0x0010 "Set Report Rate?" */
@property(nonatomic) BOOL descriptorsDone;
@property(nonatomic) uint64_t subscribeStart; /* 开始订阅输入的时间，用来在日志里报告等了多久 */
@property(nonatomic) BOOL connectedReported;
@property(nonatomic) BOOL userDisconnect;
@property(nonatomic) uint64_t phaseSince;
@property(nonatomic) BOOL usb;                 /* 走 USB 线（只有 macOS），peripheral 为 nil */
@property(nonatomic, copy) NSString *usbIdent; /* "usb-<locationID>" */
@end

@implementation NS2Pad {
@public
    ns2_session session;
    /* 下面这些由 g.lock 保护 */
    ns2pad_state latest;
    bool haveState;
    ns2pad_info info;
    ns2pad_rumble_frame rumble[2];
    bool rumbleActive;
    int rumbleTail; /* 振幅归零后再发几帧静音帧 */
#if NS2_HAVE_USB
    /* USB，只在 g.queue 上用 */
    IOUSBHostInterface *usbIntf; /* 接口 1：命令 / 响应 */
    IOUSBHostPipe *usbOut, *usbIn;
    IOHIDDeviceRef hid;          /* 接口 0：输入报告、震动（持有一次引用） */
    uint64_t usbEntryId;         /* IOUSBHostDevice 的注册表 ID */
    uint32_t usbLocation;
    uint8_t rx[256];             /* 一条响应可能分成几个 64 字节包，攒到短包为止 */
    size_t rxLen;
    uint64_t rxAt;
    bool usbClosed;
#endif
}
@end

/* ------------------------------------------------------------------------- */
/* 全局状态                                                                   */
/* ------------------------------------------------------------------------- */

@interface NS2Central : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

static struct {
    bool started;
    dispatch_queue_t queue;
    CBCentralManager *central;
    NS2Central *delegate;
    ns2pad_callbacks cb;
    void *user;
    ns2pad_config config;
    os_unfair_lock lock;
    NS2Pad *pads[NS2PAD_MAX_PADS];          /* 按 slot 存，g.queue 上读写；对外查询时加锁读 */
    NSMutableArray<NS2Pad *> *pending;      /* 正在连接、还没分到 slot 的 */
    NSMutableDictionary<NSUUID *, NSNumber *> *lastSlot; /* 手柄上次用的 slot，重连时尽量沿用 */
    dispatch_source_t timer;
    bool wantScan;
    bool btReady;
    NSMutableSet<NSUUID *> *usbTwins;       /* 和某个 USB 手柄是同一只的蓝牙外设：USB 连着时不再连它 */
#if NS2_HAVE_USB
    IONotificationPortRef usbPort;
    io_iterator_t usbAdded, usbGone;
    IOHIDManagerRef hidManager;
#endif
} g = {.lock = OS_UNFAIR_LOCK_INIT};

static void *const kQueueKey = (void *)&kQueueKey;

static void ns2log(int level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void ns2log(int level, const char *fmt, ...) {
    if (!g.cb.log || level > g.config.log_level) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    g.cb.log(g.user, level, buf);
}

static CBUUID *uuid(const char *s) { return [CBUUID UUIDWithString:[NSString stringWithUTF8String:s]]; }

static void runOnQueueSync(dispatch_block_t b) {
    if (dispatch_get_specific(kQueueKey)) b();
    else dispatch_sync(g.queue, b);
}

/* ------------------------------------------------------------------------- */
/* 小工具                                                                     */
/* ------------------------------------------------------------------------- */

static NS2Pad *padForPeripheral(CBPeripheral *p) {
    for (int i = 0; i < NS2PAD_MAX_PADS; i++)
        if (g.pads[i] && g.pads[i].peripheral == p) return g.pads[i];
    for (NS2Pad *pad in g.pending)
        if (pad.peripheral == p) return pad;
    return nil;
}

static int freeSlotFor(NSUUID *ident) {
    NSNumber *last = g.lastSlot[ident];
    if (last && last.intValue >= 0 && last.intValue < NS2PAD_MAX_PADS && !g.pads[last.intValue]) return last.intValue;
    for (int i = 0; i < NS2PAD_MAX_PADS; i++) {
        if (g.pads[i]) continue;
        bool reserved = false;
        for (NSUUID *k in g.lastSlot)
            if (g.lastSlot[k].intValue == i && ![k isEqual:ident]) reserved = true;
        if (!reserved) return i;
    }
    for (int i = 0; i < NS2PAD_MAX_PADS; i++)
        if (!g.pads[i]) return i;
    return -1;
}

static int connectedCount(void) {
    int n = (int)g.pending.count;
    for (int i = 0; i < NS2PAD_MAX_PADS; i++)
        if (g.pads[i]) n++;
    return n;
}

static bool productAccepted(uint16_t pid) {
    for (int i = 0; i < 8 && g.config.accept_product_ids[i]; i++)
        if (g.config.accept_product_ids[i] == pid) return true;
    return false;
}

static void updateScan(void) {
    if (!g.btReady) return;
    bool want = g.wantScan && connectedCount() < NS2PAD_MAX_PADS;
    if (want && !g.central.isScanning) {
        /* Switch 2 手柄的广播里没有服务 UUID，只能不带过滤地扫，再看厂商数据 */
        [g.central scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @NO}];
        ns2log(NS2PAD_LOG_INFO, "scanning (hold the small pairing button on the controller until the lights sweep)");
    } else if (!want && g.central.isScanning) {
        [g.central stopScan];
    }
}

static void setPhase(NS2Pad *pad, PadPhase phase) {
    pad.phase = phase;
    pad.phaseSince = now_ns();
}

static void usbWriteForward(NS2Pad *pad, const ns2_tx *tx);

static void writeTx(NS2Pad *pad, const ns2_tx *tx) {
    if (pad.usb) {
        usbWriteForward(pad, tx);
        return;
    }
    CBCharacteristic *c;
    if (tx->channel == 1) c = pad.rumbleOut;
    else c = g.config.use_combined_command_channel ? pad.combined : pad.command;
    if (!c) {
        ns2log(NS2PAD_LOG_WARN, "pad %d: characteristic for channel %d missing, write dropped", pad.slot, tx->channel);
        return;
    }
    NSUInteger maxLen = [pad.peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
    if (tx->len > maxLen) {
        ns2log(NS2PAD_LOG_WARN, "pad %d: write of %zu bytes exceeds the link's maximum %lu", pad.slot, tx->len,
               (unsigned long)maxLen);
    }
    if (g.config.log_level >= NS2PAD_LOG_DEBUG && tx->channel == 0) {
        char hex[200];
        size_t n = tx->len < 64 ? tx->len : 64;
        for (size_t i = 0; i < n; i++) snprintf(hex + 3 * i, 4, "%02x ", tx->bytes[i]);
        ns2log(NS2PAD_LOG_DEBUG, "pad %d -> %s", pad.slot, hex);
    }
    [pad.peripheral writeValue:[NSData dataWithBytes:tx->bytes length:tx->len]
             forCharacteristic:c
                          type:CBCharacteristicWriteWithoutResponse];
}

static void fillInfo(NS2Pad *pad) {
    ns2pad_info info = pad->session.info;
    snprintf(info.identifier, sizeof info.identifier, "%s",
             pad.usb ? pad.usbIdent.UTF8String : pad.peripheral.identifier.UUIDString.UTF8String);
    info.player_index = pad.slot;
    os_unfair_lock_lock(&g.lock);
    pad->info = info;
    os_unfair_lock_unlock(&g.lock);
}

static void startTimerIfNeeded(void);
#if NS2_HAVE_USB
static void usbWrite(NS2Pad *pad, const ns2_tx *tx);
static void usbClose(NS2Pad *pad);
#endif

/* 握手结束（成功或部分失败）：打开输入报告通知（报告速率描述符等订阅成功后再写）。 */
static void finishHandshake(NS2Pad *pad, bool ok) {
    setPhase(pad, PAD_SUBSCRIBING);
    pad.subscribeStart = now_ns();
    ns2log(ok ? NS2PAD_LOG_INFO : NS2PAD_LOG_WARN, "pad %d: handshake %s (imu %s)%s", pad.slot,
           ok ? "done" : "finished with timeouts", pad->session.imu_enabled ? "on" : "not confirmed",
           pad.usb ? " over USB" : "");
    if (pad.usb) return; /* USB：握手最后一步已经让手柄开始发输入，第一帧到了就就绪 */
    /* 真机（macOS）上先写报告速率描述符会把订阅卡住约 3 秒，所以先订阅输入，订阅成功后再写描述符 */
    [pad.peripheral setNotifyValue:YES forCharacteristic:pad.input];
}

/* 输入报告订阅成功：进入就绪状态，通知使用者，再写报告速率描述符。
   真机上订阅确认（didUpdateNotificationState）有时迟迟不来，但数据已经在来，所以收到第一帧输入时也会调用这里。 */
static void removePad(NS2Pad *pad);

/* 同一只手柄（序列号相同）同时连着蓝牙和 USB：留 USB，断开蓝牙，USB 手柄接过蓝牙那个的编号。
   返回 false 表示 pad 自己就是要断开的蓝牙那个。 */
static bool resolveTwin(NS2Pad *pad) {
    const char *serial = pad->session.info.serial;
    if (!serial[0]) return true;
    for (int i = 0; i < NS2PAD_MAX_PADS; i++) {
        NS2Pad *o = g.pads[i];
        if (!o || o == pad || o.usb == pad.usb || strcmp(o->session.info.serial, serial)) continue;
        NS2Pad *ble = pad.usb ? o : pad;
        NS2Pad *usb = pad.usb ? pad : o;
        if (!pad.usb && usb.phase != PAD_READY && usb.phase != PAD_SUBSCRIBING && usb.phase != PAD_HANDSHAKE) continue;
        ns2log(NS2PAD_LOG_INFO, "pad %d: same controller as the USB one, leaving Bluetooth for the cable", ble.slot);
        [g.usbTwins addObject:ble.peripheral.identifier];
        ble.userDisconnect = YES;
        int bleSlot = ble.slot;
        [g.central cancelPeripheralConnection:ble.peripheral];
        removePad(ble);
        if (!pad.usb) return false;
        if (bleSlot >= 0 && bleSlot != pad.slot && !g.pads[bleSlot]) { /* 沿用蓝牙那个的编号 */
            os_unfair_lock_lock(&g.lock);
            g.pads[pad.slot] = nil;
            g.pads[bleSlot] = pad;
            os_unfair_lock_unlock(&g.lock);
            pad.slot = bleSlot;
        }
        return true;
    }
    return true;
}

static void padBecameReady(NS2Pad *pad) {
    if (!resolveTwin(pad)) return;
    setPhase(pad, PAD_READY);
    fillInfo(pad);
    pad.connectedReported = YES;
    ns2pad_info info;
    os_unfair_lock_lock(&g.lock);
    info = pad->info;
    os_unfair_lock_unlock(&g.lock);
    ns2log(NS2PAD_LOG_INFO, "pad %d: ready — %s, serial %s, calibration flags 0x%02x (input after %.0f ms)", pad.slot,
           info.name, info.serial[0] ? info.serial : "?", info.calibration_flags,
           (double)(now_ns() - pad.subscribeStart) / 1e6);
    if (g.cb.connected) g.cb.connected(g.user, pad.slot, &info);
    if (!pad.usb && pad.rateDesc) {
        const uint8_t v[2] = {NS2_REPORT_RATE_VALUE_0, NS2_REPORT_RATE_VALUE_1};
        [pad.peripheral writeValue:[NSData dataWithBytes:v length:2] forDescriptor:pad.rateDesc];
    }
}

static void tick(void) {
    uint64_t now = now_ns();
    bool any = false;
    for (int i = 0; i < NS2PAD_MAX_PADS; i++) {
        NS2Pad *pad = g.pads[i];
        if (!pad) continue;
        any = true;
        if (pad.phase == PAD_HANDSHAKE || pad.phase == PAD_READY) {
            /* 握手推进 / 排队命令：一次 tick 最多发一条，留出时间给响应 */
            ns2_tx tx;
            ns2_poll_result r = ns2_session_poll(&pad->session, now, &tx);
            if (r == NS2_POLL_SEND) writeTx(pad, &tx);
            else if (r == NS2_POLL_READY || r == NS2_POLL_FAILED) finishHandshake(pad, r == NS2_POLL_READY);
        }
        if (pad.phase == PAD_DISCOVERING && now > pad.phaseSince && now - pad.phaseSince > 10000ull * 1000 * 1000) {
            /* 服务发现 10 秒没结果：断开，交给自动重连再试一次 */
            ns2log(NS2PAD_LOG_WARN, "pad %d: service discovery timed out, reconnecting", pad.slot);
            setPhase(pad, PAD_CONNECTING);
            [g.central cancelPeripheralConnection:pad.peripheral];
            continue;
        }
        /* 真机上握手刚结束时的第一次订阅经常没反应，再订阅一次就好，所以每 0.1 秒重试一次 */
#if NS2_HAVE_USB
        if (pad.usb && pad->rxLen && now - pad->rxAt > 20ull * 1000 * 1000) { /* 最后一包正好 64 字节：等不到短包 */
            ns2_session_on_response(&pad->session, pad->rx, pad->rxLen, 0, now);
            pad->rxLen = 0;
        }
#endif
        if (!pad.usb && pad.phase == PAD_SUBSCRIBING && now > pad.phaseSince &&
            now - pad.phaseSince > 100ull * 1000 * 1000) {
            ns2log(NS2PAD_LOG_DEBUG, "pad %d: input subscription not confirmed after 0.1 s, retrying", pad.slot);
            setPhase(pad, PAD_SUBSCRIBING);
            [pad.peripheral setNotifyValue:YES forCharacteristic:pad.input];
        }
        if (pad.phase == PAD_READY && (pad.rumbleOut || pad.usb)) {
            os_unfair_lock_lock(&g.lock);
            bool send = pad->rumbleActive || pad->rumbleTail > 0;
            ns2pad_rumble_frame l = pad->rumble[0], r = pad->rumble[1];
            if (!pad->rumbleActive && pad->rumbleTail > 0) {
                l.high_amp = l.low_amp = r.high_amp = r.low_amp = 0;
            }
            os_unfair_lock_unlock(&g.lock);
            if (send && (pad.usb || pad.peripheral.canSendWriteWithoutResponse)) {
                ns2_tx tx;
                ns2_session_rumble_report(&pad->session, &l, &r, &tx);
                writeTx(pad, &tx);
                os_unfair_lock_lock(&g.lock);
                if (!pad->rumbleActive && pad->rumbleTail > 0) pad->rumbleTail--;
                os_unfair_lock_unlock(&g.lock);
            }
        }
    }
    if (!any && g.pending.count == 0 && g.timer) {
        dispatch_source_cancel(g.timer);
        g.timer = nil;
    }
}

static void startTimerIfNeeded(void) {
    if (g.timer) return;
    g.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g.queue);
    dispatch_source_set_timer(g.timer, dispatch_time(DISPATCH_TIME_NOW, 0), 10ull * NSEC_PER_MSEC, 2ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g.timer, ^{ tick(); });
    dispatch_resume(g.timer);
}

static void removePad(NS2Pad *pad) {
#if NS2_HAVE_USB
    if (pad.usb) usbClose(pad);
#endif
    int slot = pad.slot;
    bool reported = pad.connectedReported;
    os_unfair_lock_lock(&g.lock);
    if (slot >= 0 && slot < NS2PAD_MAX_PADS && g.pads[slot] == pad) g.pads[slot] = nil;
    os_unfair_lock_unlock(&g.lock);
    [g.pending removeObject:pad];
    if (reported && g.cb.disconnected) g.cb.disconnected(g.user, slot);
}

/* 一帧输入报告 0x05（蓝牙下不带报告 ID，USB 下调用方已去掉报告 ID）。g.queue 上。 */
static void handleInput(NS2Pad *pad, const uint8_t *bytes, size_t len, uint64_t now) {
    ns2pad_state st;
    if (!ns2_session_on_input(&pad->session, bytes, len, now, &st)) return;
    if (pad.phase == PAD_SUBSCRIBING) padBecameReady(pad);
    if (pad.phase != PAD_READY) return;
    bool firstTimingCheck = (pad->session.info.calibration_flags & NS2PAD_CAL_IMU_TIMING_CHECKED) &&
                            !(pad->info.calibration_flags & NS2PAD_CAL_IMU_TIMING_CHECKED);
    os_unfair_lock_lock(&g.lock);
    pad->latest = st;
    pad->haveState = true;
    if (firstTimingCheck) {
        pad->info.calibration_flags = pad->session.info.calibration_flags;
        pad->info.imu_timestamp_quirk = pad->session.info.imu_timestamp_quirk;
    }
    os_unfair_lock_unlock(&g.lock);
    if (firstTimingCheck) {
        ns2log(NS2PAD_LOG_INFO, "pad %d: imu clock checked (scale %.4f%s)", pad.slot, pad->session.ts_scale,
               pad->session.info.imu_timestamp_quirk ? ", non-microsecond timestamps: alternate gyro range" : "");
    }
    if (g.cb.state) g.cb.state(g.user, pad.slot, &st);
}

/* ------------------------------------------------------------------------- */
/* CoreBluetooth 代理                                                          */
/* ------------------------------------------------------------------------- */

@implementation NS2Central

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
    case CBManagerStatePoweredOn:
        g.btReady = true;
        ns2log(NS2PAD_LOG_INFO, "bluetooth on");
        updateScan();
        break;
    case CBManagerStateUnauthorized:
        g.btReady = false;
        ns2log(NS2PAD_LOG_ERROR, "bluetooth permission denied: allow it in System Settings > Privacy & Security > Bluetooth");
        break;
    case CBManagerStatePoweredOff:
        g.btReady = false;
        ns2log(NS2PAD_LOG_WARN, "bluetooth is off");
        break;
    case CBManagerStateUnsupported:
        g.btReady = false;
        ns2log(NS2PAD_LOG_ERROR, "this device has no Bluetooth LE");
        break;
    default:
        g.btReady = false;
        break;
    }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)adv
                     RSSI:(NSNumber *)RSSI {
    NSData *mfg = adv[CBAdvertisementDataManufacturerDataKey];
    if (!mfg) return;
    uint16_t pid = ns2_adv_product_id(mfg.bytes, mfg.length);
    if (!pid) return;
    if (padForPeripheral(peripheral)) return;
    if ([g.usbTwins containsObject:peripheral.identifier]) return; /* 它正连着 USB 线 */
    if (!productAccepted(pid)) {
        ns2log(NS2PAD_LOG_INFO, "ignoring %s (product %04x is not enabled in the config)", ns2_product_name(pid), pid);
        return;
    }
    if (connectedCount() >= NS2PAD_MAX_PADS) return;

    NS2Pad *pad = [NS2Pad new];
    pad.peripheral = peripheral;
    pad.slot = -1;
    pad.productId = pid;
    setPhase(pad, PAD_CONNECTING);
    peripheral.delegate = g.delegate;
    [g.pending addObject:pad];
    ns2log(NS2PAD_LOG_INFO, "found %s (RSSI %d), connecting", ns2_product_name(pid), RSSI.intValue);
    [central connectPeripheral:peripheral options:nil];
    startTimerIfNeeded();
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    NS2Pad *pad = padForPeripheral(peripheral);
    if (!pad) {
        [central cancelPeripheralConnection:peripheral];
        return;
    }
    if (pad.slot < 0) {
        int slot = freeSlotFor(peripheral.identifier);
        if (slot < 0) {
            [central cancelPeripheralConnection:peripheral];
            return;
        }
        pad.slot = slot;
        g.lastSlot[peripheral.identifier] = @(slot);
        [g.pending removeObject:pad];
        os_unfair_lock_lock(&g.lock);
        g.pads[slot] = pad;
        os_unfair_lock_unlock(&g.lock);
    }
    setPhase(pad, PAD_DISCOVERING);
    ns2log(NS2PAD_LOG_INFO, "pad %d: connected, discovering services", pad.slot);
    [peripheral discoverServices:@[ uuid(NS2_UUID_SERVICE) ]];
    updateScan();
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    ns2log(NS2PAD_LOG_WARN, "connect failed: %s", error.localizedDescription.UTF8String ?: "unknown");
    if (pad) removePad(pad);
    updateScan();
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    int slot = pad ? pad.slot : -1;
    ns2log(NS2PAD_LOG_INFO, "pad %d: disconnected%s%s", slot, error ? ": " : "",
           error ? error.localizedDescription.UTF8String : "");
    bool reconnect = pad && !pad.userDisconnect && g.config.auto_reconnect;
    if (pad) removePad(pad);
    if (reconnect) {
        /* 挂一个"等它再出现就连"的连接请求。苹果的这种请求不会超时：手柄一按键（发重连广播）就会连上 */
        NS2Pad *again = [NS2Pad new];
        again.peripheral = peripheral;
        again.slot = -1;
        again.productId = pad.productId;
        setPhase(again, PAD_CONNECTING);
        peripheral.delegate = g.delegate;
        [g.pending addObject:again];
        [central connectPeripheral:peripheral options:nil];
        ns2log(NS2PAD_LOG_INFO, "waiting for the controller to come back (press any button)");
    }
    updateScan();
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    if (!pad) return;
    CBService *svc = nil;
    for (CBService *s in peripheral.services)
        if ([s.UUID isEqual:uuid(NS2_UUID_SERVICE)]) svc = s;
    if (!svc) {
        ns2log(NS2PAD_LOG_ERROR, "pad %d: Nintendo service not found (%s)", pad.slot,
               error.localizedDescription.UTF8String ?: "no error");
        [g.central cancelPeripheralConnection:peripheral];
        return;
    }
    [peripheral discoverCharacteristics:nil forService:svc];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    if (!pad) return;
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID isEqual:uuid(NS2_UUID_INPUT_COMMON)]) pad.input = c;
        else if ([c.UUID isEqual:uuid(NS2_UUID_INPUT_PRO)]) pad.proInput = c;
        else if ([c.UUID isEqual:uuid(NS2_UUID_COMMAND)]) pad.command = c;
        else if ([c.UUID isEqual:uuid(NS2_UUID_COMBINED_PRO)]) pad.combined = c;
        else if ([c.UUID isEqual:uuid(NS2_UUID_OUTPUT_PRO)]) pad.rumbleOut = c;
        else if ([c.UUID isEqual:uuid(NS2_UUID_RESPONSE_PRO)]) pad.respExt = c;
        else if ([c.UUID isEqual:uuid(NS2_UUID_RESPONSE_BASIC)]) pad.respBasic = c;
    }
    ns2log(NS2PAD_LOG_DEBUG, "pad %d: %lu characteristics (input %s, command %s, responses %s/%s, rumble %s)", pad.slot,
           (unsigned long)service.characteristics.count, pad.input ? "yes" : "NO", pad.command ? "yes" : "NO",
           pad.respExt ? "yes" : "NO", pad.respBasic ? "yes" : "NO", pad.rumbleOut ? "yes" : "NO");
    if (!pad.input || !(pad.command || pad.combined) || !(pad.respExt || pad.respBasic)) {
        ns2log(NS2PAD_LOG_ERROR, "pad %d: required characteristics missing (%s)", pad.slot,
               error.localizedDescription.UTF8String ?: "no error");
        [g.central cancelPeripheralConnection:peripheral];
        return;
    }
    /* 报告速率描述符在 0x09 输入特征下（抓包写的是句柄 0x0010） */
    if (pad.proInput) [peripheral discoverDescriptorsForCharacteristic:pad.proInput];
    else pad.descriptorsDone = YES;
    /* 先打开命令响应通知，确认后开始握手 */
    if (pad.respExt) [peripheral setNotifyValue:YES forCharacteristic:pad.respExt];
    if (pad.respBasic) [peripheral setNotifyValue:YES forCharacteristic:pad.respBasic];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic
                                      error:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    if (!pad) return;
    for (CBDescriptor *d in characteristic.descriptors)
        if ([d.UUID isEqual:uuid(NS2_UUID_REPORT_RATE_DESC)]) pad.rateDesc = d;
    pad.descriptorsDone = YES;
    if (!pad.rateDesc) ns2log(NS2PAD_LOG_DEBUG, "pad %d: report rate descriptor not found", pad.slot);
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)c
                                          error:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    if (!pad) return;
    if (error) {
        ns2log(NS2PAD_LOG_WARN, "pad %d: enabling notifications on %s failed: %s", pad.slot,
               c.UUID.UUIDString.UTF8String, error.localizedDescription.UTF8String);
    }
    bool isResponse = (c == pad.respExt) || (c == pad.respBasic && !pad.respExt);
    if (isResponse && pad.phase == PAD_DISCOVERING && c.isNotifying) {
        ns2_session_options o;
        ns2_session_options_default(&o);
        o.player_leds = (uint8_t)(pad.slot < 4 ? (1u << pad.slot) : 0x09);
        o.connect_vibration = g.config.connect_vibration;
        o.use_combined_channel = g.config.use_combined_command_channel;
        o.stick_deadzone = g.config.stick_deadzone;
        ns2_session_init(&pad->session, &o);
        pad->session.info.product_id = pad.productId;
        snprintf(pad->session.info.name, sizeof pad->session.info.name, "%s", ns2_product_name(pad.productId));
        setPhase(pad, PAD_HANDSHAKE);
        ns2log(NS2PAD_LOG_INFO, "pad %d: handshake started", pad.slot);
        startTimerIfNeeded();
    }
    if (c == pad.input && c.isNotifying && pad.phase == PAD_SUBSCRIBING) padBecameReady(pad);
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    if (!pad || descriptor != pad.rateDesc) return;
    if (error) ns2log(NS2PAD_LOG_WARN, "pad %d: report rate descriptor write failed: %s", pad.slot, error.localizedDescription.UTF8String);
    else ns2log(NS2PAD_LOG_DEBUG, "pad %d: report rate descriptor written", pad.slot);
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
    NS2Pad *pad = padForPeripheral(peripheral);
    NSData *v = c.value;
    if (!pad || !v || error) return;
    uint64_t now = now_ns();
    if (c == pad.input) {
        handleInput(pad, v.bytes, v.length, now);
    } else if (c == pad.respExt || c == pad.respBasic) {
        size_t prefix = (c == pad.respExt) ? NS2_RESPONSE_PREFIX_EXT : 0;
        if (g.config.log_level >= NS2PAD_LOG_DEBUG) {
            char hex[200];
            const uint8_t *b = v.bytes;
            size_t n = v.length > prefix ? v.length - prefix : 0;
            if (n > 40) n = 40;
            for (size_t i = 0; i < n; i++) snprintf(hex + 3 * i, 4, "%02x ", b[prefix + i]);
            hex[3 * n] = 0;
            ns2log(NS2PAD_LOG_DEBUG, "pad %d <- %s", pad.slot, hex);
        }
        ns2_session_on_response(&pad->session, v.bytes, v.length, prefix, now);
    }
}

@end

/* ------------------------------------------------------------------------- */
/* USB（只有 macOS）                                                           */
/* ------------------------------------------------------------------------- */
/*
 * 插上线后手柄是一个复合 USB 设备：接口 0 是 HID（系统自带驱动接管，用 IOHIDManager 读），接口 1 是厂商 bulk 接口
 * （没有驱动，用 IOUSBHost 直接打开），接口 2 是音频。手柄不经初始化就不发输入：命令（和蓝牙同一套，传输字节 0x00）
 * 写到接口 1 的 bulk OUT，响应从 bulk IN 读；握手最后的 0x03/0x0D 之后，HID 接口开始发 64 字节的输入报告
 * （报告 ID 0x05 + 蓝牙那 63 字节），实测 250 帧/秒。震动是 HID 输出报告 0x02（和蓝牙同样的块，第 0 字节是报告 ID）。
 * 顺序和数据参考 SDL 的 USB 驱动（src/joystick/hidapi/SDL_hidapi_switch2.c，zlib），见 docs/protocol.md。
 */
#if NS2_HAVE_USB

static void usbReadNext(NS2Pad *pad);

static NS2Pad *usbPadForEntry(uint64_t entry) {
    for (int i = 0; i < NS2PAD_MAX_PADS; i++)
        if (g.pads[i] && g.pads[i].usb && g.pads[i]->usbEntryId == entry) return g.pads[i];
    return nil;
}

static void usbWrite(NS2Pad *pad, const ns2_tx *tx) {
    if (pad->usbClosed) return;
    if (tx->channel == 1) { /* 震动：HID 输出报告 0x02，64 字节 */
        if (!pad->hid) return;
        uint8_t buf[64] = {0};
        memcpy(buf, tx->bytes, tx->len < sizeof buf ? tx->len : sizeof buf);
        buf[0] = 0x02;
        IOReturn r = IOHIDDeviceSetReport(pad->hid, kIOHIDReportTypeOutput, 0x02, buf, sizeof buf);
        if (r != kIOReturnSuccess) ns2log(NS2PAD_LOG_DEBUG, "pad %d: USB rumble report failed 0x%x", pad.slot, r);
        return;
    }
    if (g.config.log_level >= NS2PAD_LOG_DEBUG) {
        char hex[200];
        size_t n = tx->len < 64 ? tx->len : 64;
        for (size_t i = 0; i < n; i++) snprintf(hex + 3 * i, 4, "%02x ", tx->bytes[i]);
        ns2log(NS2PAD_LOG_DEBUG, "pad %d -> %s", pad.slot, hex);
    }
    NSMutableData *d = [NSMutableData dataWithBytes:tx->bytes length:tx->len];
    NSError *e = nil;
    int slot = pad.slot;
    if (![pad->usbOut enqueueIORequestWithData:d completionTimeout:1.0 error:&e
                             completionHandler:^(IOReturn status, NSUInteger done) {
                                 (void)done;
                                 if (status != kIOReturnSuccess && status != kIOReturnAborted)
                                     ns2log(NS2PAD_LOG_WARN, "pad %d: USB command write failed 0x%x", slot, status);
                             }])
        ns2log(NS2PAD_LOG_WARN, "pad %d: USB command write not queued: %s", slot, e.localizedDescription.UTF8String);
}

static void usbWriteForward(NS2Pad *pad, const ns2_tx *tx) { usbWrite(pad, tx); }

static void usbGotResponse(NS2Pad *pad, uint64_t now) {
    if (g.config.log_level >= NS2PAD_LOG_DEBUG) {
        char hex[200];
        size_t n = pad->rxLen < 40 ? pad->rxLen : 40;
        for (size_t i = 0; i < n; i++) snprintf(hex + 3 * i, 4, "%02x ", pad->rx[i]);
        hex[3 * n] = 0;
        ns2log(NS2PAD_LOG_DEBUG, "pad %d <- %s(%zu bytes)", pad.slot, hex, pad->rxLen);
    }
    ns2_session_on_response(&pad->session, pad->rx, pad->rxLen, 0, now);
    pad->rxLen = 0;
}

/* bulk IN 一直挂着一个读请求。不满 64 字节的包是一条响应的最后一包。 */
static void usbReadNext(NS2Pad *pad) {
    if (pad->usbClosed) return;
    NSMutableData *d = [NSMutableData dataWithLength:64];
    NSError *e = nil;
    BOOL ok = [pad->usbIn enqueueIORequestWithData:d completionTimeout:0 error:&e
                                 completionHandler:^(IOReturn status, NSUInteger done) {
                                     if (pad->usbClosed) return;
                                     if (status == kIOReturnSuccess) {
                                         uint64_t now = now_ns();
                                         if (pad->rxLen + done <= sizeof pad->rx) {
                                             memcpy(pad->rx + pad->rxLen, d.bytes, done);
                                             pad->rxLen += done;
                                         }
                                         pad->rxAt = now;
                                         if (done < 64 || pad->rxLen + 64 > sizeof pad->rx) usbGotResponse(pad, now);
                                         usbReadNext(pad);
                                     } else if (status != kIOReturnAborted && status != kIOReturnNotResponding &&
                                                status != kIOReturnNoDevice) {
                                         ns2log(NS2PAD_LOG_DEBUG, "pad %d: USB read 0x%x, retrying", pad.slot, status);
                                         [pad->usbIn clearStallWithError:nil];
                                         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), g.queue,
                                                        ^{ usbReadNext(pad); });
                                     }
                                 }];
    if (!ok) ns2log(NS2PAD_LOG_WARN, "pad %d: USB read not queued: %s", pad.slot, e.localizedDescription.UTF8String);
}

/* 管理器的输入报告回调（g.queue）。设备激活后不能再单独给它注册回调，所以统一在管理器上注册，按 sender 找手柄。 */
static void usbHidReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID,
                         uint8_t *report, CFIndex len) {
    (void)ctx; (void)result; (void)type;
    if (reportID != 0x05 || len < 1 + 0x3C || report[0] != 0x05) return;
    for (int i = 0; i < NS2PAD_MAX_PADS; i++) {
        NS2Pad *pad = g.pads[i];
        if (pad && pad.usb && !pad->usbClosed && pad->hid == sender) {
            handleInput(pad, report + 1, (size_t)len - 1, now_ns());
            return;
        }
    }
}

static uint32_t hidLocation(IOHIDDeviceRef dev) {
    CFTypeRef v = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDLocationIDKey));
    return v && CFGetTypeID(v) == CFNumberGetTypeID() ? (uint32_t)[(__bridge NSNumber *)v unsignedIntValue] : 0;
}

static void usbAttachHid(NS2Pad *pad, IOHIDDeviceRef dev) {
    if (pad->hid || pad->usbClosed) return;
    pad->hid = (IOHIDDeviceRef)CFRetain(dev);
    ns2log(NS2PAD_LOG_DEBUG, "pad %d: USB HID interface attached", pad.slot);
}

static void hidMatched(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)result; (void)sender;
    uint32_t loc = hidLocation(dev);
    for (int i = 0; i < NS2PAD_MAX_PADS; i++) {
        NS2Pad *pad = g.pads[i];
        if (pad && pad.usb && !pad->hid && pad->usbLocation == loc) usbAttachHid(pad, dev);
    }
}

static void usbClose(NS2Pad *pad) {
    if (pad->usbClosed) return;
    pad->usbClosed = true;
    if (pad->hid) {
        CFRelease(pad->hid);
        pad->hid = NULL;
    }
    [pad->usbIntf destroy];
    pad->usbIntf = nil;
    pad->usbOut = pad->usbIn = nil;
}

static io_service_t usbFindInterface(io_service_t dev, int number) {
    io_iterator_t it;
    if (IORegistryEntryGetChildIterator(dev, kIOServicePlane, &it) != KERN_SUCCESS) return 0;
    io_service_t s, found = 0;
    while ((s = IOIteratorNext(it))) {
        CFTypeRef num = IORegistryEntryCreateCFProperty(s, CFSTR("bInterfaceNumber"), NULL, 0);
        if (!found && IOObjectConformsTo(s, "IOUSBHostInterface") && num && CFGetTypeID(num) == CFNumberGetTypeID() &&
            [(__bridge NSNumber *)num intValue] == number)
            found = s;
        else
            IOObjectRelease(s);
        if (num) CFRelease(num);
    }
    IOObjectRelease(it);
    return found;
}

static uint32_t registryUInt(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, NULL, 0);
    uint32_t r = v && CFGetTypeID(v) == CFNumberGetTypeID() ? [(__bridge NSNumber *)v unsignedIntValue] : 0;
    if (v) CFRelease(v);
    return r;
}

static void usbOpenDevice(io_service_t dev, int attempt);

static void usbRetryLater(io_service_t dev, int attempt) {
    IOObjectRetain(dev);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), g.queue, ^{
        if (g.usbPort) usbOpenDevice(dev, attempt + 1);
        IOObjectRelease(dev);
    });
}

static void usbOpenDevice(io_service_t dev, int attempt) {
    uint64_t entry = 0;
    IORegistryEntryGetRegistryEntryID(dev, &entry);
    if (usbPadForEntry(entry)) return;
    uint16_t pid = (uint16_t)registryUInt(dev, CFSTR("idProduct"));
    if (!productAccepted(pid)) {
        if (attempt == 0) ns2log(NS2PAD_LOG_INFO, "USB: ignoring %s (product %04x is not enabled in the config)",
                                 ns2_product_name(pid), pid);
        return;
    }
    io_service_t ifc = usbFindInterface(dev, 1);
    if (!ifc) { /* 刚插上时接口可能还没注册好 */
        if (attempt < 10) usbRetryLater(dev, attempt);
        else ns2log(NS2PAD_LOG_WARN, "USB: %s has no command interface", ns2_product_name(pid));
        return;
    }
    NSError *e = nil;
    IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:ifc options:IOUSBHostObjectInitOptionsNone
                                                                       queue:g.queue error:&e interestHandler:nil];
    IOObjectRelease(ifc);
    if (!intf) {
        if (attempt < 10) usbRetryLater(dev, attempt);
        else ns2log(NS2PAD_LOG_WARN, "USB: could not open the controller's command interface: %s (another program using it?)",
                    e.localizedDescription.UTF8String);
        return;
    }
    IOUSBHostPipe *outPipe = nil, *inPipe = nil;
    const IOUSBConfigurationDescriptor *cd = intf.configurationDescriptor;
    const IOUSBInterfaceDescriptor *idesc = intf.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(cd, idesc, (const IOUSBDescriptorHeader *)ep))) {
        if (IOUSBGetEndpointType(ep) != kIOUSBEndpointTypeBulk) continue;
        IOUSBHostPipe *pipe = [intf copyPipeWithAddress:ep->bEndpointAddress error:nil];
        if (IOUSBGetEndpointDirection(ep) == kIOUSBEndpointDirectionIn) inPipe = pipe;
        else outPipe = pipe;
    }
    if (!outPipe || !inPipe) {
        ns2log(NS2PAD_LOG_WARN, "USB: the controller's command interface has no bulk endpoints");
        [intf destroy];
        return;
    }
    uint32_t loc = registryUInt(dev, CFSTR("locationID"));
    uint8_t key[16] = {'n', 's', '2', 'u', 's', 'b', 0, 0, 0, 0, 0, 0, (uint8_t)(loc >> 24), (uint8_t)(loc >> 16),
                       (uint8_t)(loc >> 8), (uint8_t)loc};
    NSUUID *ident = [[NSUUID alloc] initWithUUIDBytes:key];
    int slot = freeSlotFor(ident);
    if (slot < 0) {
        [intf destroy];
        return;
    }
    NS2Pad *pad = [NS2Pad new];
    pad.usb = YES;
    pad.usbIdent = [NSString stringWithFormat:@"usb-%08x", loc];
    pad.slot = slot;
    pad.productId = pid;
    pad->usbIntf = intf;
    pad->usbOut = outPipe;
    pad->usbIn = inPipe;
    pad->usbEntryId = entry;
    pad->usbLocation = loc;
    ns2_session_options so;
    ns2_session_options_default(&so);
    so.connect_vibration = g.config.connect_vibration;
    so.stick_deadzone = g.config.stick_deadzone;
    so.player_leds = (uint8_t)(1u << (slot & 3));
    so.usb = true;
    ns2_session_init(&pad->session, &so);
    g.lastSlot[ident] = @(slot);
    os_unfair_lock_lock(&g.lock);
    g.pads[slot] = pad;
    os_unfair_lock_unlock(&g.lock);
    setPhase(pad, PAD_HANDSHAKE);
    ns2log(NS2PAD_LOG_INFO, "pad %d: %s on USB, starting handshake", slot, ns2_product_name(pid));
    if (g.hidManager) {
        CFSetRef set = IOHIDManagerCopyDevices(g.hidManager);
        if (set) {
            CFIndex n = CFSetGetCount(set);
            const void **devs = calloc((size_t)n, sizeof *devs);
            CFSetGetValues(set, devs);
            for (CFIndex i = 0; i < n; i++)
                if (hidLocation((IOHIDDeviceRef)devs[i]) == loc) usbAttachHid(pad, (IOHIDDeviceRef)devs[i]);
            free(devs);
            CFRelease(set);
        }
    }
    usbReadNext(pad);
    startTimerIfNeeded();
}

static void usbDevicesAdded(void *ctx, io_iterator_t it) {
    (void)ctx;
    io_service_t dev;
    while ((dev = IOIteratorNext(it))) {
        usbOpenDevice(dev, 0);
        IOObjectRelease(dev);
    }
}

static void usbDevicesGone(void *ctx, io_iterator_t it) {
    (void)ctx;
    io_service_t dev;
    while ((dev = IOIteratorNext(it))) {
        uint64_t entry = 0;
        IORegistryEntryGetRegistryEntryID(dev, &entry);
        NS2Pad *pad = usbPadForEntry(entry);
        if (pad) {
            ns2log(NS2PAD_LOG_INFO, "pad %d: USB cable unplugged", pad.slot);
            removePad(pad);
            /* 蓝牙那个可以再连了（手柄按一下键就会发重连广播） */
            [g.usbTwins removeAllObjects];
        }
        IOObjectRelease(dev);
    }
}

static void usbStart(void) {
    g.usbPort = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(g.usbPort, g.queue);
    /* USB 匹配规则：只按厂商 ID 匹配不到设备，要带上产品 ID（这里用产品 ID 列表） */
    NSMutableArray *pids = [NSMutableArray new];
    for (int i = 0; i < 8 && g.config.accept_product_ids[i]; i++) [pids addObject:@(g.config.accept_product_ids[i])];
    NSDictionary *match = @{@kIOProviderClassKey : @"IOUSBHostDevice", @"idVendor" : @(NS2_VENDOR_ID),
                            @"idProductArray" : pids};
    IOServiceAddMatchingNotification(g.usbPort, kIOFirstMatchNotification, (__bridge_retained CFDictionaryRef)match,
                                     usbDevicesAdded, NULL, &g.usbAdded);
    IOServiceAddMatchingNotification(g.usbPort, kIOTerminatedNotification,
                                     (__bridge_retained CFDictionaryRef)[match copy], usbDevicesGone, NULL, &g.usbGone);
    usbDevicesGone(NULL, g.usbGone);
    g.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSMutableArray *m = [NSMutableArray new];
    for (int i = 0; i < 8 && g.config.accept_product_ids[i]; i++)
        [m addObject:@{@kIOHIDVendorIDKey : @(NS2_VENDOR_ID), @kIOHIDProductIDKey : @(g.config.accept_product_ids[i]),
                       @kIOHIDTransportKey : @kIOHIDTransportUSBValue}];
    IOHIDManagerSetDeviceMatchingMultiple(g.hidManager, (__bridge CFArrayRef)m);
    IOHIDManagerRegisterDeviceMatchingCallback(g.hidManager, hidMatched, NULL);
    IOHIDManagerRegisterInputReportCallback(g.hidManager, usbHidReport, NULL);
    IOHIDManagerSetDispatchQueue(g.hidManager, g.queue);
    IOHIDManagerOpen(g.hidManager, kIOHIDOptionsTypeNone);
    IOHIDManagerActivate(g.hidManager);
    ns2log(NS2PAD_LOG_DEBUG, "USB: watching for controllers");
    usbDevicesAdded(NULL, g.usbAdded); /* 已经插着的 */
}

static void usbStop(void) {
    for (int i = 0; i < NS2PAD_MAX_PADS; i++)
        if (g.pads[i] && g.pads[i].usb) usbClose(g.pads[i]);
    if (g.hidManager) {
        IOHIDManagerCancel(g.hidManager);
        IOHIDManagerClose(g.hidManager, kIOHIDOptionsTypeNone);
        CFRelease(g.hidManager);
        g.hidManager = NULL;
    }
    if (g.usbAdded) IOObjectRelease(g.usbAdded);
    if (g.usbGone) IOObjectRelease(g.usbGone);
    g.usbAdded = g.usbGone = 0;
    if (g.usbPort) IONotificationPortDestroy(g.usbPort);
    g.usbPort = NULL;
}

#else
static void usbWriteForward(NS2Pad *pad, const ns2_tx *tx) { (void)pad; (void)tx; }
#endif

/* ------------------------------------------------------------------------- */
/* C 接口                                                                     */
/* ------------------------------------------------------------------------- */

const char *ns2pad_version(void) { return NS2PAD_VERSION_STRING; }

void ns2pad_config_default(ns2pad_config *c) {
    memset(c, 0, sizeof *c);
    c->log_level = NS2PAD_LOG_INFO;
    c->auto_reconnect = true;
    c->connect_vibration = true;
    c->stick_deadzone = 0.0f;
    c->use_combined_command_channel = false;
    c->accept_product_ids[0] = NS2PAD_PID_PRO2;
    c->usb = true;
    c->bluetooth = true;
}

int ns2pad_start(const ns2pad_callbacks *callbacks, void *user, const ns2pad_config *config) {
    if (g.started) return -1;
    g.started = true;
    memset(&g.cb, 0, sizeof g.cb);
    if (callbacks) g.cb = *callbacks;
    g.user = user;
    if (config) g.config = *config;
    else ns2pad_config_default(&g.config);
    if (!g.config.accept_product_ids[0]) g.config.accept_product_ids[0] = NS2PAD_PID_PRO2;
    g.queue = dispatch_queue_create("ns2pad.bluetooth", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(g.queue, kQueueKey, kQueueKey, NULL);
    g.pending = [NSMutableArray new];
    g.lastSlot = [NSMutableDictionary new];
    g.usbTwins = [NSMutableSet new];
    g.wantScan = true;
    g.delegate = [NS2Central new];
    dispatch_async(g.queue, ^{
        if (g.config.bluetooth)
            g.central = [[CBCentralManager alloc] initWithDelegate:g.delegate queue:g.queue options:nil];
#if NS2_HAVE_USB
        if (g.config.usb) usbStart();
#endif
    });
    return 0;
}

void ns2pad_stop(void) {
    if (!g.started) return;
    runOnQueueSync(^{
        if (g.timer) {
            dispatch_source_cancel(g.timer);
            g.timer = nil;
        }
        if (g.central.isScanning) [g.central stopScan];
#if NS2_HAVE_USB
        usbStop();
#endif
        for (int i = 0; i < NS2PAD_MAX_PADS; i++) {
            NS2Pad *pad = g.pads[i];
            if (!pad) continue;
            pad.userDisconnect = YES;
            [g.central cancelPeripheralConnection:pad.peripheral];
            pad.peripheral.delegate = nil;
            os_unfair_lock_lock(&g.lock);
            g.pads[i] = nil;
            os_unfair_lock_unlock(&g.lock);
        }
        for (NS2Pad *pad in g.pending) {
            [g.central cancelPeripheralConnection:pad.peripheral];
            pad.peripheral.delegate = nil;
        }
        [g.pending removeAllObjects];
        g.central.delegate = nil;
        g.central = nil;
        g.btReady = false;
    });
    memset(&g.cb, 0, sizeof g.cb);
    g.delegate = nil;
    g.queue = nil;
    g.started = false;
}

void ns2pad_set_scanning(bool on) {
    if (!g.started) return;
    dispatch_async(g.queue, ^{
        g.wantScan = on;
        updateScan();
    });
}

bool ns2pad_bluetooth_ready(void) { return g.started && g.btReady; }

static NS2Pad *lockedPad(int pad) {
    if (pad < 0 || pad >= NS2PAD_MAX_PADS) return nil;
    return g.pads[pad];
}

bool ns2pad_is_connected(int pad) {
    if (!g.started) return false;
    os_unfair_lock_lock(&g.lock);
    NS2Pad *p = lockedPad(pad);
    bool r = p && p.connectedReported;
    os_unfair_lock_unlock(&g.lock);
    return r;
}

bool ns2pad_get_state(int pad, ns2pad_state *out) {
    if (!g.started || !out) return false;
    os_unfair_lock_lock(&g.lock);
    NS2Pad *p = lockedPad(pad);
    bool r = p && p->haveState;
    if (r) *out = p->latest;
    os_unfair_lock_unlock(&g.lock);
    return r;
}

bool ns2pad_get_info(int pad, ns2pad_info *out) {
    if (!g.started || !out) return false;
    os_unfair_lock_lock(&g.lock);
    NS2Pad *p = lockedPad(pad);
    bool r = p && p.connectedReported;
    if (r) *out = p->info;
    os_unfair_lock_unlock(&g.lock);
    return r;
}

uint16_t ns2pad_rumble_amp_from_unit(float unit) {
    if (!(unit > 0)) return 0;
    if (unit > 1) unit = 1;
    return (uint16_t)(unit * NS2_RUMBLE_SAFE_MAX_AMP + 0.5f);
}

bool ns2pad_set_rumble_hd(int pad, const ns2pad_rumble_frame *left, const ns2pad_rumble_frame *right) {
    if (!g.started) return false;
    static const ns2pad_rumble_frame zero = {NS2_RUMBLE_DEFAULT_HIGH_FREQ, 0, NS2_RUMBLE_DEFAULT_LOW_FREQ, 0};
    if (!left) left = right ? right : &zero;
    if (!right) right = left;
    os_unfair_lock_lock(&g.lock);
    NS2Pad *p = lockedPad(pad);
    bool r = p && p.connectedReported;
    if (r) {
        p->rumble[0] = *left;
        p->rumble[1] = *right;
        bool active = left->high_amp || left->low_amp || right->high_amp || right->low_amp;
        if (p->rumbleActive && !active) p->rumbleTail = 3;
        p->rumbleActive = active;
    }
    os_unfair_lock_unlock(&g.lock);
    return r;
}

bool ns2pad_set_rumble(int pad, float low, float high) {
    ns2pad_rumble_frame f = {NS2_RUMBLE_DEFAULT_HIGH_FREQ, ns2pad_rumble_amp_from_unit(high),
                             NS2_RUMBLE_DEFAULT_LOW_FREQ, ns2pad_rumble_amp_from_unit(low)};
    return ns2pad_set_rumble_hd(pad, &f, NULL);
}

static bool queueCommand(int pad, const uint8_t *cmd, size_t len) {
    if (!g.started || !ns2pad_is_connected(pad)) return false;
    NSData *data = [NSData dataWithBytes:cmd length:len];
    dispatch_async(g.queue, ^{
        NS2Pad *p = lockedPad(pad);
        if (p && !ns2_session_queue_command(&p->session, data.bytes, data.length))
            ns2log(NS2PAD_LOG_WARN, "pad %d: command queue full", pad);
    });
    return true;
}

bool ns2pad_play_vibration_sample(int pad, uint8_t sample) {
    uint8_t cmd[16];
    size_t n = ns2_build_vibration_sample(cmd, sizeof cmd, sample);
    return queueCommand(pad, cmd, n);
}

bool ns2pad_set_player_leds(int pad, uint8_t mask) {
    uint8_t cmd[16];
    size_t n = ns2_build_player_leds(cmd, sizeof cmd, mask);
    return queueCommand(pad, cmd, n);
}

void ns2pad_disconnect(int pad) {
    if (!g.started) return;
    dispatch_async(g.queue, ^{
        NS2Pad *p = lockedPad(pad);
        if (!p) return;
        p.userDisconnect = YES;
        if (p.usb) removePad(p); /* USB：只是不再读它；重新插线才会再连 */
        else [g.central cancelPeripheralConnection:p.peripheral];
    });
}
