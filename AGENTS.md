# Codex 发布契约

凡是会改变交付软件行为的任务，Codex 在宣布完成前必须执行完整发布流程：

1. 按语义化版本更新 `VERSION`，并递增 `BUILD_NUMBER`。
2. 在 `CHANGELOG.md` 增加面向用户的更新记录，并用本版本内容替换 `RELEASE_NOTES.md`。
3. 运行 `swift test -Xswiftc -warnings-as-errors`、凭据/本机路径扫描和适用的安装包验收。
4. 通过 `script/release_local.sh` 生成并验证本地 DMG；正式签名、公证条件满足时改用 `script/package_release.sh`。
5. 提交全部已审查的源码和文档。本机 post-commit 钩子会自动把提交推送到 GitHub。
6. 创建并推送带说明的 `v<VERSION>` 标签；`.github/workflows/release.yml` 会在 macOS 26 ARM64 环境重新测试、生成 DMG，并使用 `RELEASE_NOTES.md` 创建或更新公开 GitHub Release。
7. 核对远端提交、Release 页面、版本号、更新说明、DMG 与 SHA-256 下载；只有经过验证且许可允许的 DMG 才能作为附件上传。

测试、敏感信息扫描、依赖许可、签名或打包验收失败时不得发布。严禁提交密钥、Cookie、平台会话、本地历史、用户路径、模型权重、打包运行时或内部审计材料。


---


# 项目开发准则（AI 编码助手通用）

> **本文件供所有 AI 编码助手（Codex、Qoder、Cursor、Copilot 等）读取并严格遵守。**
> 最后更新：2026-07-25

---

## 一、开发前必须做的事

### 1.1 GitHub 先行调研

开发任何新功能、新项目或重大重构前，**必须**先在 GitHub 上搜索类似实现：

- 使用 `gh search repos "<关键词>" --sort stars --limit 5` 搜索相关项目
- 评估 Star 数较高（≥500）的项目的架构、实现方式、维护状态
- 优先借鉴成熟方案，避免重复造轮子
- 记录可借鉴的项目名称、关键技术点、可复用组件
- 比较各项目的核心功能、技术栈、许可证、社区活跃度
- 根据用户需求输出推荐方案，包括技术选型、模块划分、开发步骤
- **修复 Bug、小功能调整、用户已明确指定实现方式的任务，直接执行，无需调研**
- 无法联网或无法访问 GitHub 时，必须明确说明，**禁止虚构调研结果**

### 1.2 阅读项目现有代码

- 先了解项目结构、技术栈、已有代码风格和架构模式
- 尊重项目已有的架构决策、命名规范和设计模式
- **不要随意重构已有代码**，除非用户明确提出重构需求
- 识别项目中的核心模块和边界，避免跨模块的破坏性修改
- 注意项目中的 `.editorconfig`、`tsconfig.json`、`eslint` 等配置文件所规定的代码风格

### 1.3 评估影响范围

- 修改代码前评估变更对其他模块、测试、CI/CD 的影响
- 涉及数据库 Schema 变更时，必须提供迁移脚本
- 涉及 API 变更时，需说明前后端影响

---

## 二、平台设计规范（严格遵守）

### 2.1 macOS 应用

- **必须**遵循 [macOS 26 Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/macos)
- 追求**原生 APP 级别**的视觉效果和交互体验，拒绝跨平台通用样式
- 使用 **SwiftUI** 或 **AppKit** 原生组件，避免通用 UI 框架覆盖原生风格
- 参考系统应用的设计语言：
  - 窗口管理：`NSWindow`、`WindowGroup`、多窗口支持
  - 工具栏：`Toolbar`、自定义 ToolbarItem
  - 侧边栏：`NavigationSplitView`、可折叠侧边栏
  - Sheet / Alert / Popover：系统原生弹出组件
  - 菜单栏：`MenuBarExtra`、Status Item
- 动画遵循系统物理效果：使用 `.spring()`、`.interpolatingSpring`
- 支持 Dark Mode、Accent Color 自定义、Dynamic Type

### 2.2 iOS 应用

- **必须**遵循 [iOS 26 Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/ios)
- 使用原生 UI 模式，尽可能接近原生 APP 样式
- 遵循 iOS 导航模式：
  - `NavigationStack` / `NavigationSplitView`（iPad）
  - `TabView`（底部标签栏）
  - `Sheet` / `Full Screen Cover`（模态呈现）
- 使用 **SF Symbols** 图标，系统字体（`.font(.body)` 等）和标准间距
- 支持 Dynamic Type、VoiceOver、Dark Mode
- 手势交互符合 iOS 习惯：滑动返回、长按菜单、下拉刷新
- 适配 iPhone 和 iPad（如适用）

### 2.3 Android 应用

- **必须**遵循 [Material Design 3](https://m3.material.io/) 规范
- 尽可能接近 Android 原生 APP 样式
- 使用 **Jetpack Compose + Material 3** 组件
- 遵循 Android 导航模式：Navigation Compose、Bottom Navigation、Drawer
- 使用 Material You 动态取色（如适用）
- 支持 Predictive Back 手势、Edge-to-Edge 显示
- 遵循 Android 无障碍指南：contentDescription、touch target 尺寸

### 2.4 Web 应用

- **响应式设计**：移动优先（Mobile First），使用 CSS Grid / Flexbox
- **无障碍**：遵循 WCAG 2.1 AA 标准
  - 使用语义化 HTML（`<nav>`、`<main>`、`<article>`、`<button>` 等）
  - ARIA 属性仅在语义化 HTML 不足时补充
  - 颜色对比度 ≥ 4.5:1（正文文字）
- **性能**：Core Web Vitals 达标（LCP < 2.5s, FID < 100ms, CLS < 0.1）
- 支持 `prefers-color-scheme`（暗色模式）和 `prefers-reduced-motion`

---

## 三、代码质量标准

### 3.1 通用要求

- **注释**：关键业务逻辑、复杂算法、非显而易见的实现必须有注释
- **函数/方法**：保持简短（建议 ≤ 50 行），单一职责原则
- **错误处理**：
  - 不要吞掉错误（`catch {}` 空块禁止）
  - 区分可恢复错误和不可恢复错误
  - 提供有意义的错误信息，包含上下文
- **类型安全**：Web 项目使用 TypeScript，避免 `any`；Swift 项目避免强制解包 `!`
- **命名规范**：
  - 变量/函数：语义化命名，避免缩写（`getUserById` 而非 `getUsr`）
  - 布尔值：使用 `is`/`has`/`should`/`can` 前缀
  - 常量：`UPPER_SNAKE_CASE`（Web）或 `camelCase`（Swift）
- **DRY 原则**：重复代码超过 2 次，考虑抽象
- **依赖最小化**：不引入不必要的第三方依赖

### 3.2 UI 代码特别注意

- **禁止**使用 `div` + `onClick` 代替 `<button>`（无障碍问题）
- 所有 `<img>` 必须有 `alt` 文本（装饰性图片用 `alt=""`）
- 动画必须有 `prefers-reduced-motion` 降级方案
- **响应式布局**：不使用固定 `px` 宽度，使用 `rem`、`em`、`%`、`vw/vh` 等相对单位
- **CSS 常见陷阱**：
  - `flex-shrink: 0` 防止子元素被压缩
  - `overflow: hidden` 配合 `text-overflow: ellipsis` 处理文本溢出
  - `z-index` stacking context 问题：不要随意设置超大 z-index 值
  - `position: sticky` 需要父元素有足够高度且 overflow 不为 hidden
- **表单**：所有 `<input>` 关联 `<label>`，错误状态有明确的视觉反馈

### 3.3 Swift/SwiftUI 专项

- 使用 `@Observable` 宏（iOS 17+）替代 `ObservableObject`
- 使用 `async/await` 处理异步操作，避免嵌套回调
- View 文件保持轻量，业务逻辑放 ViewModel 或 Service 层
- 使用 `Result` 类型或 `throws` 处理错误，避免返回可选类型表示错误

---

## 四、效率与 Token 节约

- 只处理用户明确要求的任务，不主动扩展需求
- 优先采用**最小改动**，禁止无关重构、格式化和依赖升级
- 未指定文件时，只搜索与任务直接相关的目录和符号
- **禁止**无目的扫描整个仓库，禁止重复读取已检查过的文件
- 简单任务直接执行，不输出计划或长篇分析
- 复杂任务先给出不超过 5 条的简短计划，确认后再执行
- 只运行与改动直接相关的测试、检查或构建
- 不输出完整文件、完整日志、重复代码或思考过程
- 完成后仅报告：修改了哪些文件、完成了什么、测试结果、尚存风险

---

## 五、Git 规范

### 5.1 Commit 信息格式

使用 **约定式提交（Conventional Commits）**：

```
<type>(<scope>): <subject>

[可选的正文]

[可选的脚注]
```

- **type** 可选值：
  - `feat`：新功能
  - `fix`：Bug 修复
  - `refactor`：重构（不改变外部行为）
  - `docs`：文档变更
  - `test`：测试相关
  - `chore`：构建/工具链/依赖
  - `perf`：性能优化
  - `style`：代码格式（不影响逻辑）
  - `ci`：CI/CD 配置
- **示例**：`feat(auth): 添加微信登录支持`

### 5.2 分支策略

- `main` / `master`：生产分支，始终保持可部署状态
- `develop`：开发分支，集成最新功能
- `feature/<name>`：功能分支，从 develop 拉取
- `fix/<name>`：修复分支，从 main 或 develop 拉取
- `release/<version>`：发布分支，用于发布前测试和修复

### 5.3 提交纪律

- 每个 commit 只做一件事，保持原子提交
- 不要提交未完成的代码到 main/develop
- 提交前确保代码能编译通过、测试通过
- 敏感信息（密钥、密码）**绝对不能**提交

---

## 六、项目结构规范

```
project-root/
├── src/                 # 源代码
│   ├── components/      # UI 组件
│   ├── services/        # 业务逻辑/服务层
│   ├── models/          # 数据模型
│   ├── utils/           # 工具函数
│   └── assets/          # 静态资源
├── tests/               # 测试代码
├── docs/                # 文档
├── scripts/             # 构建/部署脚本
├── .env.example         # 环境变量模板
├── .gitignore
├── README.md
└── AGENTS.md            # 本文件
```

- 配置文件放项目根目录
- 源代码放 `src/` 目录（Swift 项目遵循 Xcode 项目结构）
- 测试代码放 `tests/` 或 `__tests__/` 目录
- 保持目录职责清晰，不要在错误的目录下放置文件

---

## 七、安全要求

- **绝对禁止**在代码中硬编码密钥、密码、API Key、Token
- 使用环境变量或 `.env` 文件管理敏感配置
- `.env` 文件**必须**在 `.gitignore` 中
- 提供 `.env.example` 模板文件，列出所需的环境变量（不含真实值）
- 依赖包要定期检查和更新，关注安全公告
- 用户输入必须做校验和转义，防止注入攻击
- 网络请求使用 HTTPS，验证证书
- 文件操作注意路径遍历攻击

---

## 八、测试要求

- 核心业务逻辑必须有单元测试覆盖
- 关键用户流程应有集成测试
- UI 组件建议有快照测试或视觉回归测试
- 测试文件命名：`<module>.test.<ext>` 或 `<module>_tests.<ext>`
- 测试要有明确的 AAA 结构：Arrange → Act → Assert
- 不要测试实现细节，测试行为和结果

---

## 九、文档要求

- 公共 API 必须有文档注释（JSDoc / DocC / KDoc）
- 复杂架构决策记录在 ADR（Architecture Decision Record）中
- README 包含：项目简介、安装步骤、使用方法、贡献指南
- 变更日志维护在 `CHANGELOG.md` 中

---

## 十、协作规范

- 代码变更必须通过 Pull Request / Merge Request
- PR 描述需包含：变更目的、实现方式、测试情况、截图（UI 变更时）
- Code Review 关注：正确性、性能、安全、可维护性、测试覆盖
- 保持代码变更小且聚焦，避免超大 PR


---

## 记忆交接文档协议

### 开始工作前
1. 读取 `docs/CURRENT_HANDOFF.md` 了解项目当前状态
2. 如有 `docs/MEMORY_INDEX.md`，按指引读取相关上下文文件

### 结束工作后
必须更新 `docs/CURRENT_HANDOFF.md`，记录以下内容：
- **更新时间**：日期时间
- **最近完成**：本次做了什么
- **当前状态**：项目现在处于什么阶段
- **下一步**：接下来该做什么
- **阻塞/待确认**：有什么卡住的或需要用户确认的
- **不可破坏的决定**：本次做出的重要架构/设计决策
- **涉及文件**：本次修改了哪些关键文件
- **生产环境变更**：是否部署或修改了生产环境

### 规则
- 交接文档是"唯一交接事实源"，优先于旧对话记录
- 只更新有变化的部分，不要重写整个文档
- 如果 docs/ 目录不存在，创建它
