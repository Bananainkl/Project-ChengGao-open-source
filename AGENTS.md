# Codex 发布契约

凡是会改变交付软件行为的任务，Codex 在宣布完成前必须执行完整发布流程：

1. 按语义化版本更新 `VERSION`，并递增 `BUILD_NUMBER`。
2. 在 `CHANGELOG.md` 增加面向用户的更新记录，并用本版本内容替换 `RELEASE_NOTES.md`。
3. 运行 `swift test -Xswiftc -warnings-as-errors`、凭据/本机路径扫描和适用的安装包验收。
4. 通过 `script/release_local.sh` 生成并验证本地 DMG；正式签名、公证条件满足时改用 `script/package_release.sh`。
5. 提交全部已审查的源码和文档。本机 post-commit 钩子会自动把提交推送到 GitHub。
6. 创建并推送带说明的 `v<VERSION>` 标签；`.github/workflows/release.yml` 会使用 `RELEASE_NOTES.md` 创建公开 GitHub Release。
7. 核对远端提交、Release 页面、版本号、更新说明和源码下载；只有经过验证且许可允许的 DMG 才能作为附件上传。

测试、敏感信息扫描、依赖许可、签名或打包验收失败时不得发布。严禁提交密钥、Cookie、平台会话、本地历史、用户路径、模型权重、打包运行时或内部审计材料。
