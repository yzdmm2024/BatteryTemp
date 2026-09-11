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

#pragma mark - 偏好（直接读全局 plist，避免 App 沙盒下跨进程读不到）
// 设置面板(Preferences 进程)通过 NSUserDefaults suite 写入 /var/mobile/Library/Preferences/com.yzdmm.batterytemp.plist
// 普通 App 在沙盒里 initWithSuiteName 只能读自己的容器，故这里直接读全路径文件，天然拿到最新值。
static NSString *const kEnabled  = @"enabled";    // 开关
static NSString *const kVGap     = @"vGap";       // 高度
static NSString *const kHOffset  = @"hOffset";    // 左右
static NSString *const kVOffset  = @"vOffset";    // 上下
static NSString *const kFontSize = @"fontSize";   // 大小

static CFStringRef kChangedCFName = CFSTR("com.yzdmm.batterytemp.changed");

static NSString *bt_prefsPath(void) {
    return @"/var/mobile/Library/Preferences/com.yzdmm.batterytemp.plist";
}

static BOOL btBool(NSString *key, BOOL def) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:bt_prefsPath()];
    id v = d ? d[key] : nil;
    return v ? [v boolValue] : def;
}
static double btDouble(NSString *key, double def) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:bt_prefsPath()];
    id v = d ? d[key] : nil;
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

static UIView *bt_scanView(UIView *v);

static UIView *bt_findHost(void) {
    UIApplication *app = [UIApplication sharedApplication];
    // 优先找含状态栏电池视图的窗口：普通 App 的状态栏是独立 _UIStatusBarWindow，
    // 不吸附它的话标签会落到空白右上角。找不到再回退到前台 keyWindow。
    for (UIWindow *w in [app windows]) {
        if (bt_scanView(w)) return w;
    }
    UIWindow *kw = app.keyWindow;
    if (kw) return kw;
    return [app.windows firstObject];
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
    l.backgroundColor = [UIColor clearColor];              // 完全透明，不遮住后面内容
    l.layer.shadowColor = [UIColor blackColor].CGColor;    // 文字阴影，浅色/白色界面也清晰可读
    l.layer.shadowOpacity = 0.8f;
    l.layer.shadowRadius = 1.0;
    l.layer.shadowOffset = CGSizeMake(0, 0.5);
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
    double size = MAX(btDouble(kFontSize, 10), 5);   // 默认接近状态栏小字，最小 5
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
    UIApplication *app = [UIApplication sharedApplication];
    // 宿主=含状态栏电池的窗口，属于“状态栏”层，滑app/转场时一直存在，常驻不消失。
    // 找到一次后尽量复用；只有它失效(不在窗口列表)才重新找，避免跟着 keyWindow 跳来跳去。
    BOOL hostAlive = gHost && [[app windows] containsObject:(UIWindow*)gHost];
    if (!hostAlive) {
        UIView *nb = nil, *nw = nil;
        for (UIWindow *w in [app windows]) {
            UIView *f = bt_scanView(w);
            if (f) { nw = w; nb = f; break; }
        }
        if (nw) { gHost = nw; gBattery = nb; }
        else   { gBattery = nil; gHost = app.keyWindow ?: [app.windows firstObject]; }
    } else if (!gBattery || ![gBattery window]) {
        gBattery = bt_scanView(gHost);   // 宿主还在但电池视图被重建了，重新扫
    }
    if (!gHost) return;
    bt_ensureLabel();
    if (gLabel && [gLabel window] != gHost) {
        [gLabel removeFromSuperview];
        [gHost addSubview:gLabel];
        [gHost bringSubviewToFront:gLabel];
    }
    if (gLabel) bt_position();
}

static void bt_startTimer(void) {
    if (gTimerStarted) return;
    gTimerStarted = 1;
    // 高频自愈：状态栏一出现就能立刻吸附上，切换 App 时基本无感
    [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t){
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
// 只有真正带状态栏的 UI 进程才需要叠加标签：
//   跳过系统 daemon（无 bundle id）与设置面板进程（它自己就是配置界面）。
static BOOL bt_shouldInject(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return NO;
    if ([bid isEqualToString:@"com.apple.Preferences"]) return NO;
    return YES;   // SpringBoard 与普通 App 都注入，实现“贯穿”显示
}

__attribute__((constructor))
static void btInit(void) {
    if (!bt_shouldInject()) return;
    @autoreleasepool {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        btChangedNotifyCallback, kChangedCFName, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        bt_startTimer();   // 注入立即启动自愈定时器，状态栏一出现就吸附，切换时无延迟
    }
    NSLog(@"[电池温度] dylib 注入 UI 进程 (iOS16 / rootless / 状态栏电池下常驻透明小字, 贯穿显示)");
}