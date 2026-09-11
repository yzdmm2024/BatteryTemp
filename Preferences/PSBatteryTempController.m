#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>

// 电池温度设置面板 — 纯代码布局，不依赖 PSStepperCell（部分 iOS 不识别会退成空行）。
// 开关用 UISwitch，四项调节用原生 UIStepper（自带 - / +），实时写入偏好并广播给 SpringBoard。

static NSString *const kDomain  = @"com.yzdmm.batterytemp";
static NSString *const kEnabled = @"enabled";
static NSString *const kChanged = @"com.yzdmm.batterytemp.changed";

static double btDouble(NSString *key, double def) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id v = [d objectForKey:key];
    return v ? [v doubleValue] : def;
}
static void btSetDouble(NSString *key, double val) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setDouble:val forKey:key];
    [d synchronize];
}
static BOOL btBool(NSString *key, BOOL def) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id v = [d objectForKey:key];
    return v ? [v boolValue] : def;
}
static void btSetBool(NSString *key, BOOL val) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setBool:val forKey:key];
    [d synchronize];
}
static void btNotify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.yzdmm.batterytemp.changed"),
                                         NULL, NULL, true);
}

@interface PSBatteryTempController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation PSBatteryTempController {
    UITableView *_table;
    NSArray *_steppers;   // 每项: {title,key,def,min,max,step}
    NSMutableDictionary *_stepperMap; // @(tag) -> key 字符串（UIStepper 根据 tag 定位 key）
    NSMutableArray *_steppersView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"电池温度";

    _steppers = @[
        @{@"title":@"温度 高度", @"key":@"vGap",     @"def":@8,  @"min":@0,  @"max":@40, @"step":@1},
        @{@"title":@"温度 左右", @"key":@"hOffset",  @"def":@0,  @"min":@-80,@"max":@80, @"step":@1},
        @{@"title":@"温度 上下", @"key":@"vOffset",  @"def":@0,  @"min":@-20,@"max":@80, @"step":@1},
        @{@"title":@"温度 大小", @"key":@"fontSize", @"def":@13, @"min":@8,  @"max":@40, @"step":@1},
    ];
    _stepperMap = [NSMutableDictionary dictionary];
    for (int i = 0; i < _steppers.count; i++) {
        _stepperMap[@(i + 1)] = _steppers[i][@"key"];
    }

    CGRect b = self.view.bounds;
    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height)
                                          style:UITableViewStyleGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
}

#pragma mark - 兼容：Preferences 可能以不同方式实例化

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    return [super init];
}
- (void)setSpecifier:(PSSpecifier *)specifier {}
- (void)setParentController:(UIViewController *)parentController {}

#pragma mark - 事件

- (void)enabledChanged:(UISwitch *)sw {
    btSetBool(kEnabled, sw.on);
    btNotify();
}

- (void)stepChanged:(UIStepper *)st {
    NSString *key = _stepperMap[@(st.tag)];
    if (!key) return;
    btSetDouble(key, st.value);
    // 刷新该行文字，显示最新数值
    for (int i = 0; i < _steppers.count; i++) {
        if ([_steppers[i][@"key"] isEqualToString:key]) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:1];
            UITableViewCell *cell = [_table cellForRowAtIndexPath:ip];
            cell.textLabel.text = [NSString stringWithFormat:@"%@  %@",
                                   _steppers[i][@"title"], @(st.value)];
            break;
        }
    }
    btNotify();
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : _steppers.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"在桌面/锁屏状态栏的电池图标正下方，实时显示电池温度（°C）与电压（V），每 2 秒刷新。换过电池、系统隐藏温度时也能看真实读数。";
    return @"改动即时生效，回到桌面即可看到效果。用 - / + 微调显示高度、左右、上下与大小。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"sw"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"sw"];
        c.textLabel.text = @"启用温度显示";
        c.accessoryView = nil;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = btBool(kEnabled, YES);
        [sw addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    NSInteger row = indexPath.row;
    NSDictionary *conf = _steppers[row];
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"st"];
    if (c) c.accessoryView = nil;
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"st"];

    double val = btDouble(conf[@"key"], [conf[@"def"] doubleValue]);

    UIStepper *st = (UIStepper *)c.accessoryView;
    if (!st) {
        st = [[UIStepper alloc] init];
        [st addTarget:self action:@selector(stepChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = st;
    }
    st.tag = row + 1;
    st.minimumValue = [conf[@"min"] doubleValue];
    st.maximumValue = [conf[@"max"] doubleValue];
    st.stepValue = [conf[@"step"] doubleValue];
    st.value = val;
    c.textLabel.text = [NSString stringWithFormat:@"%@  %@", conf[@"title"], @(val)];
    return c;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_table reloadData];
}

@end