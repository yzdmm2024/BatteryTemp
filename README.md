# BatteryTemp — 电池温度显示插件

在 **「设置 → 电池」** 详情页底部固定显示一行实时数据：
**电池温度（°C）· 电压（V）· 循环次数**，每 3 秒刷新一次。
换第三方电池后系统隐藏了温度，这个插件直接从 IOKit 读真实硬件数据。

- 数据来源：IOKit 注册表 `AppleSmartBattery` 的 `Temperature`（0.1K 单位）/ `Voltage` / `CycleCount`
- 实测机型：iPhone 12 Pro / iOS 16.6 / relaxin rootless（已 frida 验证读数真实）
- 注入目标：`com.apple.Preferences`（设置 App）

## 本机制作（Windows 一键，推荐）

> 依赖桌面工具包「本机制造插件的必备东西」

```bash
bash "BatteryTempTweak/build_local.sh" "BatteryTempTweak" no
```

产物在 `BatteryTempTweak/输出成品/`：
- `BatteryTempTweak.dylib`（已 adhoc 签名）
- `BatteryTempTweak_v1.0.0_iphoneos-arm64.deb`

> 第二个参数 `no` = 只出 dylib + deb，跳过 TrollStore IPA（本插件是系统级 tweak，不需要 IPA 载体）。

## 安装到手机（rootless / relaxin）

- 用 Sileo / Zebra 打开 `.deb` 安装，或 `dpkg -i`；
- 装完会自动 `killall SpringBoard`（respring）；
- 打开 **设置 → 电池**，滚到页面底部即可看到温度行。

## 卸载

Sileo/Zebra 里删除 `com.yzdmm.batterytemp`，或 `dpkg -r com.yzdmm.batterytemp`，再 respring。

## 兜底：GitHub CI 出 deb

仓库根提供 `.github/workflows/build.yml`（theos + macOS runner）。
推送后到 Actions 下载 `BatteryTemp-deb` 产物即可。本地 lld 18 对复杂工程
出的 dyld 绑定信息有缺陷，单文件小插件（本工程）本机可编；若装上异常请改用 CI 产物。
