# 社区 PR 合并说明 / Merge notes

本分支把上游 [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock) 中尚未合并的 **15 个 PR**
合并到了本 fork（上游作者没有合并这些 PR，本仓库为他们提供一个可直接构建的版本）。

## 已合并的 PR

| 类别 | PR | 内容 |
| --- | --- | --- |
| 修复 | #185 | 修复 `apple-device-names` 脚本里 `parse_info()` 的变量引用错误 |
| 翻译 | #170 | 挪威语翻译改进 |
| 翻译 | #143 | 简体中文本地化校对润色 |
| 翻译 | #172 | 新增法语本地化 |
| 翻译 | #146 | 新增希伯来语、罗马尼亚语本地化 |
| 文档 | #188 | 新增繁体中文 README |
| 工具 | #132 | 新增 devcontainer 配置 |
| 功能 | #128 | 仅在连接外接显示器时解锁 |
| 功能 | #154 | 睡眠 RSSI：信号弱时先关屏（不锁屏） |
| 修复 | #167 | 修复设备列表出现重复设备名 |
| 功能 | #171 | 锁屏状态下也执行 event 脚本（可开关） |
| 功能 | #178 | 隐藏菜单栏图标（可开关） |
| 功能 | #181 | 重命名设备（自定义设备显示名） |
| 稳定性 | #186 | BLE 断线重连恢复 + RSSI 平滑决策 + 诊断日志 |
| 稳定性 | #189 | 蓝牙接近检测稳定化（多样本确认、RSSI 有效性过滤） |

## 未合并的 PR（及原因）

- **#183 / #184**：两个互相冲突的大重构（各 3500+ 行），与 #186/#189 的 RSSI 逻辑重叠，语义无法安全调和。
- **#179**：macOS 26 兼容 + 多设备支持（草稿），改动 4591 行且修改了 `.xib` 界面文件。
- **#187**：Telegram 告警（含拍照 + 定位，5374 行），属于较大的新功能，需要单独评估隐私与权限影响。
- **#192**：仅电池供电时自动锁定（草稿）。

需要以上任何一个时，可以单独再合并。

## 冲突解决说明（重点）

1. **`BLEUnlock/BLE.swift`（#186 + #189）**
   两个 PR 都在修同一类问题（单次 RSSI 尖峰导致误解锁），但机制不同。合并后的行为：
   - 「设备靠近」的判定有两个入口，任一生效即确认，避免任何一方单独失效导致无法解锁：
     - #189 的 `ProximityMonitor`：多样本确认（1.5 秒窗口内 2 个达标样本，主动模式下每 0.4 秒补采样）；
     - #186 的 `shouldUnlock`：滑动窗口样本数 ≥ `unlockMinSamples` 且平滑均值越过阈值。
   - 两条路径统一走新增的 `confirmPresence(estimatedRSSI:source:)`，日志里用 `source` 区分。
   - 保留 #186 的关键修正：确认靠近时**不再清空** `latestRSSIs`（清空会让下一个原始样本直接决定锁屏）。
   - 保留 #189 的状态门控（`ProximityRSSIGate`）、蓝牙关闭/不可用时的 `stopProximityMonitoring` 复位、以及 RSSI 有效性过滤。
2. **`AppDelegate.swift`（#154）**：#154 的「睡眠 RSSI」关屏分支与 #171 的「锁屏时也执行脚本」逻辑合并为同一分支，先判断关屏再判断锁定，两者都保留。
3. **中文 `zh-Hans.lproj/Localizable.strings`（#143 vs #171/#178/#154）**：以 #143 的校对版本为准，再补上各 PR 新增的键（`run_event_script_while_locked`、`hide_menu_bar_icon`、`sleep_rssi`）。
4. **`Info.plist` 的 `CFBundleVersion`**：各 PR 分支各自递增过，取较大值（847）。
5. **`project.pbxproj`**：新增语言、新增源文件、测试 target 的插入点冲突，均保留双方条目。

## 构建（无需 Xcode）

本机只装了 Command Line Tools（没有完整 Xcode），因此附带 `build-without-xcode.sh`：

```bash
./build-without-xcode.sh          # 产出 build/BLEUnlock.app
./build-without-xcode.sh --zip    # 同时打包 zip
```

- `BLEUnlock/*.swift`、`lowlevel.c`、所有 `.lproj` 文案、`Launcher/*.m` 全部从本仓库源码编译（universal：arm64 + x86_64）。
- 只有 Interface Builder 才能编译的界面资源（`MainMenu.nib`、`AboutBox.nib`、`Assets.car`、`AppIcon.icns`、Launcher 的 nib）取自官方 1.12.2 发行包，脚本会自动从 `/Applications/BLEUnlock.app` 或 GitHub Releases 获取并缓存到 `build/vendor/`。
- 因此：**如果某个 PR 改了 `.xib`／`.xcassets`，需要装完整 Xcode 用 `xcodebuild` 构建**（本分支合并的 15 个 PR 都没有改界面文件）。
- 签名为 ad-hoc（本地自用）。改动代码后重新构建会让「蓝牙」「辅助功能」等系统授权需要重新确认。

## 安装

```bash
# 1. 退出正在运行的 BLEUnlock（菜单栏图标 → Quit）
# 2. 替换 /Applications 里的旧版本
ditto build/BLEUnlock.app /Applications/BLEUnlock.app
# 3. 首次运行请重新授予蓝牙权限；若要自动输入密码解锁，还需在
#    系统设置 → 隐私与安全性 → 辅助功能 中勾选 BLEUnlock
```
