# Taskronome

**Give every task its turn. / 让每项任务，按时轮到。**

Taskronome 是一款面向 Windows 10/11 的桌面时间片轮转应用。它让多个任务按用户设定的顺序和时长依次执行；每个任务真正开始前都要求在应用内进行 10 秒在场确认，防止用户离开电脑后继续虚假累计时长。

## 核心特性

- 为每项任务设置独立时间片，按顺序循环轮转。
- 第一项和之后每一项都必须在应用内确认，Windows 通知点击只负责唤醒窗口。
- 10 秒未确认即暂停；等待、暂停、锁屏、睡眠、会话断开和应用离线期间均不计时。
- 使用单调时钟计算持续时间，系统时间被修改不会影响剩余时间。
- 支持暂停/恢复、跳过本轮、提前完成、停用、重排和重新启用已完成任务。
- 默认置顶，可最小化到托盘；支持单实例、通知中心提醒、系统提示音和任务栏闪烁回退。
- 本地保存任务、检查点、工作段和轮转事件；异常退出后保守恢复为系统暂停。
- 提供今日/7 天/30 天/全部统计和 UTF-8 CSV 导出。
- 不含账号、云同步、联网统计、广告或遥测。

## 系统要求

- Windows 10 版本 2004（Build 19041）或更高版本，推荐 Windows 11。
- x64 处理器。
- 应用以普通用户权限运行；Windows App SDK 通知不支持管理员提升模式。

## 使用方法

1. 在“任务规划”中新建任务，设置名称、备注和时间片。
2. 调整顺序并确认需要轮转的任务处于启用、未完成状态。
3. 点击“开始轮转”。第一项任务会立即进入 10 秒确认。
4. 在应用内点击“开始任务（我在）”后才开始计时。
5. 时间片结束后，Taskronome 通知下一项任务并再次要求确认。
6. 临时离开时可主动暂停；若未确认或系统锁屏/睡眠，应用会自动安全暂停。

快捷键：`Enter` 确认任务、`Space` 暂停/恢复、`Ctrl+N` 新建任务、`Ctrl+Shift+T` 切换置顶。文本输入期间不会拦截 Enter 或 Space。

## 从源码验证

需要 Windows、PowerShell 7、.NET SDK 10.0.400，以及运行源码审计所需的 Python 3。完整验证并打包命令：

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-and-verify.ps1 -Package
```

该命令依次执行源码审计、NuGet locked restore、格式检查、Release 构建、确定性测试、Core 行/分支覆盖率门槛、真实 2 秒/3 秒短时间片场景、win-x64 自包含发布、WPF 启动与单实例 smoke，并生成便携包和 Inno Setup 安装器。打包还需要本机安装 Inno Setup 6/7。

只做验证时可运行：

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1
python .\scripts\assistant-source-audit.py
```

最终 Windows 原生交互验收使用同一次 CI 下载并解压的 `Taskronome.exe`，不使用测试模式或通知 dry-run：

```powershell
pwsh -NoProfile -File .\scripts\windows-interactive-acceptance.ps1 `
  -AppPath .\ci-artifact\Taskronome.exe `
  -CommitSha <CI-HEAD> -CiRunId <CI-run-id> `
  -PackageArtifactId <package-artifact-id> -EvidenceArtifactId <evidence-artifact-id>
```

该验收脚本为隔离数据目录启动真实生产程序，通过 `System.Windows.Automation` 的 AutomationId 和控件 pattern 完成可自动化检查，并生成 JSON、Markdown、窗口截图、日志、数据快照、SHA-256 清单和证据 ZIP。通知中心、托盘溢出区、锁屏、睡眠、显示缩放和高对比度等需要当前交互桌面或操作者配合的检查，只有在实际执行并留下系统证据后才记为 Pass；确实缺少硬件或权限时记为带理由的 N/A。

构建便携包及按用户安装器：

```powershell
pwsh ./scripts/package.ps1 -Version 1.0.0
```

安装器使用 Inno Setup，默认安装到当前用户的 `%LOCALAPPDATA%\Programs\Taskronome`，不请求管理员权限。产物和 SHA-256 校验值位于 `artifacts/dist/`，文件名为 `Taskronome-1.0.0-win-x64-portable.zip` 与 `Taskronome-1.0.0-win-x64-setup.exe`。正式下载时，应使用生成这些文件的同一次 CI 或 Release workflow 所上传的 `SHA256SUMS.txt`；本地构建生成的哈希仅用于本地验证。

## 项目结构

```text
src/Taskronome.Core/       与 UI/Windows API 解耦的状态机、计时和持久化
src/Taskronome.App/        WPF 界面、通知、托盘、单实例和系统事件集成
tests/                     确定性单元测试与真实短时场景
scripts/                   一键验证、打包和 Windows UI Automation 验收脚本
installer/                 Inno Setup 按用户安装器
docs/                      架构、测试、人工验收与交接说明
```

自动化测试策略见 [docs/TEST_PLAN.md](docs/TEST_PLAN.md)，Windows 人工验收见 [docs/MANUAL_TEST_CHECKLIST.md](docs/MANUAL_TEST_CHECKLIST.md)，最终真实结果见 [docs/TEST_REPORT.md](docs/TEST_REPORT.md)。

## 本地数据

默认数据目录：`%LOCALAPPDATA%\Taskronome`。

- `data.json`：任务、设置、统计、事件和恢复检查点。
- `data.json.bak`：上一次成功保存的备份。
- `data.corrupt-*.json`：检测到损坏时保留的原始文件。
- `logs/`：仅本机诊断日志。

删除应用不会主动删除这些用户数据。详情见 [PRIVACY.md](PRIVACY.md)。

## 开源与安全

Taskronome 采用 [MIT License](LICENSE)。第三方依赖及许可证见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。安全问题请按 [SECURITY.md](SECURITY.md) 中的方式报告。

当前安装包未进行商业代码签名，因此 Windows SmartScreen 在下载量较低时可能显示“未知发布者”。请核对 CI 产物中的 `SHA256SUMS.txt`。
