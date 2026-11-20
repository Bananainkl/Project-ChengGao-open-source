# 项目交接文档

> 本文档由 AI 编码助手（Qoder/Codex）在每次任务结束时更新，用于跨对话上下文同步。

---

## 2026-11-20 15:09 HKT · 澄稿 1.23.1（77）

### 最近完成

重新组织六个工作区和三个设置标签。每个窗口独立导航，写稿、检索、编辑成稿与文件包导出均可从当前任务直接进入。研究记录支持宽窗双栏和窄窗返回，缩放过程中保留选中项。项目首页截图来自安装版中的示例文稿。

### 当前状态与生产环境

Apple Silicon 本地候选包为 `dist/ChengGao-1.23.1-macOS-arm64.dmg`，191,252,407 字节，SHA-256 为 `d992151a40fee4aa0751f5d2116c445fe41077dc79cb7e89f806f06f7393543c`。已在 macOS 27.2.1 从 DMG 安装启动，主程序标记 SDK 27.2、最低系统 26.0。DMG 校验、严格代码签名完整性检查和 173 项默认测试通过。仅更新本机安装，公开 Release 仍为之前的版本。

### 安装版验收

- 核对浅色标准窗口和深色窄窗口的六个页面、三个设置标签。用 ⌘1 至 ⌘6 逐页导航，并实际进入和退出全屏。在第二个窗口切页后，第一个窗口仍保留原页面。
- 使用包含研究历史的安装版连续跨过分栏断点 12 次，并反复打开详情和返回。另有实际 NSWindow 承载 24 条测试结果的自动回归。
- 从隔离的示例历史打开五类结果，修改标题并保存，从最近处理搜索到修改后的文稿。通过系统目录选择器导出并读取改写文稿、11 行口播字幕和分镜提示词。
- 单独启用 5 项在线回归。哔哩哔哩关键词检索本轮返回结果，隔离用户状态的安装版按 ⌘Return 搜索后也显示了真实排名与详情。哔哩哔哩字幕请求失败，YouTube 字幕响应无法解析，小红书和抖音检索要求有效登录。实际配置的第三方改写服务曾返回 HTTP 404，本地兼容测试服务的成功回包只验证客户端处理链路。

### 下一步与阻塞

补验 macOS 26 安装运行、第三方账号登录后的完整流程和 VoiceOver 连续朗读。当前使用临时签名，Gatekeeper 评估被拒，正式分发仍需 Developer ID 签名和公证。此版仅供本地验收。

### 设计决定与涉及文件

使用系统导航、原生工具栏、表单和焦点命令。系统减少动态效果设置控制转场。研究列表在窗口缩放期间具有稳定的视图身份。窗口入口位于 `Sources/ChengGao/App/ChengGaoApp.swift`，界面位于 `Sources/ChengGao/Views`，命令位于 `Sources/ChengGao/Support/FocusedRewriteActions.swift`。构建、打包、发布工作流和 `OfflineRewritePipelineTests.swift` 同步覆盖双工具链及回归。

---

## 2026-07-26

### 最近完成
- 澄稿 1.22.4 (74) 修复爆款研究页详情栏过宽：用明确的 2:1 固定比例替代只设置 `HSplitView.idealWidth` 的无效方案。
- 删除详情页播放量和重复指标区；列表显示点赞数，详情指标改为两行布局。
- 修复 `release_local.sh` 传入错误 DMG 文件名，以及安装脚本变量紧邻中文标点导致的解析失败。
- 170 项警告即错误测试通过；DMG 校验并从本体安装 `/Applications/澄稿.app` 成功。
- 安装版真实历史页面核对：左侧约三分之二、右侧约三分之一，界面无“播放”文字，点赞／收藏／评论／综合热度没有挤压换行。
- 公开仓库提交 `23cb922` 已由 post-commit 钩子推送到远端 `dev-0.1.4-fix`。

### 当前状态
- 本机安装版：1.22.4 (74)，运行正常。
- DMG：`dist/ChengGao-1.22.4-macOS-arm64.dmg`
- 大小：191,220,380 bytes；SHA-256：`e465412a7aa42df4800ed5df68fee9c6cf697d692b5620ce979898c0d31103cf`

### 下一步
- 如需合并到公开 `main` 或创建正式 Release，先审查 Qoder 分支上的其余 UI 改动；正式附件仍需 Developer ID 签名与公证。

### 阻塞/待确认
- 当前仍为 arm64、临时签名未公证的本地候选包。

### 不可破坏的决定
- 研究页右侧详情栏保持结果区域三分之一；不要再用 `HSplitView` 的 `idealWidth` 冒充固定比例验收。
- 播放量无法稳定取得时不展示，不用占位值冒充真实数据。

### 涉及文件
- `Sources/ChengGao/Views/ResearchView.swift`
- `Tests/ChengGaoTests/OfflineRewritePipelineTests.swift`
- `script/install_local.sh`
- `script/release_local.sh`
- `VERSION`、`BUILD_NUMBER`、`CHANGELOG.md`、`README.md`、`RELEASE_NOTES.md`

### 生产环境变更
- 从本次 DMG 更新了 `/Applications/澄稿.app` 至 1.22.4 (74)。

---

<!-- 以下为历史交接记录，最新的在最上面 -->
