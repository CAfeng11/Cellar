# Contributing to Cellar

感谢你愿意参与 Cellar。这个项目优先接受聚焦、可解释、可验证的改动。

## 开发环境

- macOS 26+
- Xcode 26+
- Homebrew

## 本地验证

运行完整测试：

```bash
./script/test.sh
```

构建并启动本地 Debug App：

```bash
./script/build_and_run.sh --verify
```

也可以使用 Xcode 打开 `Cellar.xcodeproj`，运行共享的 `Cellar` scheme。

## 提交范围

优先欢迎：

- 可复现的 Bug 修复
- Homebrew/Runtime 识别准确性改进
- 测试、文档、可访问性与可维护性改进
- 与现有产品边界一致的小型功能

较大的产品范围变更，请先创建 Discussion 或 Issue 说明问题、影响范围和候选方案。

## Pull Request 要求

- 一个 PR 解决一个明确问题
- 描述复现方式、行为变化和验证结果
- 行为变化需要更新 README 或相关文档
- 新增判断逻辑应尽量补充单元测试
- 不提交本机路径、日志、DerivedData、`xcuserdata`、凭据或完整环境变量
- 不把 npm/pip/uv 等 Runtime 更新混入 Homebrew 普通升级语义
- 不把“命令已生成/已复制”描述为“修复已执行”

## 代码约定

- 保持现有 Swift/SwiftUI 命名与结构风格
- 先修正事实模型，再调整界面文案
- 涉及命令执行时，参数应结构化传递并验证输入
- 高风险动作必须说明影响范围、确认方式和回滚路径
- 不为消除 warning 而隐藏真实并发或隔离问题

提交前请确认 `./script/test.sh` 通过，并在 PR 中注明本机 macOS 与 Xcode 版本。
