# ============ BatteryTemp：rootless 电池温度显示 + 设置面板 ============
# iOS 16「设置 → 电池」：在电池图标下方/页面底部实时显示温度/电压/循环，标签可拖动。
# 注入 com.apple.Preferences（BatteryUsageUI.bundle 加载后才 %init 挂钩）。

TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

# ===== Tweak 本体 =====
TWEAK_NAME = BatteryTemp
BatteryTemp_FILES = src/Tweak.xm
BatteryTemp_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -w
BatteryTemp_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
BatteryTemp_LDFLAGS_THEOS = -undefined,dynamic_lookup

# ===== 设置面板 PreferenceBundle =====
BUNDLE_NAME = BatteryTempPrefs
BatteryTempPrefs_FILES = Preferences/PSBatteryTempController.m
BatteryTempPrefs_INSTALL_PATH = /Library/PreferenceBundles
BatteryTempPrefs_FRAMEWORKS = UIKit Foundation
BatteryTempPrefs_PRIVATE_FRAMEWORKS = Preferences
BatteryTempPrefs_LDFLAGS = -F$(TARGET_PRIVATE_FRAMEWORK_PATH)
BatteryTempPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -w

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"