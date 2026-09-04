#!/usr/bin/env python3
"""Static handoff audit for the Taskronome source tree.

This intentionally checks repository structure and production-source hygiene. It
does not replace compilation or runtime tests; those are run by verify.ps1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


MARKER_RE = re.compile(r"\b(?:TODO|FIXME|NotImplementedException|PLACEHOLDER)\b")
ABSOLUTE_DEV_PATH_RE = re.compile(
    r"(?:[A-Za-z]:[\\/]Users[\\/][^\\/\s]+|D:[\\/]VibeCodingTools)",
    re.IGNORECASE,
)
SOURCE_EXTENSIONS = {".cs", ".xaml", ".ps1", ".yml", ".yaml", ".iss"}
IGNORED_DIRS = {".git", "bin", "obj", "artifacts", "TestResults", "coverage"}

REQUIRED_AUTOMATION_IDS = {
    "MainWindow.xaml": {
        "MainWindow",
        "MainTabs",
        "TasksTab",
        "RunningTab",
        "StatisticsTab",
        "SettingsTab",
        "TasksContent",
        "TaskGrid",
        "NewTaskButton",
        "EditTaskButton",
        "DeleteTaskButton",
        "MoveUpButton",
        "MoveDownButton",
        "ToggleEnabledButton",
        "ReopenTaskButton",
        "ResetCompletionButton",
        "StartRotationButton",
        "RunningContent",
        "CurrentTaskText",
        "RemainingText",
        "ConfirmationPanel",
        "ConfirmationText",
        "ConfirmTaskButton",
        "PauseResumeButton",
        "SkipButton",
        "CompleteButton",
        "StopButton",
        "AbsentPausePanel",
        "SystemPausePanel",
        "SettingsContent",
        "DataDirectoryTextBox",
        "PrivacyTextBlock",
        "KeyboardTextBlock",
        "AlwaysOnTopCheckBox",
        "PlaySoundCheckBox",
        "ShowNotificationCheckBox",
        "MinimizeToTrayCheckBox",
        "TestNotificationButton",
        "StatisticsContent",
        "StatisticsGrid",
        "EventsGrid",
        "StatisticsScopeLabel",
        "StatisticsScopeComboBox",
        "ExportCsvButton",
    },
    "TaskEditorWindow.xaml": {
        "TaskEditorWindow",
        "NameTextBox",
        "NotesTextBox",
        "HoursTextBox",
        "MinutesTextBox",
        "SecondsTextBox",
        "ValidationTextBlock",
        "SaveTaskButton",
        "CancelTaskButton",
    },
}

WINDOWS_APP_RUNTIME_INSIGHTS_RESOURCE = (
    "src/Taskronome.App/Runtime/Microsoft.WindowsAppRuntime.Insights.Resource.dll"
)
WINDOWS_APP_RUNTIME_INSIGHTS_RESOURCE_SHA256 = (
    "5485bbb3675830ab386b02b29c0fbe012764c4f04fb2573cac32985716589db6"
)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig", errors="replace")


def source_files(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.suffix.lower() in SOURCE_EXTENSIONS
        and not any(part in IGNORED_DIRS for part in path.relative_to(root).parts)
    )


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def audit(root: Path) -> tuple[dict[str, object], list[str]]:
    errors: list[str] = []
    required_files = [
        "AGENTS.md",
        "README.md",
        "LICENSE",
        "PRIVACY.md",
        "SECURITY.md",
        "CONTRIBUTING.md",
        "THIRD-PARTY-NOTICES.md",
        "Taskronome.sln",
        "Directory.Packages.props",
        "coverlet.runsettings",
        "scripts/verify.ps1",
        "scripts/package.ps1",
        "scripts/bootstrap-and-verify.ps1",
        "scripts/ui-smoke.ps1",
        "scripts/windows-interactive-acceptance.ps1",
        "src/Taskronome.Core/Taskronome.Core.csproj",
        "src/Taskronome.App/Taskronome.App.csproj",
        "tests/Taskronome.Core.Tests/Taskronome.Core.Tests.csproj",
        "tests/Taskronome.ScenarioRunner/Taskronome.ScenarioRunner.csproj",
        "docs/ASSISTANT_HANDOFF.md",
        "docs/ARCHITECTURE.md",
        "docs/TEST_PLAN.md",
        "docs/TEST_REPORT.md",
        "docs/MANUAL_TEST_CHECKLIST.md",
        "docs/PRIVACY.md",
    ]
    missing = [item for item in required_files if not (root / item).is_file()]
    for item in missing:
        fail(errors, f"required file is missing: {item}")

    project_paths = sorted(root.glob("**/*.csproj"))
    lock_files: list[str] = []
    project_refs: dict[str, list[str]] = {}
    for project_path in project_paths:
        try:
            project = ET.fromstring(read_text(project_path))
        except ET.ParseError as exc:
            fail(errors, f"invalid project XML in {project_path.relative_to(root)}: {exc}")
            continue

        relative_project = project_path.relative_to(root).as_posix()
        lock_path = project_path.with_name("packages.lock.json")
        if not lock_path.is_file():
            fail(errors, f"packages.lock.json is missing next to {relative_project}")
        else:
            lock_files.append(lock_path.relative_to(root).as_posix())

        references = [
            node.attrib.get("Include", "")
            for node in project.findall(".//{*}ProjectReference")
        ]
        project_refs[relative_project] = references
        if relative_project.endswith("Taskronome.Core.csproj") and any(
            "Taskronome.App" in reference for reference in references
        ):
            fail(errors, "Taskronome.Core must not reference Taskronome.App")

    app_references = project_refs.get("src/Taskronome.App/Taskronome.App.csproj", [])
    if not any("Taskronome.Core" in reference for reference in app_references):
        fail(errors, "Taskronome.App must reference Taskronome.Core")

    test_projects = [
        path
        for path in project_paths
        if path.parts[-2] == "tests" or "tests" in path.relative_to(root).parts
    ]
    for test_project in test_projects:
        if not any(
            "Taskronome.Core" in reference
            for reference in project_refs.get(test_project.relative_to(root).as_posix(), [])
        ):
            fail(errors, f"test project does not reference Taskronome.Core: {test_project.relative_to(root)}")

    test_source = "\n".join(
        read_text(path)
        for path in (root / "tests").rglob("*.cs")
        if path.is_file()
    )
    fact_count = len(re.findall(r"\[(?:Fact|Theory)(?:\([^\]]*\))?\]", test_source))
    if fact_count < 50:
        fail(errors, f"deterministic test attribute count is {fact_count}; at least 50 is required")

    source_issues: list[dict[str, object]] = []
    absolute_path_issues: list[dict[str, object]] = []
    for path in source_files(root):
        relative = path.relative_to(root).as_posix()
        if path.name not in {"assistant-source-audit.py", "verify.ps1"}:
            for line_number, line in enumerate(read_text(path).splitlines(), start=1):
                if MARKER_RE.search(line):
                    source_issues.append({"file": relative, "line": line_number})
        for line_number, line in enumerate(read_text(path).splitlines(), start=1):
            if ABSOLUTE_DEV_PATH_RE.search(line):
                absolute_path_issues.append({"file": relative, "line": line_number})

    for issue in source_issues:
        fail(errors, f"unfinished marker in {issue['file']}:{issue['line']}")
    for issue in absolute_path_issues:
        fail(errors, f"developer absolute path in {issue['file']}:{issue['line']}")

    for file_name, required_ids in REQUIRED_AUTOMATION_IDS.items():
        path = root / "src" / "Taskronome.App" / file_name
        if not path.is_file():
            continue
        text = read_text(path)
        present_ids = set(re.findall(r'AutomationProperties\.AutomationId\s*=\s*"([^"]+)"', text))
        for automation_id in sorted(required_ids - present_ids):
            fail(errors, f"required AutomationId is missing in src/Taskronome.App/{file_name}: {automation_id}")

    main_window_text = read_text(root / "src/Taskronome.App/MainWindow.xaml")
    if not re.search(r'\bMinWidth\s*=\s*"400"', main_window_text):
        fail(errors, "MainWindow.xaml must declare MinWidth=400 for the supported compact layout")
    if not re.search(r'\bMinHeight\s*=\s*"300"', main_window_text):
        fail(errors, "MainWindow.xaml must declare MinHeight=300 for the supported compact layout")
    window_services_text = read_text(root / "src/Taskronome.App/Services/WindowServices.cs")
    if not re.search(r'MinimumWidth\s*=\s*400', window_services_text):
        fail(errors, "WindowPlacementService must clamp persisted width at 400")
    if not re.search(r'MinimumHeight\s*=\s*300', window_services_text):
        fail(errors, "WindowPlacementService must clamp persisted height at 300")

    notification_resource = root / WINDOWS_APP_RUNTIME_INSIGHTS_RESOURCE
    notification_resource_sha256: str | None = None
    if not notification_resource.is_file():
        fail(errors, f"required Windows App SDK notification resource is missing: {WINDOWS_APP_RUNTIME_INSIGHTS_RESOURCE}")
    else:
        notification_resource_sha256 = hashlib.sha256(notification_resource.read_bytes()).hexdigest()
        if notification_resource_sha256 != WINDOWS_APP_RUNTIME_INSIGHTS_RESOURCE_SHA256:
            fail(
                errors,
                "Windows App SDK notification resource SHA-256 does not match the audited "
                f"runtime file: {notification_resource_sha256}",
            )

    package_props = root / "Directory.Packages.props"
    package_text = read_text(package_props) if package_props.is_file() else ""
    if "ManagePackageVersionsCentrally" not in package_text:
        fail(errors, "central package management is not enabled")

    solution_text = read_text(root / "Taskronome.sln") if (root / "Taskronome.sln").is_file() else ""
    if solution_text.count('Project("{') != 4:
        fail(errors, "Taskronome.sln must contain the four production/test projects")

    result: dict[str, object] = {
        "status": "passed" if not errors else "failed",
        "repository": str(root),
        "requiredFileCount": len(required_files),
        "projectCount": len(project_paths),
        "lockFiles": lock_files,
        "testAttributeCount": fact_count,
        "sourceMarkerIssues": source_issues,
        "absolutePathIssues": absolute_path_issues,
        "requiredAutomationIds": {
            file_name: sorted(ids) for file_name, ids in REQUIRED_AUTOMATION_IDS.items()
        },
        "windowsAppRuntimeInsightsResource": {
            "path": WINDOWS_APP_RUNTIME_INSIGHTS_RESOURCE,
            "sha256": notification_resource_sha256,
            "expectedSha256": WINDOWS_APP_RUNTIME_INSIGHTS_RESOURCE_SHA256,
        },
        "errors": errors,
    }
    return result, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="optional JSON output path")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    result, errors = audit(root)
    payload = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    print(payload, end="")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
