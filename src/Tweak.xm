// 电池温度 BatteryTemp — 在「设置 → 电池」页面显示实时电池温度/电压/循环次数
// 适配：iPhone 12 Pro / iOS 16.x / rootless (relaxin・Dopamine) / ElleKit TweakInject
// 关键修复：
//   1) iOS 16 设置电池页的真实控制器类是 BatteryUIController（BatteryUIDetailController 不存在），
//      且它位于惰性加载的 BatteryUsageUI.bundle 内 —— 必须在 bundle 加载后再 %init 才挂得上。
//   2) 标签可拖动：在电池页用手指拖动温度文字到任意位置，松手自动保存百分比坐标。
//   3) 提供「设置 → 电池温度」面板（开关 / 默认位置 / 重置），改动实时生效。
// 温度数据来源：IOKit 注册表 AppleSmartBattery 的 Temperature（0.1K）实际电芯内部温度。

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach/mach_port.h>

#pragma mark - 偏好（与设置面板共享同一 suite）
static NSString *const PS_DOMAIN = @"com.yzdmm.batterytemp";
static NSString *const kEnabled  = @"enabled";    // 开关，默认开
static NSString *const kAnchor   = @"anchor";     // 0=电池正下方(默认) 1=页面底部
static NSString *const kCenterX  = @"centerX";    // 拖动后保存的相对横坐标 0..1
static NSString *const kCenterY  = @"centerY";    // 相对纵坐标 0..1
static NSString *const kChanged  = @"com.yzdmm.batterytemp.changed";

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
static void btSetDouble(NSString *key, double val) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:PS_DOMAIN];
    [d setDouble:val forKey:key];
    [d synchronize];   // 立即落盘，防进程被杀丢失拖动后的位置
}

#pragma mark - IOKit 前向声明（运行时符号由系统提供，走 -undefined,dynamic_lookup）
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;

CFMutableDictionaryRef IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t masterPort, CFDictionaryRef matching);
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options);
kern_return_t IOObjectRelease(io_object_t object);

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

#pragma mark - 关联对象键
static const void *kLabelKey = &kLabelKey;
static const void *kTimerKey = &kTimerKey;

static void bt_layOut(UILabel *label, UIView *host) {
    double cx = btDouble(kCenterX, 0.5);
    double cy = btDouble(kCenterY, -1);
    if (cy < 0)   // 尚未手动拖动过 → 用“默认位置”锚点
        cy = (btDouble(kAnchor, 0) < 1) ? 0.20 : 0.88;
    CGFloat w = host.bounds.size.width;
    CGFloat h = host.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    CGFloat px = MIN(MAX((CGFloat)cx, 0.05), 0.95) * w;
    CGFloat py = MIN(MAX((CGFloat)cy, 0.05), 0.95) * h;
    label.center = CGPointMake(px, py);
}

static void bt_refreshTemp(id host) {
    UILabel *label = objc_getAssociatedObject(host, kLabelKey);
    if (!label) return;
    double c = bt_bs_temp_c();
    int64_t volt = bt_bs_int(@"Voltage");
    int64_t cyc  = bt_bs_int(@"CycleCount");
    NSMutableString *s = [NSMutableString stringWithFormat:@"电池温度: %.1f°C", c];
    if (volt > 0) [s appendFormat:@"   ·   电压 %.2fV", volt / 1000.0];
    if (cyc  > 0) [s appendFormat:@"   ·   循环 %lld", (long long)cyc];
    label.text = s;
    [label sizeToFit];
    bt_layOut(label, [host view]);   // 文字变宽/变窄后保持中心点不漂
}

static void bt_onDrag(UIPanGestureRecognizer *pan, UIViewController *vc) {
    UILabel *label = objc_getAssociatedObject(vc, kLabelKey);
    UIView *host = vc.view;
    if (!label || !host) return;
    CGPoint t = [pan translationInView:host];
    CGPoint c = CGPointMake(label.center.x + t.x, label.center.y + t.y);
    CGFloat w = MAX(host.bounds.size.width, 1);
    CGFloat h = MAX(host.bounds.size.height, 1);
    c.x = MIN(MAX(c.x, 0.05 * w), 0.95 * w);
    c.y = MIN(MAX(c.y, 0.05 * h), 0.95 * h);
    label.center = c;
    [pan setTranslation:CGPointZero inView:host];
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        btSetDouble(kCenterX, label.center.x / w);
        btSetDouble(kCenterY, label.center.y / h);
    }
}

static void bt_removeLabel(UIViewController *vc) {
    NSTimer *timer = objc_getAssociatedObject(vc, kTimerKey);
    UILabel *label  = objc_getAssociatedObject(vc, kLabelKey);
    if (timer) { [timer invalidate]; objc_setAssociatedObject(vc, kTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    if (label) { [label removeFromSuperview]; objc_setAssociatedObject(vc, kLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}

static void bt_ensureTempLabel(id self) {
    if (!btBool(kEnabled, YES)) return;          // 面板开关关闭 → 什么都不加
    UIViewController *vc = (UIViewController *)self;
    if (objc_getAssociatedObject(vc, kLabelKey)) return;

    UILabel *label = [[UILabel alloc] init];
    label.text = @"电池温度: 读取中…";
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];   // 深色半透明圆角底，拖动更醒目
    label.layer.cornerRadius = 8.0;
    label.layer.masksToBounds = YES;
    label.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    label.layer.borderWidth = 0.5;
    label.userInteractionEnabled = YES;
    [label sizeToFit];
    [vc.view addSubview:label];
    bt_layOut(label, vc.view);

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:vc action:@selector(btHandleDrag:)];
    [label addGestureRecognizer:pan];

    objc_setAssociatedObject(vc, kLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(vc, kTimerKey)) {
        __weak UIViewController *weakVC = vc;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t){
            if (weakVC) bt_refreshTemp(weakVC);
        }];
        objc_setAssociatedObject(vc, kTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    bt_refreshTemp(vc);
}

static void btApplyForVC(id self) {
    UIViewController *vc = (UIViewController *)self;
    if (btBool(kEnabled, YES)) bt_ensureTempLabel(vc);
    else bt_removeLabel(vc);
}

#pragma mark - Runtime 挂钩（替代 Logos %group：BatteryUIController 在 BatteryUsageUI.bundle 惰性加载，
// 必须等 bundle 加载后手动 swizzle。Logos 的 %init 不允许在 C 函数/GCD 块里调用，故用原生 runtime。）
static IMP bt_orig_viewDidLoad = NULL;
static void bt_viewDidLoad(id self, SEL _cmd) {
    if (bt_orig_viewDidLoad)
        ((void (*)(id, SEL))bt_orig_viewDidLoad)(self, _cmd);
    if (@available(iOS 13.0, *)) {
        bt_ensureTempLabel(self);
    }
}

static IMP bt_orig_viewWillAppear = NULL;
static void bt_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (bt_orig_viewWillAppear)
        ((void (*)(id, SEL, BOOL))bt_orig_viewWillAppear)(self, _cmd, animated);
    btApplyForVC(self);   // 每次进入页面：按开关增/删，位置读默认锚点或上次拖动结果
}

static void bt_handleDrag(id self, SEL _cmd, UIPanGestureRecognizer *pan) {
    bt_onDrag(pan, self);
}

static void bt_realHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("BatteryUIController");
        if (!cls) return;

        // %new：补上拖动手势方法（原类没有 → class_addMethod）
        class_addMethod(cls, sel_registerName("btHandleDrag:"), (IMP)bt_handleDrag, "v@:@");

        // 替换 viewDidLoad / viewWillAppear:
        Method m1 = class_getInstanceMethod(cls, @selector(viewDidLoad));
        if (m1) { bt_orig_viewDidLoad = method_getImplementation(m1); method_setImplementation(m1, (IMP)bt_viewDidLoad); }
        Method m2 = class_getInstanceMethod(cls, @selector(viewWillAppear:));
        if (m2) { bt_orig_viewWillAppear = method_getImplementation(m2); method_setImplementation(m2, (IMP)bt_viewWillAppear); }

        NSLog(@"[电池温度] 已挂钩 BatteryUIController (runtime swizzle)");
    });
}

static void btTryHook(void) {
    if (objc_getClass("BatteryUIController")) bt_realHook();
}

#pragma mark - 构造函数
static void btBundleLoaded(CFNotificationCenterRef __unused center,
                           void * __unused obs,
                           CFStringRef __unused name,
                           const void * __unused object,
                           CFDictionaryRef __unused userInfo) {
    btTryHook();
}

__attribute__((constructor))
static void btInit(void) {
    @autoreleasepool {
        // 1) BatteryUIController 在 BatteryUsageUI.bundle 惰性加载 → 监听它加载后再挂钩
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PreferenceBundles/BatteryUsageUI.bundle"];
        if (bundle) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                            btBundleLoaded, CFSTR("NSBundleDidLoadNotification"),
                                            (__bridge CFBundleRef)bundle,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        // 2) 兜底：延迟轮询几次（bundle 若已被缓存/别的 bundle 覆盖）
        for (int i = 1; i <= 5; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                btTryHook();
            });
        }
    }
    NSLog(@"[电池温度] dylib 已加载 (iOS16 / rootless / BatteryUIController)");
}