---
kind: external_dependency
name: 本地推理运行时 llama.cpp b10015
slug: llama-cpp
category: external_dependency
category_hints:
    - vendor_identity
scope:
    - '**'
source_files:
    - Sources/ChengGao/Services/EmbeddedModelRuntime.swift
---

应用直接启动包内的 llama-cli 子进程（Runtime/llama-cli）执行本地模型推理，不启动服务器、不开放端口、不需要 Ollama。支持 Qwen3 1.7B Q4_K_M（极速档）和 Qwen3 4B Q4_K_M（增强档）双模型自适应，8GB 设备自动限制为 1.7B 保护模式。通过命令行参数控制上下文大小、温度、top-k/top-p 等推理参数，输出文件采用临时目录隔离。