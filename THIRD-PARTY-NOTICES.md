# Third-party notices

Taskronome 自有源代码采用 MIT License。以下组件由各自权利人维护：

| 组件 | 用途 | 版本 | 许可证/说明 |
|---|---|---:|---|
| .NET / WPF | 应用运行时与桌面 UI | 10 | MIT，Microsoft |
| Microsoft.WindowsAppSDK | Windows 应用通知与运行时 API | 2.4.0 | MIT，Microsoft |
| xUnit.net | 测试框架，仅开发/CI | 2.9.3 | Apache-2.0 |
| xunit.runner.visualstudio | 测试适配器，仅开发/CI | 4.0.0 | Apache-2.0 |
| Microsoft.NET.Test.Sdk | 测试宿主，仅开发/CI | 18.9.0 | MIT，Microsoft |
| coverlet.collector | 覆盖率，仅开发/CI | 10.0.1 | MIT |
| Inno Setup | 生成安装器的构建工具，不随应用源代码运行 | 6.7.3（本机；CI 可使用更新版本） | Inno Setup License |

运行时使用的 Windows 系统字体、系统图标和系统提示音由操作系统提供，仓库和安装包不复制字体文件或来源不明的声音素材。

NuGet 依赖版本集中固定在 `Directory.Packages.props`。发布前应使用构建产物和 NuGet 依赖图复核该清单。
