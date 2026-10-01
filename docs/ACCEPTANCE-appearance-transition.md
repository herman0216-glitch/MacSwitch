# 深色模式过渡验收 — 2026-09-18

## 当前实现（2026-09-19）

用户要求固定原生方案且不再使用 System Events。应用现仅使用 SkyLight 原生外观接口切换深浅色；已删除 System Events 控制、AppleScript、Apple Events 自动化权限声明和设置页中的授权入口。读取系统外观仍使用只读的系统偏好。允许 build `26A428`，并于 2026-09-30 按用户要求加入当前 macOS 27.0.1 build `26A434`；后端仍检查 Objective-C 方法编码及所需符号，其他 build 或接口不匹配时显示不可用。`26A434` 的真实外观切换验收为 `NOT RUN`，本次仅解除版本禁用。

回调超时或执行异常时先回读系统真实状态：目标已实现则结束操作，不重复切换；目标未实现则显示错误并停用该会话的原生后端。开启“减少动态效果”时仍使用原生 setter，但省略过渡动画。旧版的本机 opt-in 偏好不再参与决策。

验证：`./script/test.sh` 最终结果为 **102 项测试通过、103 次执行、0 失败/跳过**，结果包 `build/TestResults-20260919-142730.xcresult`。`./script/build_and_run.sh --telemetry` 构建并启动项目 `dist/MacSwitch.app` 后，设置页显示新的原生接口说明；应用菜单由浅到深、再恢复浅色，两次均收到 `Native appearance transition completed` 日志并回读成功。`codesign --verify --deep --strict` 通过，构建后的 Info.plist 不含 `NSAppleEventsUsageDescription`，签名权限不含 Apple Events 自动化项；源代码和独立探针均无 System Events/AppleScript 调用。外接屏、更多应用、实体快捷键和真实“减少动态效果”场景仍由用户后续验证。

下面保留 2026-09-18 的原生与旧方案对照、首次试用和当时的验证记录，属于历史证据；其中提到的回退方式、权限申请和 `legacy` 探针命令不适用于当前实现。

## 历史试用结论与启用状态

已实现即时目标反馈、固定宽度进度指示、可替换的原生候选后端、异常回读与回退、超时/取消/退出清理和迟到回调隔离。原有未提交修改（移除成功勾号）保留，`SwitchService` 接口不变。

**已按用户追加授权在本机启用原生过渡试用；通用发布仍默认关闭。** 用户明确表示“效果好的那一方案可以先在这一台电脑上启动，后续测试我会自行进行”，因此本地试用不再等待剩余实机验收。采用当前用户、当前主机专属偏好 `NativeAppearanceTransitionLocalBuild=26A428`，仅匹配本机当前 ABI 探测版本；系统升级、减少动态效果或接口不可用时回退到 System Events。外接屏、控制中心等后续验收由用户自行完成，不将其记为已通过。没有新增权限、截图遮罩、速度设置、自动外观策略修改或人为动画等待。

执行依据：[原始计划副本](PLAN-appearance-transition.md)；源文件为 `/Users/herman/Downloads/PLAN.md`。

## 环境和接口核对

- Apple Silicon MacBook Air；macOS 27.0 **26A428**；Xcode 27.0 **27A266a**。
- 本轮仅检测到 `Built-in Retina Display`；“减少动态效果”为关闭。
- 初始浅色，`AppleInterfaceStyleSwitchesAutomatically` 不存在；原生与旧方案实验均报告 `restored=true automaticUnchanged=true`，最终系统探针也回读为浅色。
- [参考源码](https://gist.github.com/avaidyam/6d0e3605cf85b10f4d0f9d654518e984) 使用的 `waitForTransitionWithCompletionHandler:` 在本机缺失，没有调用该方法。
- 实测 `transition` 编码为 `@16@0:8`，`postChangeNotification:completionHandler:` 为 `v32@0:8Q16@?24`。SkyLight 的 `SLSGetAppearanceThemeLegacy` 和 `SLSSetAppearanceThemeNotifying` 存在。符号存在不等于兼容性通过。
- 当前候选使用 `postChangeNotification:completionHandler:` 回调。Swift 函数指针中的 block 必须声明 `@escaping`；初版探针遗漏这一声明触发运行时 trap，随后恢复浅色并修正。该失败未作为成功样本。
- 单纯 Swift async 命令行循环下，20 次回读成功但回调全部超时；改为完整 `NSApplication.run()` 事件循环后，20 次回调均成功。保留这个差异，避免把探针运行方式误判为系统接口不工作。

## 双向测量

独立原生探针、旧方案各执行 20 次，深浅方向各 10 次。单位毫秒；“首次”是该方向的第一次，“后续”是该方向余下 9 次的中位数。第二方向不是进程冷启动。

| 方案 / 方向 | 首次调用返回 | 后续调用返回 | 首次状态回读 | 后续状态回读 | 首次完成信号 | 后续完成信号 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 原生 → 深色 | 28.46 | 26.78 | 28.96 | 27.55 | 344.74 | 362.82 |
| 原生 → 浅色 | 27.05 | 25.40 | 27.54 | 26.27 | 370.17 | 363.46 |
| 旧方案 → 深色 | 56.28 | 8.11 | 57.65 | 8.13 | 56.28 | 8.11 |
| 旧方案 → 浅色 | 6.65 | 7.29 | 6.68 | 7.37 | 6.65 | 7.29 |

原生“完成信号”为私有接口回调，旧方案为 AppleScript 返回。**这些不是同一种完成语义，也不是屏幕动画结束时刻，不能据此断言原生更快或更慢。** 旧方案使用与应用相同的 System Events 命令；探针预先启动 System Events 并以不弹窗方式检查权限，表格不含应用冷启动、菜单点击、启动 System Events 和授权等待，不能代表完整点击延迟。每次样本后的 750ms 间隔仅用于隔离测量，没有加入应用实现。

可见过渡的开始/结束时间没有获得可靠测量。控制中心 CUA 连接两次返回 `timeoutReached`，无法完成对照。原始数据：[原生](evidence/appearance-transition/native-26A428.log)、[旧方案](evidence/appearance-transition/legacy-26A428.log)。

用户反馈原文：“刚刚那一轮过度的很快，但是上一组效果很好”。按执行顺序理解，“刚刚”对应旧方案，“上一组”对应完整 AppKit 循环的原生方案；这是定性观感反馈，不等于无闪屏/残留、双屏或不慢于控制中心的逐项确认。

## 行为和故障覆盖

- `FeatureState.pendingTarget` 单独驱动外观开关，不覆盖系统快照；点击在入队时立即更新，失败后回读恢复。其他开关保持确认后显示。
- 深色模式允许连续点击，仍串行执行；通知刷新不会覆盖待执行意图。待执行队列完成或退出时清理目标。
- 候选后端使用独立操作 token，回调、2 秒超时、取消、退出只允许一个完成路径；重复或迟到回调不能完成下一次请求。
- 原生失败后先回读，部分成功不重复切换；未成功才走 System Events，并重新检查自动化权限。原生异常后本会话禁用该后端。
- “减少动态效果”在后端可用性和系统调用前检查；开启时回退。UI 同样尊重该设置。
- 私有接口的未知 ABI、Objective-C 异常或系统服务行为仍有维护风险，Swift 错误处理不能捕获所有进程级崩溃。通用发布默认关闭，本机试用仅匹配明确授权的已探测系统 build，不能承诺任意未来系统兼容。

## 自动化和实机边界

最终验证：

- `./script/test.sh`：**109 项测试通过，111 次执行，0 失败，0 跳过**（2 项动态参数测试共 4 次执行）。以 `xcresulttool` 汇总为准；Swift Testing 控制台单独显示 102 项，不包含其余 XCTest 项。
- 结果包：`build/TestResults-20260918-210752.xcresult`。无 Swift 编译警告；工具链仅提示未依赖 AppIntents 因而跳过元数据提取。
- `./script/build_and_run.sh --verify`：构建并启动 `dist/MacSwitch.app` 成功。
- `codesign --verify --deep --strict --verbose=2 dist/MacSwitch.app`：完整性校验通过。
- `./script/verify_system.sh read`：重新编译成功，外观回读浅色；`git diff --check` 通过。

自动测试覆盖：即时反馈和真实快照分离、连续操作串行、失败恢复、刷新与目标共存、权限拒绝/撤销、缺失或不可用后端、原生回调成功但未改变状态、部分成功、超时回退、不阻塞后续请求、重复/迟到回调、同步回调、启动异常、取消、退出和减少动态效果分支。权限与故障注入均为测试替身，没有撤销用户真实权限。

实机完成：原生和旧方案深浅各 10 次、恢复原外观与自动策略检查；新开发应用从“开关 → 深色模式”菜单切换并恢复，CUA 截图显示设置窗口确实随系统切换深浅色。独立探针不请求屏幕录制，也不申请新自动化权限。

用户后续自行验收：外接屏、菜单栏与 Finder 的逐项观感、更多跟随系统的应用、实体快捷键、物理快速点击、真实权限拒绝、真实减少动态效果、过渡中实际退出、明确无闪屏/残留/额外弹窗确认，以及控制中心点击到可见开始/结束的对照。面板固定布局和即时动画有代码与状态测试证据，本轮未获得菜单栏弹出面板的可视验收。

## 复现

```sh
./script/verify_appearance_transition.sh         # 只读检查
./script/verify_appearance_transition.sh native  # 20 次切换，需观察屏幕
./script/test.sh
./script/build_and_run.sh --verify
./script/verify_system.sh read
```

独立探针仅允许已核对 ABI 的 `26A428`，不会改写应用启用配置。切换前将原始状态写入 `build/probes/appearance-original.json`；正常结束和 Swift 错误恢复外观，强制终止/崩溃时不能依赖 `defer`，需按该文件通过系统设置恢复。不要在实验过程中手动修改外观，否则自动恢复会覆盖同时发生的修改。

## 历史本机试用配置（当前版本已停用）

2026-09-18 的临时试用曾设置：

```sh
defaults -currentHost write local.herman.MacSwitch NativeAppearanceTransitionLocalBuild -string 26A428
```

配置存放在当前用户的 ByHost 偏好中，不写入应用包。复制应用到其他电脑不会携带此配置；系统升级到其他 build 也不会启用原生候选。撤销试用可删除此键并重启应用：

```sh
defaults -currentHost delete local.herman.MacSwitch NativeAppearanceTransitionLocalBuild
```

故障回退、超时、迟到回调防护和减少动态效果检查继续保留。

本机启用后的复核（2026-09-18）：

- 重新运行完整测试：`build/TestResults-20260918-211145.xcresult`，109 项通过、111 次执行、0 失败、0 跳过；新增启用策略测试覆盖未授权、精确匹配、系统升级和未知 build。
- 使用 `./script/build_and_run.sh --telemetry` 构建并启动 `dist/MacSwitch.app`；应用日志确认 `Native appearance enabled for local trial, build=26A428`。
- 通过应用菜单实际切换到深色并恢复浅色，CUA 截图确认窗口外观变化。21:12:44.077 开始原生切换，21:12:44.500 收到完成回调，系统回读深色成功；21:12:53.485 开始恢复，21:12:53.883 回调完成，系统回读浅色成功。没有触发超时回退。这些时间仍不是可见动画起止的测量。
- `codesign --verify --deep --strict dist/MacSwitch.app` 和 `git diff --check` 通过。停止日志监视后应用继续运行。
- 当前试用启动的是项目 `dist/MacSwitch.app`；未替换 `/Applications/MacSwitch.app` 或已发布安装包。
