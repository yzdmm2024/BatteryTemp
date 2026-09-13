// 电池温度 BatteryTemp —— rootless (relaxin / Dopamine) / iOS 16
// 仅注入 SpringBoard。平时完全静默：不创建定时器、不调用 IOKit、不耗电。
// 仅当「设置 → 电池温度」面板打开时，才通过 Darwin 通知启动 1s 轮询，
// 把 AppleSmartBattery 真实温度(°C)/电压(V)/电流(mA)/循环次数写入共享 plist；
// 面板关闭（或设置 App 退后台）即停止轮询，回到静默。

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <mach/mach_port.h>

#pragma mark - 共享实时数据路径（与 PSBatteryTempController.m 保持一致）
static NSString *bt_livePath(void) {
    return @"/var/mobile/Library/Preferences/com.yzdmm.batterytemp.live.plist";
}

#pragma mark - IOKit 前向声明（Objective-C++ 下必须 extern "C"）
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;

extern "C" {
CFMutableDictionaryRef IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t masterPort, CFDictionaryRef matching);
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options);
kern_return_t IOObjectRelease(io_object_t object);
}

// 读 AppleSmartBattery 上的整型属性（Temperature/Voltage/Current/CycleCount 等）
static int64_t bt_bs_int(NSString *key) {
    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSmartBattery"));
    if (!svc) return -1;
    int64_t v = -1;
    CFTypeRef ref = IORegistryEntryCreateCFProperty(svc, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    if (ref) {
        if (CFGetTypeID(ref) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)ref, kCFNumberSInt64Type, &v);
        }
        CFRelease(ref);
    }
    IOObjectRelease(svc);
    return v;
}

// AppleSmartBattery 的 Temperature 单位是 0.1K（deciKelvin）→ 换算成摄氏度
static double bt_bs_temp_c(void) {
    int64_t raw = bt_bs_int(@"Temperature");
    if (raw <= 0) return -1;
    return (raw / 10.0) - 273.15;
}

#pragma mark - 发布实时数据到共享 plist
static void bt_publish(void) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
        double c = bt_bs_temp_c();
        int64_t volt = bt_bs_int(@"Voltage");
        int64_t cur  = bt_bs_int(@"Current");
        int64_t cyc  = bt_bs_int(@"CycleCount");
        d[@"temperatureC"] = (c >= 0) ? @(c) : @(-1);
        d[@"voltageV"]     = (volt > 0) ? @(volt / 1000.0) : @(-1);
        d[@"currentMA"]    = @(cur);   // 0 = 空闲；正负号见面板说明
        d[@"cycle"]        = (cyc > 0) ? @(cyc) : @(-1);
        [d writeToFile:bt_livePath() atomically:YES];
    } @catch (NSException *e) {
        NSLog(@"[电池温度] publish 异常: %@", e);
    }
}

#pragma mark - 面板打开时才跑的 1s 轮询（默认关闭 = 静默）
static dispatch_source_t gTimer = NULL;

static void bt_start(void) {
    if (gTimer) return;   // 已运行，幂等
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTimer) return;
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, 1ull * NSEC_PER_SEC, 0.2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gTimer, ^{ bt_publish(); });
    dispatch_resume(gTimer);
    bt_publish();   // 立即出第一帧，避免面板刚打开时空白
    NSLog(@"[电池温度] 面板已打开，开始读取电池温度");
}

static void bt_stop(void) {
    if (gTimer) { dispatch_source_cancel(gTimer); gTimer = NULL; }
    NSLog(@"[电池温度] 面板已关闭，停止读取（静默，不耗电）");
}

#pragma mark - Darwin 通知（面板 ↔ 插件 跨进程）
static void bt_notify_cb(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    if ([n isEqualToString:@"com.yzdmm.batterytemp.open"])       bt_start();
    else if ([n isEqualToString:@"com.yzdmm.batterytemp.close"]) bt_stop();
}

#pragma mark - 构造函数（仅注入 SpringBoard，加载即静默等待通知）
__attribute__((constructor))
static void btInit(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.apple.springboard"]) return;
    @autoreleasepool {
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(nc, NULL, bt_notify_cb,
            CFSTR("com.yzdmm.batterytemp.open"),  NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(nc, NULL, bt_notify_cb,
            CFSTR("com.yzdmm.batterytemp.close"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        NSLog(@"[电池温度] 已加载：平时静默，仅「设置 → 电池温度」面板打开时读取");
    }
}
