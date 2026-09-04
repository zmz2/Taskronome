# Windows App Runtime satellite provenance

This file documents the binary beside it. The DLL is the x64
`Microsoft.WindowsAppRuntime.Insights.Resource.dll` from the installed
Microsoft Windows App Runtime 2.4.0.0 package, matching the locked
`Microsoft.WindowsAppSDK` 2.4.0 dependency used by Taskronome.

- Package family: `Microsoft.WindowsAppRuntime.2_2.4.0.0_x64__8wekyb3d8bbwe`
- Product version: `2.4.0.0`
- SHA-256: `5485bbb3675830ab386b02b29c0fbe012764c4f04fb2573cac32985716589db6`
- License: Microsoft Windows App SDK, MIT; see `THIRD-PARTY-NOTICES.md`.

The file is included because the 2.4.0 Foundation NuGet component used by
the self-contained build does not carry this runtime satellite, while the
self-contained `Microsoft.WindowsAppRuntime.dll` attempts to load it during
bootstrap/notification registration. It is copied to the application root by
the app project and is not a user-facing feature or test backdoor.
