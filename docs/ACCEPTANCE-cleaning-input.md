# 清洁模式输入保护验收

开发与首轮实测：2026-09-28；最终自动化复验：2026-09-29。依据用户指定的 `/Users/herman/Downloads/清洁模式优化.md`。

## 当前结论

**`26A428` 首轮真实触控板验证通过；尚未完成全部补充手势、多屏及恢复验收。** 2026-09-29 用户明确授权放行 `26A428`；2026-09-30 用户要求解除升级后禁用，另将当前 macOS 27.0.1 build `26A434` 加入 `CleaningCompatibility.verifiedBuilds`。两者均可通过正常菜单开关继续使用和测试；`26A434` 的真实手势与恢复验收为 `NOT RUN`，不继承旧 build 的实机结论。触发角保护与辅助功能权限检查仍保留，其他 build 仍保持关闭。Debug 限时原型仍限定原候选 `26A428`。

本轮保留工作区已有外观切换、图标等未提交修改；不修改触控板偏好，不重启 Dock，不安装驱动，不执行配置迁移。

用户随后明确要求“先把开发部分完成，后续我会自行测试”。本次交付范围据此调整为：完成实现、自动化回归、Debug/Release 构建及可自行运行的限时验证入口。剩余实机矩阵由用户后续完成，不继续要求现场测试，不将未测项目或本次开发完成解释为正式开放许可。

## 环境与实现

- 本机：MacBook Air / arm64，macOS 27.0（26A428），Xcode 27.0（27A266a）。当前资源探针只看到内置屏幕 1470 × 956 逻辑点；不能据此声明外接屏幕验收通过。
- 保留 HID 层键盘及媒体键拦截；新增独立 session/head/default 主动 tap，请求全事件掩码，仅放行普通指针移动。启动和健康检查按 tap ID、所属进程、位置、选项及必需事件位核验两条保护，任一失效退出。
- 私有 CGS 手势 29 / DockControl 30 / 真实类型字段 55 只位于兼容层；不把 NSEvent 的手势编号当作 CGEvent 编号，不合成手势，也不改写私有序列。
- 全局吞掉左键 down/up，记录显示器标识和退出按钮几何区域；同一按钮内完成按下/松开才异步退出。拖出后返回、拖入、跨屏按下/松开、重建显示器期间点击都取消。
- 使用主坐标屏幕 `NSScreen.screens[0]` 的上边界做 AppKit → Quartz 转换，单位为逻辑点，兼容负坐标和显示器上下排列；不使用随焦点变化的 `NSScreen.main`。
- 保存原 presentation options，清洁时使用 hideDock / hideMenuBar / disableScreenCornerInteractions，退出原样恢复。失去前台、检测到 Space 变化、睡眠、权限或 tap 健康失效均结束会话；唤醒后不自动重开。
- 服务及窗口后端使用会话 token，旧异步启动不能提交或清理后来的会话；合法退出等待回调期间仍保留有效健康状态。

## 已执行的自动验证

| 项目 | 结果与证据 | 能证明的范围 |
|---|---|---|
| 完整现有测试 + 新增回归 | PASS；最终 `build/TestResults-20260929-132436.xcresult`，Swift Testing 112 项；xcresult 汇总 119 项、121 次设备执行、0 失败、0 跳过 | 包含 XCTest 与参数化执行；摘要已保存 `final-test-summary-20260929.json` |
| 输入决策 | PASS；`CleaningInputTests.swift` | 0–63 事件白名单、同按钮完整点击、拖入/拖出、跨屏、重复 up、几何变化取消 |
| 坐标转换 | PASS | 主屏、左上及下方屏幕逻辑点；不是外接硬件证据 |
| 双 tap 回滚/超时 | PASS（fake taps） | 第二 tap 建立失败会回收第一 tap，重复 stop 安全，陈旧失败不会结束新会话 |
| 快捷键和启动事务 | PASS（fake backends） | 未验收版本不启动；启动失败、退出、shutdown 恢复快捷键；关闭再开启交错及重复开启 |
| 独立原型 watchdog | PASS；`build/cleaning-input/watchdog-tests.json` | 对隔离子进程加速验证取消、SIGTERM、忽略 TERM 后 SIGKILL；不是清洁遮罩实机恢复证明 |
| Debug 构建及启动 | PASS；`build/logs/cleaning-build-run.log` | `script/build_and_run.sh --verify`，产物 `dist/MacSwitch.app`；最终交付启动普通版本，不自动开启清洁模式 |
| 本地签名完整性 | PASS；`codesign --verify --deep --strict` | 仅 ad-hoc 完整性，非 Developer ID 或公证 |
| 原型启动 | PASS | 已观察到“MacSwitch 清洁模式限时验证”窗口；未点击开始时，无输入 tap、无遮罩 |
| Release 构建 | PASS | 独立目录 `build/CleaningRelease`，日志 `build/logs/cleaning-release-build.log`；存在既有 `VolumePanel.swift:76` Sendable 警告及 AppIntents 元数据提示，非清洁代码编译错误 |
| 权限拒绝后的实机回滚 | PASS | 原型前两轮因辅助功能权限未获认可而拒绝启动；`resources-after-denied.json` 确認无 tap、无遮罩，独立 watchdog 子进程已结束，presentation 为 0 |

## 真机验收矩阵

首轮（原型第 3 次尝试，20:52:04–20:52:13）进入成功。用户明确反馈：“已测试：均被阻止，中央按钮正常退出，原桌面与应用未变。” 对应问题覆盖四指左右切桌面、上滑调度中心、显示桌面、滚动/缩放、边缘与触发角。记录显示输入健康为 true，presentation 32778，退出恢复为 0；事件计数为 29:582、30:103、14:8、mouseMoved:272，Space 变化通知为 0。行为通过依据是用户观察，计数只辅助核对确实进入原型。

该轮进入前前台是 MacSwitch 自身，因此恢复其他应用焦点仍需补验。只读查询显示右下触发角值为 14，其他三角未设置；不把未设置的三角认定为经过动作阻断测试。原始证据保存在 [`evidence/cleaning-input-20260928/`](evidence/cleaning-input-20260928/)，原型 JSON 的人工验收字段保留原始 NOT RUN；本节记录后续用户反馈，不改写原始日志。

以下各项必须记录操作者实际观察，不能用单元测试、合成输入或遮罩仍存在替代。`NOT RUN` 表示尚无有效证据，不等于通过。

| 验收项 | 状态 |
|---|---|
| 真实单指/普通鼠标移动 | NOT RUN |
| 中央按钮内点击退出，退出点击不穿透 | 按钮退出 PASS（用户确认）；底层点击无穿透仍需专项观察 |
| 按钮外点击、右键、拖入、拖出、拖出再返回不退出 | NOT RUN |
| 双指滚动、缩放、旋转、智能缩放 | 滚动/缩放 PASS（用户确认）；旋转/智能缩放待补验 |
| 三/四指左右切桌面，无动画、露出或后台 Space 改变 | 四指 PASS（用户确认）；其他已配置指法待补验 |
| 调度中心、应用窗口、显示桌面 | 调度中心/显示桌面 PASS（用户确认）；应用窗口待补验 |
| 屏幕边缘、触发角 | 用户确认本轮边缘/触发角未打开系统界面；右下已有配置，其他三角未设置 |
| 键盘、修饰键、媒体键 | NOT RUN（本轮） |
| 退出后仍在原桌面/原应用，Dock 与菜单栏恢复 | 原桌面/原应用 PASS（用户确认，本轮为 MacSwitch）；presentation 原值恢复 PASS；外部应用焦点待补验 |
| 内外屏分别退出，真实拔插显示器后覆盖与按钮坐标正确 | NOT RUN；当前未连接外屏 |
| 快速开关、手势进行中开启 | NOT RUN（真实输入） |
| 真实睡眠/唤醒，不自动重开，无残留 | NOT RUN |
| 权限撤销、真实拦截超时、失去前台 | NOT RUN（真实系统） |
| 限时自动退出、强制结束后输入及屏幕恢复 | NOT RUN（真实清洁会话） |

## 复验步骤

运行 `./script/verify_cleaning_input.sh` 构建并打开原型。它不立即黑屏；用户点击开始后留 5 秒准备时间，可切回原来的应用。会话 45 秒自动退出；独立 Bash 子进程在 55 秒超时后先 TERM、再 KILL，发信号前核对父子关系。正常退出取消该子进程。

该入口适合尚未加入支持名单的构建进行限时测试；`26A428` 已可使用正常清洁开关继续验收。需要暂时停止测试时可直接关闭原型窗口。若独立兜底进程意外结束，原型主动取消会话。重新构建的本地 ad-hoc 应用可能需要重新认可辅助功能权限；脚本不会修改该权限。源码哈希分别记录首轮实测版本与最终开发版本，最后一轮只调整了支持名单策略的可测试性及原型 watchdog 意外退出处理，未修改实测输入过滤策略。

先从静止触控板开始，依次完成手势矩阵并记录原桌面/原应用。每轮中央退出按钮或自动超时后，原型面板可以再次开始。之后单独验收手势途中开启、睡眠、外接屏幕、异常恢复。结果 JSON 包含开始/结束快照、事件类型计数及 Space 通知数量，不保存按键内容或指针轨迹；**事件计数不能证明手势阻止成功**。最新文件与每轮副本位于 `build/cleaning-input/`。

任一手势仍生效则记录 FAIL，并立即将对应系统 build 从 `verifiedBuilds` 移除。当前 `26A428` 是为继续实机验收而获准启用，剩余项目仍需更新为明确的人工观察证据。系统升级后重新验收，新 build 不自动继承支持状态。

## 来源

- [Apple 手势处理说明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)：部分系统手势优先于应用响应链。
- [Apple 触发角保护接口](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct/disablescreencornerinteractions)：本机 SDK `NSApplication.h` 同时确认 macOS 27 可用、前台条件，以及必须同时 hideDock 或 autoHideDock。
- [iss 固定提交](https://github.com/joshuarli/iss/blob/493b008f2ea8e9215877c39700e8ea3add800e97/iss.c)：会话级私有手势事件的横向切桌面过滤依据；不能证明其余手势或本实现通过。
