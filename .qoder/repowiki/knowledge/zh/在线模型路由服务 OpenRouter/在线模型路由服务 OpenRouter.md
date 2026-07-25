---
kind: external_dependency
name: 在线模型路由服务 OpenRouter
slug: openrouter
category: external_dependency
category_hints:
    - vendor_identity
scope:
    - '**'
source_files:
    - Sources/ChengGao/Services/OpenRouterCredentialStore.swift
---

可选的在线优先模式使用 OpenRouter 的免费模型路由处理全文改写任务。密钥保存在 macOS 钥匙串中，断网、限流或在线质量不合格时自动回退到本地模型。OpenRouter 的实际模型会随当时可用性变化，结果备注会记录本次实际路由的模型名称。这是在线 AI 改写的核心路由服务。