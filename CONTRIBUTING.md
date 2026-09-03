# Contributing to Taskronome

感谢改进 Taskronome。提交前请先阅读仓库根目录的 `AGENTS.md` 和 Issue #1 中的行为约束。

## 开发要求

- Windows 10/11 x64、PowerShell 7、.NET SDK 10.0.400；运行源码审计还需要 Python 3。
- 不得让 UI 定时器或系统墙上时钟成为计时真值。
- 只有 `Running` 状态可以增加实际工作时长。
- 新的任务轮次必须经过应用内确认；通知点击不能代替确认。
- 锁屏、睡眠、断开、确认超时和离线期间不得计时。
- 不引入遥测、管理员权限、未知来源素材或运行时 copyleft 依赖。

## 提交前检查

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-and-verify.ps1 -Package
```

若只需要验证：

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1
python .\scripts\assistant-source-audit.py
```

Pull Request 应说明状态机行为变化、测试用例、实际执行结果和仍需人工验证的 Windows 交互。不要以截图代替可重复的自动化验证，也不要声称 CI 无法验证的视觉/通知行为已经人工通过。
