# 参与开发

需要 macOS 26+、完整 Xcode 26+，以及可选的 XcodeGen 2.44+。打开随附的 `MacSwitch.xcodeproj`，或运行 `./script/build_and_run.sh --verify`。

修改工程设置时更新 `project.yml` 并使用 XcodeGen 重新生成工程。提交前运行 `./script/test.sh`，说明复现方式、修改行为及测试结果。设备功能还需说明实际测试设备与权限状态；单元测试不能代替实际音频、键盘、显示器和睡眠恢复验证。

请保持系统服务与界面分离，保留失败后的实际状态回读和资源清理。不要移动用户桌面文件、修改 TCC 数据库、加入全局安全保护关闭命令，或把用户音频写入日志与文件。系统操作探针可能改变音量、静音或路由，运行前阅读 README 与脚本。

历史验收见 `docs/ACCEPTANCE.md` 与 `docs/ACCEPTANCE-cleaning-audio.md`，当前版本的分发验证见 `docs/RELEASE-1.1.0.md`。提交贡献即表示你有权按项目 MIT 许可证提供该贡献。
