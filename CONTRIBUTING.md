# 开发与提交流程

稳定分支使用 `main`。不要提交模型权重、打包后运行时、DMG、密钥、Cookie、平台会话或本地用户历史。

## 本地验证

```bash
swift test -Xswiftc -warnings-as-errors
```

应用代码或发行资源变更还应运行 README 中相应的构建与安装验证。

## 提交变更

请创建独立分支并发起 Pull Request：

```bash
git switch -c feature/short-description
git commit -m "说明本次变更"
git push -u origin feature/short-description
```

提交前检查 `git status` 和暂存区差异，确保不含本地历史、账号信息或访问凭据。需要使用真实本地历史的诊断测试必须通过 `CHENGGAO_LIVE_HISTORY_PATH` 显式指定文件，且该文件不得提交。
