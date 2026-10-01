# 系统桌面隐藏验收记录

## 实现边界

- 普通桌面写入 `com.apple.WindowManager/StandardHideDesktopIcons`，台前调度写入 `com.apple.WindowManager/HideDesktop`。
- 开启时两项均写为 `true`，关闭时两项均写为 `false`。两个值均为 `true` 时开关开启；只有一项为 `true` 时开关关闭并显示“部分模式已隐藏”。
- 每次操作保存两个键各自的原值及缺省状态；写入失败或读回不一致时逐项恢复，恢复失败会报告读回的实际状态。
- 2026-09-30 用户反馈系统偏好在点击墙纸或台前调度收起窗口时临时显示图标，并选择“文件隐藏标记”方案：开启时额外为 `~/Desktop` 顶层可见项目设置 `UF_HIDDEN`（先写记录再写标记，失败回滚本次标记及偏好），监听目录为新项目补设；关闭时只清除记录内项目，找不到路径时用书签定位。此项取代下文“不以文件隐藏替代”的原边界。
- 不修改 `GloballyEnabled`、`EnableStandardClickToShowDesktop`、小组件偏好、窗口布局或桌面文件；不以重启 Finder、重启 Dock、关闭台前调度或 `CreateDesktop=false` 补救。
- 检测到遗留 `com.apple.finder/CreateDesktop=false` 时阻止写入并提示手动恢复。未列入验证清单的系统 build 显示暂不支持，并提供“桌面与程序坞”设置入口。
- 当前放行 `26A428` 及用户于 2026-09-30 明确要求解除禁用的 macOS 27.0.1 build `26A434`；其他 build 仍显示暂不支持。`26A434` 的真实桌面交互验收为 `NOT RUN`，放行不代表验收通过。该开关仍使用既有 WindowManager 后端；独立 SkyLight 跨进程方案未接入。Debug 的 `--desktop-probe` 专项写入仍限定原候选 `26A428`。

## 自动验证

2026-09-30：`./script/test.sh` 通过，Swift Testing 129 项、14 个套件，0 失败。新增文件隐藏专项：只隐藏原本可见项目并精确恢复、重复开启不重复记录、第 N 项失败回滚、改名后按书签恢复、已删除项目丢弃与恢复失败保留、监听只在开启期间补隐藏、隐藏失败回滚偏好、重启后按记录恢复监听、仅偏好隐藏时显示为临时隐藏、Finder 显示隐藏文件提示。真实桌面上的持续隐藏交互为 `NOT RUN`。

2026-09-29：`./script/test.sh` 通过。Swift Testing 共 118 项、13 个套件，另有 7 项 XCTest，均为 0 失败。桌面专项覆盖：开启/关闭、重复操作、部分隐藏、偏好缺省、部分写入失败、读回不一致、回滚失败、外部变化、旧版遗留及未验证 build。

## macOS 27.0（26A428）实机矩阵

`26A428` 已恢复 WindowManager 原生路径并移除会破坏桌面点击的 `CreateDesktop=false`；下面未完成的交互项仍需继续实机复核。

| 项目 | 结果 | 证据边界 |
| --- | --- | --- |
| 开启、关闭与原生临时显示 | 已恢复，待复核 | 偏好读回成功；需继续观察图标显隐和应用窗口返回。 |
| 网页窗口进入台前调度左侧 | 已恢复，待复核 | 已移除阻断桌面点击的 Finder 后端；仍需真实点击确认。 |
| 桌面右键、文件拖放、Finder 窗口与复制 | 待验收 | 不以偏好读回替代。 |
| 小组件、Mission Control、空间切换 | 待验收 | 不修改相关系统偏好。 |
| 多显示器 | 待验收 | 当前连接的每个显示器都要检查。 |
| 睡眠与唤醒 | 待验收 | 唤醒后由定期同步回读状态。 |
| Finder、Dock 进程连续性 | 通过（偏好写入层） | 双偏好开启、恢复前后 Finder PID 均为 42074，Dock PID 均为 1643；没有重启。 |
| 桌面文件原样保留 | 待验收 | 不创建、移动或删除用户文件。 |

偏好读回和自动测试仅证明实现状态机与写入结果，不能替代上述真实交互验收。

2026-09-29 修复时检测到上一版遗留 `CreateDesktop=false`、`StandardHideDesktopIcons=false`、`HideDesktop=false`。已迁移为 `CreateDesktop=true`、两个 WindowManager 隐藏值均为 `true`，并刷新 Finder；台前调度 `GloballyEnabled=true`、点击墙纸 `EnableStandardClickToShowDesktop=false` 未修改。
