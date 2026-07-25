---
kind: build_system
name: Swift Package Manager + Bash 脚本的 macOS 应用构建与发布流水线
category: build_system
scope:
    - '**'
source_files:
    - Package.swift
    - script/bootstrap_runtime.sh
    - script/build_and_run.sh
    - script/package_dmg.sh
    - script/package_release.sh
    - .github/workflows/release.yml
    - VERSION
    - BUILD_NUMBER
---

本项目采用 Swift Package Manager（SPM）作为统一的构建入口，配合一组 Bash 脚本完成从源码编译、App Bundle 组装、签名公证到 DMG/ZIP 分发的完整 macOS 应用发布流程，并通过 GitHub Actions 在推送 v* 标签时自动触发。

**1. 构建系统与工具链**
- SPM 包定义位于 `Package.swift`，声明 macOS 26+ 平台、可执行目标 ChengGao、系统库 CSQLite、二进制框架 whisper.xcframework 以及测试目标 ChengGaoTests。
- 构建命令统一通过 `script/build_and_run.sh` 调用 `swift build -c release -Xswiftc -warnings-as-errors -gnone`，并强制使用 `-file-prefix-map` 隐藏源码路径。
- 运行时依赖（whisper.cpp 的 xcframework、语音模型 ggml-small-q5_1.bin、许可证）由 `script/bootstrap_runtime.sh` 按固定版本（v1.9.1）和 SHA256 校验下载并缓存至 `.build/bootstrap-cache`。

**2. 关键脚本与职责划分**
- `bootstrap_runtime.sh`：仅支持 Apple Silicon（arm64），下载并校验 whisper xcframework、模型文件与许可证，生成多架构 xcframework。
- `build_and_run.sh`：编译 Release 二进制、组装 `dist/澄稿.app`（含 Info.plist、Resources、Frameworks、Models、Licenses、AppIcon），执行本地 ad-hoc 签名，并提供 run/debug/logs/telemetry/verify/package 等模式。
- `package_dmg.sh`：基于已打包的 App 生成 UDZO 压缩 DMG，附带安装说明文档，输出 DMG 及其 sha256 校验文件。
- `package_release.sh`：在本地 Developer ID 证书环境下对 App 与 DMG 执行 Hardened Runtime 签名、notarytool 公证、stapler 打票，并重新生成 ZIP 与 DMG。
- `.github/workflows/release.yml`：在 macos-26 上检出 v* 标签，运行 bootstrap、swift test、package_dmg，校验 VERSION/BUILD_NUMBER/RELEASE_NOTES.md/CHANGELOG.md 一致性后创建或更新 GitHub Release 并上传产物。

**3. 版本与产物命名约定**
- 版本号由根目录 `VERSION`（如 1.22.3）与 `BUILD_NUMBER`（如 71）两个纯文本文件驱动，Info.plist 中分别映射为 CFBundleShortVersionString 与 CFBundleVersion。
- DMG 产物命名为 `ChengGao-${VERSION}-macOS-arm64.dmg`，历史兼容中文文件名 `澄稿-${VERSION}-macOS-arm64.dmg`；GitHub Actions 会在找不到 ASCII 名时自动重命名。
- Release 标题格式为“澄稿 ${TARGET_TAG}”，Release Notes 由 `RELEASE_NOTES.md` 追加安装包说明生成。

**4. 安全与完整性约束**
- 构建阶段禁止动态链接 /opt/homebrew 或 /usr/local 路径，若 otool 检测到则拒绝打包。
- 禁止分发包含开发机源码路径或 .build/debug 痕迹的二进制，grep 匹配即中止。
- DMG 生成前强制 codesign --verify --deep --strict 验证本地签名；发布流程要求 CHANGELOG.md 中存在对应版本的条目。
- Whisper 依赖通过固定 URL + SHA256 校验下载，防止供应链篡改。
- CI 中 swift test 使用 `-Xswiftc -warnings-as-errors` 将警告视为错误。

**5. 持续集成与发布触发**
- 触发条件：推送 v* 标签或 workflow_dispatch 手动指定 tag。
- 环境：macos-26 + Xcode 26.6，使用 actions/cache 缓存 bootstrap 产物与 whisper 框架/模型/许可证。
- 产物：DMG + sha256 校验文件上传至 GitHub Release，首次打开需按 DMG 内说明处理临时签名。