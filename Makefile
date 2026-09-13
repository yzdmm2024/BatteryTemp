# ============ BatteryTemp：rootless 电池芯片真实温度/电压，面板内实时显示 ============
# 仅注入 com.apple.springboard：读取 AppleSmartBattery 真实温度/电压/电流/循环，写入共享 plist，
# 供「设置 → 电池温度」面板（独立进程）读取并实时显示。不再在状态栏绘制浮层。

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