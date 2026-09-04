# Security Policy

## Supported version

在 1.0 正式发布前，仅仓库 `main` 分支的最新版本接受安全修复。正式发布后，维护者会在此列出受支持版本。

## Reporting a vulnerability

请不要在公开 Issue 中披露会造成数据破坏、任意代码执行、权限提升或隐私泄露的细节。优先使用 GitHub 仓库的私密漏洞报告功能；若该功能未开启，请通过仓库所有者公开资料中的联系方式发送最小复现。

报告应包含受影响版本、Windows 版本、复现步骤、预期与实际行为，以及能够帮助验证问题的最小日志。请先删除任务名称、备注和本机路径等隐私信息。

## Security boundaries

- Taskronome 不应以管理员身份运行。
- Taskronome 不接收远程命令，不监听网络端口。
- 单实例 IPC 仅接受固定的 `SHOW` 命令，用于激活已有窗口。
- 本地 JSON 数据不被视为可信输入；无效或不支持的数据会被隔离。
- 发布产物应附 SHA-256；正式公开发布建议增加 Authenticode 代码签名。
