# 项目交接文档

> 本文档由 AI 编码助手（Qoder/Codex）在每次任务结束时更新，用于跨对话上下文同步。

---

## 最新更新：2026-07-26

### 最近完成
- 澄稿 1.22.4 (74) 修复爆款研究页详情栏过宽：用明确的 2:1 固定比例替代只设置 `HSplitView.idealWidth` 的无效方案。
- 删除详情页播放量和重复指标区；列表显示点赞数，详情指标改为两行布局。
- 修复 `release_local.sh` 传入错误 DMG 文件名，以及安装脚本变量紧邻中文标点导致的解析失败。
- 170 项警告即错误测试通过；DMG 校验并从本体安装 `/Applications/澄稿.app` 成功。
- 安装版真实历史页面核对：左侧约三分之二、右侧约三分之一，界面无“播放”文字，点赞／收藏／评论／综合热度没有挤压换行。

### 当前状态
- 本机安装版：1.22.4 (74)，运行正常。
- DMG：`/Users/itou/Documents/OpenSource/Project-ChengGao-open-source/dist/ChengGao-1.22.4-macOS-arm64.dmg`
- 大小：191,220,380 bytes；SHA-256：`e465412a7aa42df4800ed5df68fee9c6cf697d692b5620ce979898c0d31103cf`

### 下一步
- 推送当前分支后核对远端提交；如需正式公开附件，仍需 Developer ID 签名与公证。

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
