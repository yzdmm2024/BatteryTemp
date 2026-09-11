# ============ BatteryTemp：rootless 桌面状态栏电池温度显示 + 设置面板 ============
# 注入 com.apple.springboard：在状态栏电池图标正下方显示温度(/°C)/电压(V)，可调位置/字号。

TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# ===== Tweak 本体 =====
TWEAK_NAME = BatteryTemp
BatteryTemp_FILES = src/Tweak.xm
BatteryTemp_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -w
BatteryTemp_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics IOKit
BatteryTemp_LDFLAGS = -lnotify

# ===== 设置面板 PreferenceBundle =====
BUNDLE_NAME = BatteryTempPrefs
BatteryTempPrefs_FILES = Preferences/PSBatteryTempController.m
BatteryTempPrefs_INSTALL_PATH = /Library/PreferenceBundles
BatteryTempPrefs_FRAMEWORKS = UIKit Foundation
BatteryTempPrefs_PRIVATE_FRAMEWORKS = Preferences
BatteryTempPrefs_LDFLAGS = -F$(TARGET_PRIVATE_FRAMEWORK_PATH)
BatteryTempPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -w
BatteryTempPrefs_LDFLAGS += -lnotify

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"