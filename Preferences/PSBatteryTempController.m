#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>

// 设置面板主控制器：iOS 设置 → 电池温度
// 任何偏好值变化（开关 / -+ 调节四项）都立即通过 Darwin 通知广播给 SpringBoard 里的 dylib 实时更新。
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
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.yzdmm.batterytemp.changed"),
                                         NULL, NULL, true);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.yzdmm.batterytemp.changed"),
                                         NULL, NULL, true);
}

@end