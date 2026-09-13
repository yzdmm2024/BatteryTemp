#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>

// 电池温度设置面板 —— 无状态栏浮层，纯面板内显示。
// 点开本面板 → 发 Darwin 通知让插件（SpringBoard）开始读数；
// 退出本面板 / 设置 App 退后台 → 发通知让插件停止读数（静默、不耗电）。
// 数据由插件写入共享 plist，本面板每 1 秒读取刷新。

// 与 Tweak.xm 里 bt_livePath() 保持一致
static NSString *bt_livePath(void) {
    return @"/var/mobile/Library/Preferences/com.yzdmm.batterytemp.live.plist";
}

static void btPost(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, true);
}

@interface PSBatteryTempController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation PSBatteryTempController {
    UITableView *_table;
    NSTimer *_timer;
    NSDictionary *_live;   // 最近一次读取的实时数据
    BOOL _observing;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"电池温度";

    CGRect b = self.view.bounds;
    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height)
                                          style:UITableViewStyleGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];

    // 设置 App 退后台也静默：停止读数；回到前台且本面板仍可见则恢复
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(appDidEnterBackground)
               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(appWillEnterForeground)
               name:UIApplicationWillEnterForegroundNotification object:nil];
    _observing = YES;
}

- (void)dealloc {
    if (_observing) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        _observing = NO;
    }
    btPost(@"com.yzdmm.batterytemp.close");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    btPost(@"com.yzdmm.batterytemp.open");           // 让插件开始读
    [_table reloadData];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t){
        [self refreshLive];
    }];
    [self refreshLive];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    btPost(@"com.yzdmm.batterytemp.close");          // 让插件停止读（静默）
    [_timer invalidate]; _timer = nil;
}

- (void)appDidEnterBackground {
    btPost(@"com.yzdmm.batterytemp.close");
    [_timer invalidate]; _timer = nil;
}
- (void)appWillEnterForeground {
    if (self.isViewLoaded && self.view.window) {
        btPost(@"com.yzdmm.batterytemp.open");
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t){
            [self refreshLive];
        }];
        [self refreshLive];
    }
}

- (void)refreshLive {
    _live = [NSDictionary dictionaryWithContentsOfFile:bt_livePath()];
    if ([_table numberOfSections] > 0) {
        [_table reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    }
}

#pragma mark - 数据源
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 4; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"数据来自电池管理芯片 AppleSmartBattery，是真实硬件读数（非估算、非假）。点开本面板才开始读取，退出即停止，不后台耗电。电池温度在空闲时长时间不变属正常；充电或运行大型 App 时会明显上升。电流正号=放电、负号=充电、0=空闲。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *titles = @[@"电池温度", @"电池电压", @"电池电流", @"充电循环"];
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"lv"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"lv"];
    c.textLabel.text = titles[indexPath.row];
    c.detailTextLabel.text = [self valueForRow:indexPath.row];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.row == 0) {
        c.detailTextLabel.font = [UIFont boldSystemFontOfSize:20];
    }
    return c;
}

- (NSString *)valueForRow:(NSInteger)row {
    if (!_live) return @"读取中…";
    if (row == 0) {
        double t = [_live[@"temperatureC"] doubleValue];
        return (t >= 0) ? [NSString stringWithFormat:@"%.1f °C", t] : @"--";
    } else if (row == 1) {
        double v = [_live[@"voltageV"] doubleValue];
        return (v >= 0) ? [NSString stringWithFormat:@"%.3f V", v] : @"--";
    } else if (row == 2) {
        long long cur = [_live[@"currentMA"] longLongValue];
        if (cur > 0)  return [NSString stringWithFormat:@"+%lld mA（放电）", cur];
        if (cur < 0)  return [NSString stringWithFormat:@"%lld mA（充电）", -cur];
        return @"0 mA（空闲）";
    } else {
        long long cyc = [_live[@"cycle"] longLongValue];
        return (cyc > 0) ? [NSString stringWithFormat:@"%lld 次", cyc] : @"--";
    }
}

#pragma mark - 兼容：Preferences 可能以不同方式实例化
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier { return [super init]; }
- (void)setSpecifier:(PSSpecifier *)specifier {}
- (void)setParentController:(UIViewController *)parentController {}

@end
