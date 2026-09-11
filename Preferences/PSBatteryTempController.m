#import <Preferences/Preferences.h>
#import <notify.h>

// 设置面板主控制器：iOS 设置 → 电池温度
// 任何偏好值变化（开关 / -+ 调节四项）都立即广播通知 SpringBoard 里的 dylib 实时更新。
@interface PSBatteryTempController : PSListController
@end

@implementation PSBatteryTempController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    notify_post("com.yzdmm.batterytemp.changed");
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    notify_post("com.yzdmm.batterytemp.changed");
}

@end