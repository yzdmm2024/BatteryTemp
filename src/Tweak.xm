// 电池温度 BatteryTemp —— 桌面/状态栏电池图标正下方显示 温度(°C)+电压(V)
// 适配：iPhone 12 Pro / iOS 16.x / rootless (relaxin・Dopamine) / ElleKit TweakInject
// 注入 com.apple.springboard。不依赖具体的电池私有类名：
//   轮询扫描状态栏找到电池视图(类名含 BatteryView/BatteryItemView)做锚点，
//   找不到就回退到右上角默认位置，保证温度电压一定显示。
// 标签直接加在 SpringBoard 主窗口上（不受状态栏裁剪），位置/字号由设置面板调节。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_port.h>

#pragma mark - 偏好（与设置面板共享同一 suite）
static NSString *const kEnabled  = @"enabled";    // 开关
static NSString *const kVGap     = @"vGap";       // 高度
static NSString *const kHOffset  = @"hOffset";    // 左右
static NSString *const kVOffset  = @"vOffset";    // 上下
static NSString *const kFontSize = @"fontSize";   // 大小

static CFStringRef kChangedCFName = CFSTR("com.yzdmm.batterytemp.changed");

static BOOL btBool(NSString *key, BOOL def) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yzdmm.batterytemp"];
    id v = [d objectForKey:key];
    return v ? [v boolValue] : def;
}
static double btDouble(NSString *key, double def) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yzdmm.batterytemp"];
    id v = [d objectForKey:key];
    return v ? [v doubleValue] : def;
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

static double bt_bs_temp_c(void) {
    int64_t raw = bt_bs_int(@"Temperature");
    if (raw <= 0) return -1;
    return (raw / 10.0) - 273.15;
}

static NSString *bt_composeText(void) {
    double c = bt_bs_temp_c();
    int64_t volt = bt_bs_int(@"Voltage");
    NSMutableString *s = [NSMutableString string];
    if (c >= 0) [s appendFormat:@"%.1f°C", c]; else [s appendString:@"--"];
    if (volt > 0) { [s appendString:@"  "]; [s appendFormat:@"%.2fV", volt / 1000.0]; }
    return s.length ? s : @"--";
}

#pragma mark - 覆盖层标签
static UILabel *gLabel = nil;
static UIView  *gHost  = nil;              // SpringBoard 主窗口（strong）
static __weak UIView *gBattery = nil;      // 找到的电池视图（weak，不持有）
static int gTimerStarted = 0;
static void bt_startTimer(void);

static UIView *bt_findHost(void) {
    for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
        if (w.rootViewController) return w;
    }
    return [[[UIApplication sharedApplication] windows] firstObject];
}

static BOOL bt_isBatteryView(UIView *v) {
    NSString *cn = NSStringFromClass([v class]);
    if (!cn) return NO;
    return ([cn containsString:@"BatteryItemView"] || [cn containsString:@"BatteryView"]);
}

static UIView *bt_scanView(UIView *v) {
    if (!v) return nil;
    if (bt_isBatteryView(v)) return v;
    for (UIView *sv in [v subviews]) {
        UIView *r = bt_scanView(sv);
        if (r) return r;
    }
    return nil;
}

static CGFloat bt_statusHeight(void) {
    if (gHost) {
        UIEdgeInsets ins = gHost.safeAreaInsets;
        if (ins.top > 0) return ins.top;
    }
    return 47;
}

static void bt_ensureLabel(void) {
    if (gLabel) return;
    if (!gHost) gHost = bt_findHost();
    if (!gHost) return;
    UILabel *l = [[UILabel alloc] init];
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    l.layer.cornerRadius = 6.0;
    l.layer.masksToBounds = YES;
    l.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    l.layer.borderWidth = 0.5;
    l.layer.zPosition = 1000;
    l.userInteractionEnabled = NO;
    [gHost addSubview:l];
    [gHost bringSubviewToFront:l];
    gLabel = l;
}

// 电池在窗口坐标系中的区域；找不到就回退到右上角默认位置
static CGRect bt_batteryRect(void) {
    if (gBattery && gHost) {
        CGRect r = [gBattery convertRect:gBattery.bounds toView:gHost];
        if (CGRectGetWidth(r) > 0 && CGRectGetHeight(r) > 0) return r;
    }
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    return CGRectMake(w - 36, bt_statusHeight() * 0.35, 25, 12);
}

static void bt_position(void) {
    if (!gLabel) bt_ensureLabel();
    if (!gLabel || !gHost) return;
    CGRect r = bt_batteryRect();
    double size = MAX(btDouble(kFontSize, 13), 8);
    gLabel.font = [UIFont systemFontOfSize:(CGFloat)size weight:UIFontWeightMedium];
    gLabel.text = bt_composeText();
    [gLabel sizeToFit];
    CGSize ls = gLabel.bounds.size;
    CGFloat gap = (CGFloat)btDouble(kVGap, 8);
    CGFloat off = (CGFloat)btDouble(kVOffset, 0);
    CGFloat cx = CGRectGetMidX(r) + (CGFloat)btDouble(kHOffset, 0);
    CGFloat cy = CGRectGetMaxY(r) + gap + off + ls.height * 0.5;
    CGFloat minCx = ls.width * 0.5;
    CGFloat maxCx = gHost.bounds.size.width - ls.width * 0.5;
    if (maxCx < minCx) maxCx = minCx;
    cx = MIN(MAX(cx, minCx), maxCx);
    if (cy < 0) cy = 0;
    gLabel.center = CGPointMake(cx, cy);
}

static void bt_tick(void) {
    if (!btBool(kEnabled, YES)) {
        if (gLabel) { [gLabel removeFromSuperview]; gLabel = nil; }
        return;
    }
    if (!gHost) gHost = bt_findHost();
    if (!gBattery && gHost) gBattery = bt_scanView(gHost);
    bt_ensureLabel();
    if (gLabel) bt_position();
}

static void bt_startTimer(void) {
    if (gTimerStarted) return;
    gTimerStarted = 1;
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t){
        dispatch_async(dispatch_get_main_queue(), ^{ bt_tick(); });
    }];
    bt_tick();
}

#pragma mark - 通知回调
static void btChangedNotifyCallback(CFNotificationCenterRef __unused center,
                                    void * __unused observer,
                                    CFStringRef __unused name,
                                    const void * __unused object,
                                    CFDictionaryRef __unused userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ bt_tick(); });
}

#pragma mark - 构造函数
__attribute__((constructor))
static void btInit(void) {
    @autoreleasepool {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        btChangedNotifyCallback, kChangedCFName, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        for (int i = 1; i <= 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!gHost) gHost = bt_findHost();
                if (!gHost) return;
                if (!gBattery) gBattery = bt_scanView(gHost);
                bt_ensureLabel();
                if (gLabel) bt_position();
                bt_startTimer();
            });
        }
    }
    NSLog(@"[电池温度] dylib 已注入 SpringBoard (iOS16 / rootless / 状态栏电池下叠加标签)");
}