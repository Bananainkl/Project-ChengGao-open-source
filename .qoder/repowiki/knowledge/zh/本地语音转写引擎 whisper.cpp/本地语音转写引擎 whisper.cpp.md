---
kind: external_dependency
name: 本地语音转写引擎 whisper.cpp
slug: whisper-cpp
category: external_dependency
category_hints:
    - vendor_identity
scope:
    - '**'
source_files:
    - Frameworks/whisper.xcframework
    - Models/ggml-small-q5_1.bin
---

项目内嵌 whisper.cpp v1.9.1 作为二进制框架（Frameworks/whisper.xcframework），配合包内 Qwen3 Small Q5_1 模型（Models/ggml-small-q5_1.bin）实现离线语音转写。应用通过 afconvert 将视频音轨转换为 16kHz WAV 格式后，在进程内调用 whisper.cpp 进行转写，转写完成后释放模型资源再启动语言模型，确保两个模型不会同时驻留内存。这是处理无字幕视频的核心依赖。