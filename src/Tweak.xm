// 电池温度 BatteryTemp —— 桌面/状态栏电池图标正下方显示 温度(°C)+电压(V)
// 适配：iPhone 12 Pro / iOS 16.x / rootless (relaxin・Dopamine) / ElleKit TweakInject
// 注入 com.apple.springboard：挂钩状态栏电池视图 _UIStatusBarBatteryItemView，
// 在其正下方叠加一个小标签，仅显示「25.8°C  4.07V」；去掉文字与循环次数。
// 位置/字号可在「设置 → 电池温度」面板用 - / + 实时调节（高度/左右/上下/大小）。
// 温度数据：IOKit 注册表 AppleSmartBattery.Temperature(0.1K) / Voltage(mV)。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach/mach_port.h>

#pragma mark - 偏好（与设置面板共享同一 suite）
static NSString *const PS_DOMAIN = @"com.yzdmm.batterytemp";
static NSString *const kEnabled  = @"enabled";    // 开关，默认开
static NSString *const kVGap     = @"vGap";       // 高度：距电池图标下沿的间距
static NSString *const kHOffset  = @"hOffset";    // 左右：水平偏移（+右 -左）
static NSString *const kVOffset  = @"vOffset";    // 上下：垂直额外偏移（+下 -上）
static NSString *const kFontSize = @"fontSize";   // 大小：文字字号

static const char kChangedName[] = "com.yzdmm.batterytemp.changed";

static BOOL btBool(NSString *key, BOOL def) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:PS_DOMAIN];
    id v = [d objectForKey:key];
    return v ? [v boolValue] : def;
}
static double btDouble(NSString *key, double def) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:PS_DOMAIN];
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

#pragma mark - 标签管理与定位
static NSMutableArray *gLabels = nil;      // 已附加到状态栏电池下方的 UILabel（weak）
static int gTimerStarted = 0;
static void bt_startTimer_L(void);         // 前向声明：下文中定义

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

static void bt_positionLabel(UILabel *label, UIView *batView) {
    double size = btDouble(kFontSize, 13);
    if (size < 8) size = 8;
    label.font = [UIFont systemFontOfSize:(CGFloat)size weight:UIFontWeightMedium];
    [label sizeToFit];

    UIView *host = [batView superview];
    if (!host) return;
    CGRect f = [batView frame];
    CGFloat gap = (CGFloat)btDouble(kVGap, 8) + (CGFloat)btDouble(kVOffset, 0);
    CGFloat cx = f.origin.x + f.size.width * 0.5 + (CGFloat)btDouble(kHOffset, 0);
    CGSize ls = label.bounds.size;
    CGPoint center = CGPointMake(cx, f.origin.y + f.size.height + gap + ls.height * 0.5);
    label.center = center;

    // 不让标签跑出屏幕左右边缘
    CGFloat sw = host.bounds.size.width;
    if (sw > 0) {
        CGRect nf = label.frame;
        CGFloat maxX = sw - ls.width - 4;
        if (maxX < 4) maxX = 4;
        nf.origin.x = MIN(MAX(nf.origin.x, 4), maxX);
        label.frame = nf;
    }
}

static void bt_applyForView(id batView) {
    if (!batView) return;
    UIView *v = (UIView *)batView;
    // 电池视图已不在屏幕上 → 移除标签
    if (![v window]) {
        UILabel *old = objc_getAssociatedObject(v, @selector(btTag));
        if (old) { [old removeFromSuperview]; objc_setAssociatedObject(v, @selector(btTag), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [gLabels removeObject:old]; }
        return;
    }
    if (!btBool(kEnabled, YES)) {
        UILabel *old = objc_getAssociatedObject(v, @selector(btTag));
        if (old) { [old removeFromSuperview]; objc_setAssociatedObject(v, @selector(btTag), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [gLabels removeObject:old]; }
        return;
    }
    UIView *host = [v superview];
    if (!host) return;

    if (!gLabels) gLabels = [[NSMutableArray alloc] init];

    UILabel *label = objc_getAssociatedObject(v, @selector(btTag));
    if (!label) {
        label = [[UILabel alloc] init];
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        label.layer.cornerRadius = 6.0;
        label.layer.masksToBounds = YES;
        label.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        label.layer.borderWidth = 0.5;
        label.userInteractionEnabled = NO;
        [host addSubview:label];
        objc_setAssociatedObject(v, @selector(btTag), label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(label, @selector(btBat), v, OBJC_ASSOCIATION_ASSIGN);
        if (![gLabels containsObject:label]) [gLabels addObject:label];
    }
    label.text = bt_composeText();
    bt_positionLabel(label, v);
    bt_startTimer_L();
}

static void bt_layOutAll(void) {
    // 遍历已附加的标签：重构 text 并重新定位（通知回调 / 定时器入口）
    for (UILabel *l in [gLabels copy]) {
        id bat = objc_getAssociatedObject(l, @selector(btBat));
        if (bat) {
            if (![bat window]) continue;
            [(UILabel *)l setText:bt_composeText()];
            bt_positionLabel(l, bat);
        }
    }
}

static void bt_applyAll(void) {
    if (btBool(kEnabled, YES)) {
        bt_layOutAll();
        bt_startTimer_L();
    } else {
        for (UILabel *l in [gLabels copy]) { [l removeFromSuperview]; }
        [gLabels removeAllObjects];
    }
}

#pragma mark - 全局刷新定时器（每 3 秒更新数据与位置）
__attribute__((noinline)) static void bt_startTimer_L(void) {
    if (gTimerStarted) return;
    gTimerStarted = 1;
    [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t){
        if (!btBool(kEnabled, YES)) return;
        if (gLabels.count == 0) return;
        bt_layOutAll();
    }];
}

#pragma mark - 扫描状态栏找到电池视图
static Class bt_batteryClass(void) {
    Class c = objc_getClass("_UIStatusBarBatteryItemView");
    if (c) return c;
    return objc_getClass("UIStatusBarBatteryItemView");
}

static void bt_scanRecursive(UIView *view) {
    if (!view) return;
    Class bc = bt_batteryClass();
    if (bc && [view isKindOfClass:bc]) bt_applyForView(view);
    for (UIView *sv in view.subviews) bt_scanRecursive(sv);
}

#pragma mark - Runtime 挂钩（替代 Logos；用原生 runtime swizzle）
static IMP bt_orig_layout = NULL;
static void bt_batteryLayoutSubviews(id self, SEL _cmd) {
    if (![self isKindOfClass:bt_batteryClass()]) {   // 若方法继承自 UIView，仅对电池视图处理
        if (bt_orig_layout) ((void (*)(id, SEL))bt_orig_layout)(self, _cmd);
        return;
    }
    if (bt_orig_layout)
        ((void (*)(id, SEL))bt_orig_layout)(self, _cmd);
    bt_applyForView(self);
}

static IMP bt_orig_sbDidMove = NULL;
static void bt_statusBarDidMoveToWindow(id self, SEL _cmd) {
    Class sc = objc_getClass("_UIStatusBar");
    if (sc && ![self isKindOfClass:sc]) {            // 同样只在状态栏实例上扫描
        if (bt_orig_sbDidMove) ((void (*)(id, SEL))bt_orig_sbDidMove)(self, _cmd);
        return;
    }
    if (bt_orig_sbDidMove)
        ((void (*)(id, SEL))bt_orig_sbDidMove)(self, _cmd);
    bt_scanRecursive(self);
}

// 只 swizzle 一次：反复 method_setImplementation 会把原实现覆盖成自己造成递归
static int gSwizzled = 0;
static void bt_hookSwizzleOnce(void) {
    if (gSwizzled) return;
    Class bc = bt_batteryClass();
    Class sc = objc_getClass("_UIStatusBar");
    if (!bc || !sc) return;
    Method m = class_getInstanceMethod(bc, @selector(layoutSubviews));
    if (m) { bt_orig_layout = method_getImplementation(m); method_setImplementation(m, (IMP)bt_batteryLayoutSubviews); }
    Method m2 = class_getInstanceMethod(sc, @selector(didMoveToWindow));
    if (m2) { bt_orig_sbDidMove = method_getImplementation(m2); method_setImplementation(m2, (IMP)bt_statusBarDidMoveToWindow); }
    gSwizzled = 1;
}

static void bt_hookIfPossible(void) {
    bt_hookSwizzleOnce();
    // 现有状态栏直接扫一遍，把已经建好的电池视图也挂上
    if (gLabels == nil) gLabels = [[NSMutableArray alloc] init];
    for (UIWindow *w in [[UIApplication sharedApplication] windows]) bt_scanRecursive(w);
}

#pragma mark - 构造函数
static void btChangedCallback(int token) {
    dispatch_async(dispatch_get_main_queue(), ^{ bt_applyAll(); });
}

__attribute__((constructor))
static void btInit(void) {
    @autoreleasepool {
        notify_register_dispatch(kChangedName, &(int){0}, dispatch_get_main_queue(), ^(int token){
            btChangedCallback(token);
        });
        // 轮询挂载：SpringBoard 启动后状态栏/电池视图逐步创建
        for (int i = 1; i <= 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                bt_hookIfPossible();
            });
        }
    }
    NSLog(@"[电池温度] dylib 已注入 SpringBoard (iOS16 / rootless / 状态栏电池下方)");
}