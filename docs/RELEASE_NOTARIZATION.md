# Developer ID 公开发行

`script/package_release.sh` 是唯一的公开发行入口。它会运行全量测试，精简 llama.cpp 运行时，按由内到外的顺序给动态库、`llama-cli`、Whisper framework 和 App 签名，启用 Hardened Runtime，再向 Apple 提交 ZIP 和 DMG 公证并装订 ticket。

## 一次性准备

1. 在 Apple Developer 账号中创建并安装 `Developer ID Application` 证书。
2. 将 App Store Connect API Key 或 Apple ID 公证凭证保存到钥匙串，例如：

```bash
xcrun notarytool store-credentials "chenggao-notary" \
  --key "/absolute/path/AuthKey_XXXXXXXXXX.p8" \
  --key-id "XXXXXXXXXX" \
  --issuer "00000000-0000-0000-0000-000000000000"
```

密钥文件和凭证不得放入项目、脚本或交接文档。

## 发行

```bash
export CHENGGAO_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CHENGGAO_NOTARY_PROFILE="chenggao-notary"
./script/package_release.sh
```

脚本会在证书、公证凭证、更新记录、Hardened Runtime 或任一签名检查缺失时直接停止。只有 `notarytool --wait`、`stapler validate`、`spctl`、`codesign --strict` 和 `hdiutil verify` 全部通过后，才可将 `dist/` 中的 ZIP 或 DMG 称为已公证发行包。
