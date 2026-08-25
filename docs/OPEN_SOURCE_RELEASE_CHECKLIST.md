# Open-source Release Checklist

## Source

- [x] `MARKETING_VERSION`、README 和 CHANGELOG 一致
- [x] `./script/test.sh` 通过
- [x] Release 配置可以构建
- [x] 公开源快照没有 `xcuserdata`、DerivedData、日志或本机绝对路径
- [x] 公开源快照已检查凭据和个人信息，并从空 Git 历史开始

## Documentation

- [x] README 描述当前行为而不是规划行为
- [x] 安全边界、App Sandbox 状态和命令影响范围明确
- [x] 构建所需 macOS/Xcode/Homebrew 版本明确
- [x] Issue/PR 模板和贡献指南可用

## GitHub

- [x] 已准备无私有规划历史的公开源快照
- [x] 已准备 GitHub Actions workflow
- [ ] 创建 GitHub 远程公共仓库并确认首次 CI 通过
- [ ] 启用 Private vulnerability reporting
- [ ] 设置仓库描述、topics 和社交预览图
- [ ] 确认提交邮箱是否适合公开

## Distribution

- [x] 源码发布与二进制发布边界明确
- [ ] 若上传 `.app`，完成签名、notarization 和 Gatekeeper 验证
- [ ] Release notes 说明已知限制和最低系统版本
