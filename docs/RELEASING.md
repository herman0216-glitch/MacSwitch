# 发布流程

公开分发目前采用 ad-hoc 签名；它校验代码完整性，不验证开发者身份。没有 Developer ID 证书和公证票据，Gatekeeper 首次启动拦截属于预期。不得将 codesign 验证通过描述为 Apple 信任验证通过。

1. 在 `project.yml` 更新版本号及构建号，重新生成随附工程；同步 CHANGELOG 和发布说明。
2. 运行 `./script/test.sh`，读取 `.xcresult` 的测试摘要；测试不能替代实际设备验证。
3. 运行 `./script/package_release.sh`。脚本以 Release 配置归档 arm64/x86_64 通用应用，验证签名及架构，制作带 Applications 链接及首次启动说明的 DMG，并制作 ZIP 与 SHA-256 清单。输出在 `dist/releases/版本号/`，已有目录不会被覆盖。
4. 只读挂载 DMG，验证卷内应用签名；解压 ZIP 后再验证。将应用复制到本机可写目录并启动，检查进程实际路径、菜单栏和设置界面。Intel 需要独立实机验证。
5. 更新版本验证记录，确认源码无凭据、私有日志、用户配置和生成物，再提交并创建版本标签。
6. 在 GitHub 创建 Release，上传 DMG、ZIP、SHA256SUMS.txt、首次启动说明及 LICENSE.txt。发布说明必须明确最低系统版本、架构、签名/公证状态、权限与兼容限制。
7. 下载已发布附件，核对其 SHA-256 与本地清单，确认 Release 指向对应源码标签。

独立上传附件使用 ASCII 文件名（如 FIRST-RUN.txt），避免 GitHub 将纯中文名改写为 default.txt，导致校验清单文件名不匹配。DMG 卷内可保留中文说明文件名。

首次启动使用 Apple 官方的“系统设置 → 隐私与安全性 → 仍要打开”单应用例外。当前本机启动验证不等于全新 Mac 上浏览器下载隔离属性和 Gatekeeper 流程的端到端验证。将来获得 Developer ID 后，可另行加入证书签名、公证及 stapling 流程。
