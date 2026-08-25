# Cellar Architecture

Cellar 是一个 Xcode 管理的原生 SwiftUI macOS App。当前工程包含 `Cellar` App target 和 `CellarTests` 单元测试 target。

## 主要模块

- `CellarApp.swift`：App/窗口入口、菜单栏、主界面状态和任务编排。
- `CellarBackend.swift`：Homebrew 命令模型、进程执行、JSON 解析与包状态真相合并。
- `DashboardSummary.swift`：把 Homebrew、Runtime 和本机资产状态聚合成决策摘要。
- `PackageStateModels.swift`、`PackageSizeEstimate.swift`：版本差异、badge、筛选和大小语义。
- `RuntimeInspector.swift`：采集 GUI/Shell 下的 Node、Python、包管理器和 PATH 事实。
- `RuntimeModels.swift`：Runtime 快照、latest 状态、全局工具和策略模型。
- `RuntimeDoctorViewModel.swift`、`RuntimeDoctorView.swift`：Runtime 诊断流程与界面。
- `BrewReliabilityDiagnostics.swift`：网络、DNS、代理、端点、权限和 brew 缺失归因。
- `AppEventCenter.swift`：跨 Homebrew/Runtime 的结构化事件与最近状态。

## 数据与动作边界

```text
Homebrew / Shell / App bundles
            ↓ 只读采集
   Backend + RuntimeInspector
            ↓ 事实模型
 Dashboard / Library / Runtime Doctor
            ↓ 用户明确操作
 结构化命令执行 → 结果复核 → 事件与报告
```

Cellar 区分三类证据：

1. 已读取的本机事实，例如路径、版本和 receipt。
2. 已执行命令的结果，例如 `brew outdated` 或 latest 查询。
3. 建议或已复制命令；它们不等同于已执行修复。

## 并发模型

界面状态主要由 Main Actor 管理；外部进程和流式输出由独立任务包装。任务必须支持取消，并在完成后复核状态。当前 Swift 5 模式仍有若干面向 Swift 6 的 actor-isolation warning，贡献者不应通过静默降低检查级别规避它们。

## 测试策略

`CellarTests` 优先覆盖不依赖真实用户环境的纯逻辑：

- Homebrew JSON 与版本真相解析
- 普通更新/自更新 Cask 分类
- 大小和状态文案
- Runtime 来源、PATH Policy 和 latest 状态
- Dashboard、事件与操作摘要

真实 Homebrew、代理和版本管理器组合仍需要本机集成验证，因此 Issue/PR 应注明验证环境。
