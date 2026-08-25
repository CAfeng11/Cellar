# Security Policy

Cellar 会读取本机开发环境并执行用户明确发起的 Homebrew/Runtime 命令。安全边界是项目的一部分，而不是发布后的附加说明。

## 支持范围

当前只为最新的 `2.2.x` 补丁版本接受安全修复。旧版本可能要求先升级后复现。

## 报告漏洞

请优先使用 GitHub 仓库的 **Security → Advisories → Report a vulnerability** 私下报告。若该入口尚未启用，请创建一个不包含利用细节的最小 Issue，请求维护者建立私密联系方式。

报告中建议包含：

- 受影响版本和 macOS 版本
- 最小复现步骤
- 可能影响的数据或命令范围
- 已脱敏的日志或截图

请勿公开代理凭据、registry token、完整环境变量、用户名或不必要的绝对路径。

## 当前安全边界

- Cellar 不上传遥测，也没有后端账号系统。
- 设置保存在本机 `UserDefaults`；代理目前只支持主机、端口和协议，不设计为凭据保险箱。
- Homebrew 与 Runtime 操作通过结构化可执行文件和参数启动，不接受任意 shell 文本作为普通操作参数。
- 高风险 Runtime 改动默认只生成命令或要求明确确认，并提供回滚说明。
- App Sandbox 当前关闭，因为 Cellar 需要读取 Homebrew、App bundle 和多种本机运行时路径；这也意味着发布者和贡献者必须谨慎审查文件及进程操作。
- 本地构建不等于经过 Apple notarization。源码构建与未来签名二进制应分别验证。
