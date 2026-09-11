#import <Preferences/Preferences.h>

// 设置面板主控制器：iOS 设置 → 电池温度
// 关键：必须重写 specifiers 去读 Root.plist，否则面板空白。
@interface PSBatteryTempController : PSListController
@end

@implementation PSBatteryTempController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// “重置到电池正下方”：清掉拖动保存的位置，回到默认锚点
- (void)resetPosition {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yzdmm.batterytemp"];
    [d removeObjectForKey:@"centerX"];
    [d removeObjectForKey:@"centerY"];
    [d synchronize];
}

@end