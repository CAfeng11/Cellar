# Runtime Doctor Roadmap

`v2.1.0` 已经完成最初规划的阶段 0 到阶段 5：Cellar 不再只是 Node 运行时页，而是已经具备统一 `Runtime Doctor` 总览、Node / Python 详情、路径策略与修复建议的第一版结构。

这份路线图保留为后续演进参考，而不是当前版本仍未完成的待办列表。

## 产品边界

- Cellar 不是 Python IDE
- 不做虚拟环境内容管理
- 不替代 `pip`、`uv`、`pyenv`、`conda`
- 不替代 `npm`、`nvm`、`fnm`、`volta`
- Cellar 只做：发现、解释、对齐、修复建议
- 自动修复只限 PATH / GUI 环境 / 安全的用户级配置
- 所有危险操作默认只给命令，不静默执行

## 已完成阶段

- 阶段 0：产品边界固化
- 阶段 1：多运行时骨架
- 阶段 2：Python 观察模式
- 阶段 3：Python 修复建议
- 阶段 4：Python 全局工具入口
- 阶段 5：统一 Runtime Dashboard

## 已落地边界

- Runtime Doctor 定义为 `本机运行时环境观察、解释与秩序管理`
- Node 是第一个运行时，Python 是第二个运行时
- 默认策略保持“解释优先，自动修复克制”
- 所有危险操作默认保持“给命令，不静默执行”

## 后续方向

- 继续增强 `Custom PATH（专家模式）`
- 继续完善跨运行时工具冲突解释
- 继续补强高风险动作的只读指引与回滚说明
- 继续清理与 Runtime Doctor 无关的既有 Swift 6 warning
