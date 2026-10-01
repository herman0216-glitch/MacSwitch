# 桌面图标运行态隐藏：第一阶段可行性结论

日期：2026-09-30（Asia/Shanghai）。方案来源：[隐藏图标重构方案.md](/Users/herman/Downloads/隐藏图标重构方案.md)。用户已明确将开发验证目标从 `26A428` 更新为当前 `26A434`，其余边界全部保留。

后续变更：本报告交付后，用户另行要求解除现有三个功能的版本禁用；正式允许列表已加入 `26A434`，详见 [验收记录](/Users/herman/Documents/MacSwitch/docs/ACCEPTANCE.md)。这只启用既有功能，没有接入本报告中的 SkyLight 跨进程后端，也不改变以下第一阶段 NO-GO 结论。下文“未修改正式代码/支持清单”描述第一阶段交付时的状态。

## 结论：本次直接跨进程控制路线 NO-GO

在 macOS **27.0.1 / 26A434**、Apple Silicon、SIP 开启的环境中，自有测试窗口的 SkyLight 调用与恢复可用；相同接口直接控制另一个进程的测试窗口未生效。特别是 `SLSSetWindowAlpha` 返回 `0`，却没有改变目标窗口透明度，不能据此宣布获得控制权限。

因此第一阶段未通过，不实施正式后端，不接入 `DesktopService`，不修改正式 build 支持清单或功能文案。真实 Finder 桌面窗口的隐藏、恢复和交互均 **NOT RUN**，正式重构没有完成。没有把旧 WindowManager 设置路线作为本方案的实现。

这是一份针对所测接口、调用方式和 build 的失败证据，不是对所有可能的 macOS 私有接口作绝对不可能判断。若继续，需要先拿出在原有边界内有效的跨进程控制及独立恢复机制；不能跳过这两关试改真实桌面。

## 交付物与复现

- 独立入口：[verify_desktop_runtime.sh](/Users/herman/Documents/MacSwitch/script/verify_desktop_runtime.sh)。不调用原有 `build_and_run.sh`，不重启正在运行的 MacSwitch。
- 源码：[RuntimeProbe.swift](/Users/herman/Documents/MacSwitch/script/desktop-runtime-probe/RuntimeProbe.swift)、[SkyLight.swift](/Users/herman/Documents/MacSwitch/script/desktop-runtime-probe/SkyLight.swift)、[ProbeLogic.swift](/Users/herman/Documents/MacSwitch/script/desktop-runtime-probe/ProbeLogic.swift)、[ProbeLogicTests.swift](/Users/herman/Documents/MacSwitch/script/desktop-runtime-probe/ProbeLogicTests.swift)。未加入正式 Xcode target。
- 构建结果：[DesktopRuntimeProbe.app](/Users/herman/Documents/MacSwitch/build/DesktopRuntimeProbe/DesktopRuntimeProbe.app)。本地 ad-hoc 签名，仅用于开发验证。
- 固化证据：[result.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/result.json)、[manifest.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/manifest.json)。manifest 保存源码及证据文件 SHA-256。

```bash
cd /Users/herman/Documents/MacSwitch
rtk proxy ./script/verify_desktop_runtime.sh --build-only
rtk proxy ./script/verify_desktop_runtime.sh --inventory
rtk proxy ./script/verify_desktop_runtime.sh --run
```

`--inventory` 只枚举符号和窗口身份，不进行隐藏。`--run` 暂时创建小型测试窗口，执行自有窗口、控制进程崩溃及跨进程测试，超时恢复后关闭。它没有对 Finder 窗口进行写操作的执行路径，也没有任意窗口 ID 参数。只有 `26A434` 可运行写入测试，其他 build 拒绝执行；只读枚举仍可运行。该开发限制不表示正式支持 `26A434`。脚本正常退出仅表示研究运行完成，可行性判断以 JSON 的 `status` 为准。

## 接口签名及权限证据

动态加载本机 SkyLight 的 7 个符号：主连接、窗口 alpha 读取/设置、窗口排序、是否处于显示队列、窗口所属连接以及连接 PID。声明使用 `Int32` 连接和返回码、`UInt32` 窗口 ID、`Float` alpha 和 `UInt8` 排序状态指针。

候选 C ABI 来自 [yabai 固定 commit 的 extern.h](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h)。Apple 没有公开这些私有接口的 ABI 保证；本次进一步用当前 build 的自有窗口验证了相关参数、返回和恢复行为，并未仅凭符号存在认定可用。

[yabai 作者的权限说明](https://github.com/asmvik/yabai/issues/1863)指出，Dock 的 WindowServer 连接具有 universal-owner 权限，能修改通常只允许窗口所属应用修改的属性；其相关功能通过 Dock 注入取得该能力。本方案禁止这类注入、关闭安全保护和系统进程重启，因此未尝试它们。这是权限障碍的源码背景，实际失败结论来自下面的本机测试。

探针没有请求新增权限：`AXIsProcessTrusted=false`、屏幕捕获预检查为 `false`，均为不弹窗的读取。探针是普通 ad-hoc 开发应用，没有 universal-owner 权限。没有将授予辅助功能权限当作获得 SkyLight 特权的证明。

Apple 的 [桌面与程序坞设置说明](https://support.apple.com/guide/mac-help/change-desktop-dock-settings-mchlp1119/mac)仍说明关闭显示项目后可点击桌面取用项目。因此旧偏好路线无法证明本次“持续隐藏且设置不变”的目标。

## 当前 build 的实测

| 检查 | 结果 | 证据和边界 |
| --- | --- | --- |
| 编译及安全逻辑 | PASS | Apple Swift 6.4；23 项检查通过，包括旧/未知 build 拒绝、目标 PID/连接失效、Finder 身份/层级/显示器筛选、恢复读回失败和零返回码但状态未变的判定。 |
| 自有窗口的调用 | PASS | 设置 alpha=0 返回 0，读回 0；order-out 返回 0，读回 ordered=0。[self-hidden.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/self-window/self-hidden.json)。 |
| 独立超时恢复 | PASS，仅限自建窗口 | 独立 guardian 先就绪，6 秒后请求测试窗口所属进程恢复，读回 alpha=1、ordered=1；另有 owner 12 秒兜底。[restored.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/self-window/restored.json)。 |
| 控制进程 SIGKILL | PASS，仅限自建窗口 | 隐藏后对独立控制进程执行 SIGKILL，确认其 PID 消失；guardian 继续运行，owner 从 alpha=0、ordered=0 恢复到原值。[crash-issued.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/controller-crash/crash-issued.json)、[restored.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/controller-crash/restored.json)。 |
| 跨进程 alpha | FAIL | 使用调用者连接 ID 和目标连接 ID，两次均返回 0；每次等待 200 ms 后读回仍为 alpha=1、ordered=1。 |
| 跨进程 order-out | FAIL | 调用者连接返回 1000（SDK 的 `kCGErrorFailure`）；目标连接 ID 返回 268435459（`0x10000003`，SDK 的 `MACH_SEND_INVALID_DEST`）。窗口始终 ordered=1。不能把知道另一进程的连接 ID 当作获得权限。 |
| 跨进程测试最终状态 | 原样保留 | 目标 owner 在 6 秒恢复点再次读到 alpha=1、ordered=1；调用和最终观察均未显示获得跨进程控制能力。[operations.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/foreign-window/operations.json)、[restored.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/foreign-window/restored.json)。 |
| Finder 目标识别 | 只读通过，未接管 | Finder Apple 签名有效、标准 bundle 路径及 PID=1275；窗口 62 的层级为 -2147483603，范围匹配显示器 1。按进程身份、精确层级及显示器范围联合筛选，未按窗口名称匹配。[inventory.json](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/inventory.json)。 |
| 系统状态保留 | PASS，所记录范围 | WindowManager、Finder、Dock 三个偏好域的完整规范化 SHA-256 前后一致；相关开关值一致；Finder PID=1275、Dock PID=1273，SIP 始终开启。[前](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/environment-before.json)、[后](/Users/herman/Documents/MacSwitch/docs/evidence/desktop-runtime-26A434-20260930/environment-after.json)。 |
| Shell / diff 静态检查 | PASS | `bash -n script/verify_desktop_runtime.sh`、`git diff --check`。 |

守护进程恢复测试依赖自建窗口所属进程主动配合，证明的是测试装置在控制进程崩溃后仍能恢复。Finder 没有这个配合通道；同一装置不是可用于 Finder 的独立恢复后端。没有为它注入代码或新增通道。

未修改桌面文件的位置、内容或隐藏属性；探针只在自己的 `build/DesktopRuntimeProbe` 运行目录写入消息及证据。未修改系统设置、Finder/Dock 代码或进程生命周期。工作区原有改动保留。

## 方案验收矩阵

| 方案要求 | 结果 | 原因 |
| --- | --- | --- |
| 图标开启、关闭、连续切换及排列保留 | NOT RUN | 跨进程能力未通过，未接入真实 Finder。 |
| 点击原图标位置不误点/误投 | NOT RUN | 没有真实桌面隐藏；未用合成点击代替鼠标/触控板。 |
| 台前调度、点击墙纸各组合 | NOT RUN | 未修改设置或隐藏桌面。 |
| Finder 文件操作与其他应用任务 | NOT RUN（功能验收） | PID 连续和无文件写操作不等于真实操作验收。 |
| 小组件、墙纸、Spaces 与动画 | NOT RUN | 未进入真实桌面实验。 |
| 新文件、Finder 窗口重建 | NOT RUN | 无正式后端。 |
| 多显示器、睡眠唤醒 | NOT RUN | 当前只读枚举 1 个活动显示器，无正式后端。 |
| 正常退出、异常退出与失败后的真实桌面恢复 | NOT RUN | 测试窗口恢复不代替 Finder 恢复。 |
| 正式状态转换、重复操作、部分失败、恢复失败及其他功能隔离 | NOT RUN（第二阶段） | 第一阶段未通过，按方案未实施正式后端及其测试。 |

停止点满足方案第 2、5 节：尚未建立在既定边界内有效的跨进程控制与真实桌面恢复能力，停止接入，交付本报告及独立程序。没有把设置更改、遮挡图标或文件隐藏作为替代完成方式。
