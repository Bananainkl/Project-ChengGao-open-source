---
kind: dependency_management
name: Swift Package Manager + 预编译二进制框架的依赖管理
category: dependency_management
scope:
    - '**'
source_files:
    - Package.swift
    - script/bootstrap_runtime.sh
    - script/build_and_run.sh
    - script/package_release.sh
    - .github/workflows/release.yml
    - Sources/CSQLite/module.modulemap
    - Frameworks/whisper.xcframework/Info.plist
---

本项目采用 Swift Package Manager（SPM）作为统一的依赖声明与构建入口，结合脚本化引导与预编译二进制框架，形成 macOS 应用的依赖管理体系。

**使用的系统与工具**
- SPM：通过根目录 `Package.swift` 声明应用目标、系统库与二进制框架依赖，指定最低平台为 macOS v26。
- 预编译 xcframework：whisper.cpp 语音识别框架以 `Frameworks/whisper.xcframework` 形式内嵌，由 `bootstrap_runtime.sh` 从 GitHub Releases 下载指定版本（v1.9.1）并校验 SHA256。
- CSQLite：通过 `module.modulemap` 声明为 systemLibrary，直接链接系统 sqlite3。
- 构建与打包：`build_and_run.sh` 负责 swift build、App Bundle 组装、签名与运行；`package_release.sh` 负责 Developer ID 签名、notarytool 公证与 DMG 生成。
- CI：`.github/workflows/release.yml` 在 macOS-26 上执行 bootstrap、测试、DMG 构建与 Release 发布，并使用 actions/cache 缓存 whisper 运行时。

**关键文件与位置**
- `Package.swift`：SPM 清单，定义 ChengGao 可执行目标、CSQLite 系统库与 whisper 二进制框架依赖。
- `script/bootstrap_runtime.sh`：下载并校验 whisper xcframework、模型文件与许可证，写入 `.build/bootstrap-cache` 缓存。
- `script/build_and_run.sh`：构建、组装 App Bundle、注入 rpath、签名与运行。
- `script/package_release.sh`：Developer ID 签名、notarytool 公证、stapler 打票、DMG 创建与校验。
- `Sources/CSQLite/module.modulemap`：系统库模块映射，链接系统 sqlite3。
- `Frameworks/whisper.xcframework/`：预编译的 whisper 多架构框架。
- `Models/ggml-small-q5_1.bin`：本地语音识别模型。
- `Licenses/whisper.cpp-LICENSE.txt`：第三方许可证文本。
- `.github/workflows/release.yml`：GitHub Actions 发布流水线。

**架构与约定**
- 所有第三方二进制依赖通过 SPM 的 `binaryTarget` 或 `systemLibrary` 声明，不引入源码级依赖，避免跨平台编译问题。
- 外部运行时（whisper）采用“引导脚本 + 缓存”模式：首次构建时从受信任源下载，严格校验 SHA256，后续构建复用缓存。
- 构建产物中禁止包含开发机路径（如 `/opt/homebrew`、`/usr/local`、`/Users/...`），`build_and_run.sh` 通过 `otool -L` 与 grep 检查强制拒绝。
- 发布流程要求 CHANGELOG.md 中存在对应版本的条目，否则停止打包。
- 模型文件与许可证随应用资源一起分发，确保离线可用且合规。

**约束与规则**
- whisper 版本锁定在 v1.9.1，SHA256 硬编码于引导脚本，不可随意更改。
- 仅支持 Apple Silicon（arm64）引导，Intel 需单独打包（脚本显式退出码 2）。
- 应用最小系统版本固定为 macOS 26.0，由 Info.plist 与 SPM 共同声明。
- 发布签名必须使用 Developer ID Application 证书，并通过 notarytool 完成公证与 stapling。
- 所有依赖下载均启用重试机制（curl --retry 3），保证网络不稳定时的可靠性。