# v1.1.0 分发验证

日期：2026-09-17。源码功能沿用 1.1.0（2），本次增加开源文档、MIT 许可证资源及可复现的通用打包脚本，未更改系统服务行为。

## 当前验证

- 环境：MacBook Air / arm64，macOS 27.0（26A428），Xcode 27.0（27A266a）。最低部署目标为 macOS 26.0。
- `./script/test.sh`：90 个测试、91 次执行、0 失败、0 跳过。当前本地结果：`build/TestResults-20260917-191816.xcresult`；结果和日志不纳入 Git。
- `./script/package_release.sh`：Release 归档成功；`lipo` 验证 arm64 与 x86_64 两种架构存在。应用携带 MIT 许可证资源。
- `codesign --verify --deep --strict`：归档、DMG 卷内应用、ZIP 解压应用均通过。`codesign -dv` 确认 ad-hoc 签名、hardened runtime，未设置 TeamIdentifier；没有 Developer ID 证书或 Apple 公证。
- `spctl --assess --type execute`：拒绝，符合当前分发信任状态；未改变 Gatekeeper 设置。
- `hdiutil verify`：DMG 校验通过；只读挂载后存在 MacSwitch.app、Applications 链接、首次启动说明、LICENSE.txt。
- 将 DMG 中的应用复制至本地可写测试目录后启动成功，核对实际进程路径为该测试副本；真实设置界面显示 1.1.0（2）。README 三张设置截图来自这一 Release 副本，使用本机已有配置。
- SHA256SUMS.txt 对 DMG、ZIP、首次启动说明与许可证的校验通过。GitHub 发布后还需下载附件并再次验证。

## 验证边界

本次没有重新执行全部物理音频、键盘、双显示器或睡眠测试；历史证据与未覆盖项目见 `ACCEPTANCE.md` 和 `ACCEPTANCE-cleaning-audio.md`。当前 Release 在 Apple Silicon 上启动成功，不代表 Intel 实机兼容性已验证。没有在全新 Mac 上验证浏览器下载、隔离属性、Gatekeeper 单应用例外及权限授予的完整流程。

README 与安装包说明明确使用系统设置中的“仍要打开”，不要求关闭全局安全保护。没有自动更新或后台联网服务。
