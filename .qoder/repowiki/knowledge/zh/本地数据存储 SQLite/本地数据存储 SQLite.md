---
kind: external_dependency
name: 本地数据存储 SQLite
slug: sqlite
category: external_dependency
category_hints:
    - vendor_identity
scope:
    - '**'
source_files:
    - Sources/CSQLite
    - Package.swift
---

通过 SwiftPM systemLibrary 目标 CSQLite 集成 SQLite，用于存储爆款研究搜索结果、用户配置和历史记录。ResearchDatabase.swift 提供数据库操作接口，支持去重、CSV/JSON/Markdown 导出等功能。这是应用持久化数据的核心依赖。