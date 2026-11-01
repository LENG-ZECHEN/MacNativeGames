/*
 * ns2pad_apple.m — 苹果平台（macOS、iOS 共用）的传输层：用 CoreBluetooth 直接连 Switch 2 手柄，
 * 实现 include/ns2pad.h 里的 C 接口。
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

static void writeTx(NS2Pad *pad, const ns2_tx *tx) {
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
    snprintf(info.identifier, sizeof info.identifier, "%s", pad.peripheral.identifier.UUIDString.UTF8String);
    info.player_index = pad.slot;
    os_unfair_lock_lock(&g.lock);
    pad->info = info;
    os_unfair_lock_unlock(&g.lock);
}

static void startTimerIfNeeded(void);

/* 握手结束（成功或部分失败）：打开输入报告通知（报告速率描述符等订阅成功后再写）。 */
static void finishHandshake(NS2Pad *pad, bool ok) {
    setPhase(pad, PAD_SUBSCRIBING);
    pad.subscribeStart = now_ns();
    ns2log(ok ? NS2PAD_LOG_INFO : NS2PAD_LOG_WARN, "pad %d: handshake %s (imu %s)", pad.slot,
           ok ? "done" : "finished with timeouts", pad->session.imu_enabled ? "on" : "not confirmed");
    /* 真机（macOS）上先写报告速率描述符会把订阅卡住约 3 秒，所以先订阅输入，订阅成功后再写描述符 */
    [pad.peripheral setNotifyValue:YES forCharacteristic:pad.input];
}

/* 输入报告订阅成功：进入就绪状态，通知使用者，再写报告速率描述符。
   真机上订阅确认（didUpdateNotificationState）有时迟迟不来，但数据已经在来，所以收到第一帧输入时也会调用这里。 */
static void padBecameReady(NS2Pad *pad) {
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
    if (pad.rateDesc) {
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
        if (pad.phase == PAD_SUBSCRIBING && now > pad.phaseSince && now - pad.phaseSince > 100ull * 1000 * 1000) {
            ns2log(NS2PAD_LOG_DEBUG, "pad %d: input subscription not confirmed after 0.1 s, retrying", pad.slot);
            setPhase(pad, PAD_SUBSCRIBING);
            [pad.peripheral setNotifyValue:YES forCharacteristic:pad.input];
        }
        if (pad.phase == PAD_READY && pad.rumbleOut) {
            os_unfair_lock_lock(&g.lock);
            bool send = pad->rumbleActive || pad->rumbleTail > 0;
            ns2pad_rumble_frame l = pad->rumble[0], r = pad->rumble[1];
            if (!pad->rumbleActive && pad->rumbleTail > 0) {
                l.high_amp = l.low_amp = r.high_amp = r.low_amp = 0;
            }
            os_unfair_lock_unlock(&g.lock);
            if (send && pad.peripheral.canSendWriteWithoutResponse) {
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
    int slot = pad.slot;
    bool reported = pad.connectedReported;
    os_unfair_lock_lock(&g.lock);
    if (slot >= 0 && slot < NS2PAD_MAX_PADS && g.pads[slot] == pad) g.pads[slot] = nil;
    os_unfair_lock_unlock(&g.lock);
    [g.pending removeObject:pad];
    if (reported && g.cb.disconnected) g.cb.disconnected(g.user, slot);
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
        ns2pad_state st;
        if (!ns2_session_on_input(&pad->session, v.bytes, v.length, now, &st)) return;
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
    g.wantScan = true;
    g.delegate = [NS2Central new];
    dispatch_async(g.queue, ^{
        g.central = [[CBCentralManager alloc] initWithDelegate:g.delegate queue:g.queue options:nil];
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
        [g.central cancelPeripheralConnection:p.peripheral];
    });
}
