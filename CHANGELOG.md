# 更新日志

本项目遵循语义化版本风格记录可见变更。

## [Unreleased]

### 文档

- README 首屏明确 Cellar 是原生 SwiftUI 图形应用，并加入仪表盘、我的酒窖与 Runtime Doctor 的真实运行截图。

## [2.2.2] - 2026-08-25

### 版本定位

- `v2.2.2` 是基于 `v2.2.1` 的可靠性、可定位表达与开源准备补丁。
- 主界面第一层改为结论优先：仪表盘回答是否需要处理，我的酒窖解释资产状态，Runtime Doctor 管理运行时可靠性。
- 诊断报告、事件中心、修复历史和偏好设置共同支撑失败复盘与下一步决策。

### 新增

- 新增产品术语清单，统一仪表盘、我的酒窖、Runtime Doctor、PATH Policy、Minimal Trusted PATH、仓库版本差异、自更新 Cask、大小未知和修复历史等表达。
- 新增 Runtime 诊断领域模型、推荐动作、风险级别、结构化事件与动作后验证摘要。
- 新增 Runtime PATH Policy 策略模型，覆盖 Minimal Trusted、Mirror Shell、Custom Expert 与 Observe Only 语义。
- 新增 Runtime 修复历史，记录 Cellar 主动执行的 PATH 对齐、GUI PATH 写入、npm prefix 修复与修复计划子动作。
- 新增 Homebrew 操作摘要，支持检查更新、更新仓库后检查、升级完成/失败的主界面复盘。
- 新增“我的酒窖”资产状态 badge、状态筛选和仪表盘资产摘要。
- 新增 `CellarTests` 测试 target，覆盖 Runtime / Homebrew / Package state 纯逻辑基线。

### 优化

- 将 Runtime Doctor 拆分为模型、ViewModel、采集服务和视图入口，降低单文件维护压力。
- 批量升级确认弹窗现在列出包名、版本变化和大小状态。
- 顶部刷新入口新增显式“更新 Homebrew 仓库后检查”，不再只依赖 Option 快捷方式。
- Runtime 动作后验证改为按推荐动作 ID 关联诊断问题，避免无关告警变化被误判为修复通过。
- 安装、卸载、清理流程补齐 Homebrew 操作摘要，并为复制类 Runtime 治理动作补齐“等待手动执行”结构化事件。
- 升级完成摘要改为基于升级后的 `brew outdated` 复核结果生成，可明确区分“目标包已不再可升级”和“仍在可升级列表”。
- 仪表盘新增“今日待处理”决策层，汇总 Homebrew 更新/异常、Runtime 高风险问题和我的酒窖资产状态，并为每项绑定下一步动作。
- 新增结构化事件中心，汇总 Homebrew 与 Runtime 关键事件；底部运行日志默认折叠为高级日志入口，普通任务不再自动铺开完整日志。
- 新增 Homebrew 可靠性诊断，能将 brew 缺失、DNS/网络/代理/端点和目录权限异常归因为结构化状态，并在仪表盘与设置页给出中文说明和人工核对建议。
- Homebrew 更新列表和批量升级流程补齐大小未知说明、升级阶段摘要与完成后 outdated 复核复盘。
- 偏好设置重组为可靠性策略中心，分为连接、Homebrew 服务和维护，并支持从网络/代理错误摘要跳转到对应区域。
- Runtime 页面将 PATH Policy 升级为策略中心，显示当前策略、影响范围、风险、可执行动作与回滚方式。
- Runtime 报告导出补齐当前诊断快照、当前策略、Homebrew 可靠性诊断、最近关键事件、事件记录与修复历史，复制类动作仅进入事件，不进入已执行修复历史。
- 主界面、空状态、错误态、关键按钮、badge 和禁用态补齐下一步或 tooltip，降低第一层文案的工程化负担。
- Runtime 全局工具关注项可定位到具体工具、当前版本、latest、来源与检查时间，超过 24 小时的结果会标记为待复核。
- 补齐公开构建入口、GitHub Actions、贡献指南、安全策略与架构文档。

## [2.1.0] - 2026-05-14

### 版本定位

- `v2.1.0` 是 Runtime Doctor 的第一次完整收敛
- Cellar 从“Homebrew 工具 + Node 运行时页”演进为统一的本机运行时管理面板
- 本版重点是把 Node / Python 收拢成统一的 `Runtime Doctor` 结构与总览体验

### 新增

- 新增 `RuntimeKind`
- 新增通用运行时骨架
  - `RuntimeExecutableSnapshot`
  - `RuntimePackageManagerSnapshot`
  - `RuntimePathSnapshot`
  - `RuntimeProvider`
- 新增 Python 观察模式
  - `python3`
  - `pip`
  - `python -m pip`
  - `uv`
  - `pipx`
  - `pyenv`
  - `conda`
- 新增 Python 修复建议
  - 最小可信对齐
  - `~/.local/bin` PATH 补丁指引
  - `python -m pip` 命令建议
  - `pipx ensurepath` 指引
  - conda base 自动激活提示与回滚命令
- 新增 Python 全局工具入口视角
  - `pipx`
  - `uv tool`
  - `~/.local/bin`
  - 常见 Homebrew Python 工具
- 新增统一 Runtime Dashboard 总览
  - Node 健康度摘要
  - Python 健康度摘要
  - PATH Policy 摘要
  - 全局工具入口摘要
- 新增 `ROADMAP.md`

### 优化

- 将 `RuntimeSnapshot` 从 Node 专用结构提升为多运行时结构
- 将运行时导出报告文件名切换为按运行时种类生成
- 将运行时页顶部概览文案从 “Node 专属” 调整为 “当前运行时”
- 将 `npm 全局包` 区的对外表达提升为 `全局工具入口`
- 新增运行时切换器，可在 `Node` 与 `Python` 之间切换
- 新增 `运行时工具关系` 面板，用来解释解释器与工具入口是否属于同一环境
- 让 Python 模式从“只读观察”提升为“解释 + 建议 + 命令复制”
- 让 Python 模式开始展示全局工具入口来源、PATH 可见性、当前作用域归属和同名入口冲突
- 让运行时页从“先切换再观察”升级成“先看总览，再进入详情”
- 让 Runtime Doctor 每次刷新时同步更新 Node / Python 两套快照

### 文档

- 明确 Runtime Doctor 的产品边界
- 明确 Node 是第一个运行时，Python 是第二个运行时
- 明确 Runtime Doctor 的多运行时产品路线
- 补充 Python 观察模式的边界说明
- 补充 Python 修复建议的边界说明
- 补充 Python 全局工具入口的边界说明
- 补充统一 Runtime Dashboard 的当前结构说明

## [2.0.0] - 2026-04-18

### 版本定位

- `v2.0.0` 为一次明确的产品升级
- Cellar 从 Homebrew 更新工具扩展为本机运行时管理面板
- 本版将作为 `v2.0.0` 构建并试运行

### 新增

- 新增 `Runtime Doctor` 页面
- 新增运行时概览卡片
- 新增 Node / npm / prefix / PATH / 全局包观察能力
- 新增 Shell 与 GUI 环境差异识别
- 新增运行时来源识别
  - Homebrew
  - nvm
  - fnm
  - Volta
  - 官网 pkg
  - legacy `/usr/local`
  - app 私有运行时
- 新增 `推荐运行时` 裁决层
- 新增 `PATH Policy` 展示层
- 新增运行时报告导出
- 新增运行时修复命令复制
- 新增 GUI 修复命令与 GUI 回滚命令
- 新增 npm prefix 修复能力
- 新增全局包更新 / 重装 / 卸载操作
- 新增运行时页面统一日志接入
- 新增自动维护设置
  - 定时快速刷新
  - 分离的 `brew update` 间隔控制
- 新增 Homebrew 代理配置
- 新增出口 IP 检测与连通性测试

### 优化

- Homebrew 刷新逻辑调整为“快速刷新”和“`brew update`”分离
- 默认刷新不再每次都执行 `brew update`
- 自动维护按刷新间隔定时执行快照检查
- 自动维护仅在达到 update 阈值时执行 `brew update`
- 支持分别配置刷新间隔与 update 间隔
- 将运行时页调整为响应式布局
  - 窄窗口下自动两列或单列
  - 宽窗口下自动四列
- 优化顶部标题区与工具按钮排布
- 优化概览卡、运行时列表、全局包面板的挤压问题
- 将“告警式表达”调整为“解释式表达”
- 明确区分：
  - 终端可用
  - GUI 未接入
  - 策略性差异
  - 真正需要修复的问题
- 将默认 GUI 路径策略调整为 `Minimal Trusted PATH`
- 清理会误导用户的文案
- 统一模块名称为 `Runtime Doctor`

### 修复

- 修复运行时页面中部件互相挤压、标题裁切、文本溢出等问题
- 修复 `npm` 探测时可能出现的 `env: node: No such file or directory`
- 修复运行时卡片对 GUI 视角与终端视角表达不清的问题
- 修复修复指引中按钮语义不清、容易让人误以为会自动写入 shell 的问题
- 修复 PATH 修复命令中过度继承 shell 脏路径的问题

### 文档

- 重写 `README.md`
- 更新版本定位为 `v2.0.0`
- 补充 Runtime Doctor 的功能说明、策略说明与试运行说明

## [1.0.0] - 2026-01-19

### 新增

- 菜单栏 Homebrew 状态展示
- 主窗口可更新软件列表（支持搜索 / 类型筛选）
- 软件详情查看（brew info）
- Formula 锁定 / 解锁
- 批量升级与单项升级
- 清理缓存（brew cleanup）
- 实时日志面板

### 优化

- 操作任务拆分为 main / info / pin，避免状态互相覆盖
- Pinned 软件置顶显示
- UI 状态与后台任务解耦，避免假忙碌

### 修复

- Stream 取消时返回明确的 cancelled 错误
- 修复 Pin 并发导致的状态错乱
- 修复变量命名冲突引发的潜在问题
