#!/usr/bin/env python3
"""Offline safety audit for PatchNest-Module.

No network, root access, Android device, or GitHub Actions runner is required.
The default is report-only; ``--enforce`` fails on blockers or errors.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable, Sequence


@dataclasses.dataclass(frozen=True)
class Finding:
    severity: str
    check_id: str
    path: str
    line: int | None
    message: str
    evidence: str = ""

    def as_dict(self) -> dict[str, object]:
        return dataclasses.asdict(self)


SEVERITY_ORDER = {"info": 0, "warning": 1, "error": 2, "blocker": 3}
EXCLUDED_DIRS = {".git", "node_modules", "dist", "build", "out", "audit-output", ".venv", "venv", "__pycache__"}
TEXT_SUFFIXES = {".sh", ".js", ".mjs", ".cjs", ".json", ".md", ".yml", ".yaml", ".py", ".html", ".css"}


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--output-dir", default="audit-output")
    parser.add_argument("--enforce", action="store_true")
    parser.add_argument("--no-syntax", action="store_true")
    return parser.parse_args(argv)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def iter_text_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if any(part in EXCLUDED_DIRS for part in path.parts):
            continue
        yield path


def add_regex_findings(
    findings: list[Finding],
    *,
    root: Path,
    path: Path,
    text: str,
    pattern: str,
    severity: str,
    check_id: str,
    message: str,
    flags: int = 0,
) -> None:
    for match in re.finditer(pattern, text, flags):
        findings.append(
            Finding(
                severity,
                check_id,
                str(path.relative_to(root)),
                line_number(text, match.start()),
                message,
                match.group(0).strip().replace("\n", " ")[:240],
            )
        )


def function_body(text: str, name: str) -> tuple[str, int] | None:
    match = re.search(rf"(?ms)^{re.escape(name)}\(\)\s*\{{(?P<body>.*?)^\}}", text)
    if not match:
        return None
    return match.group("body"), match.start("body")


def check_boot_partition_selection(root: Path, findings: list[Finding]) -> None:
    target = root / "module/patch/boot_target.sh"
    extract = root / "module/patch/boot_extract.sh"
    guard = root / "module/patch/flash_guard.sh"

    if target.exists() and extract.exists() and guard.exists():
        target_text = read_text(target)
        extract_text = read_text(extract)
        guard_text = read_text(guard)
        if "find_kernel_boot_image" not in extract_text or '. "$MODPATH/boot_target.sh"' not in extract_text:
            findings.append(Finding("blocker", "BOOT-001", str(extract.relative_to(root)), None, "WebUI discovery does not use the boot-only target resolver"))
        parsed = function_body(target_text, "find_kernel_boot_image")
        if not parsed:
            findings.append(Finding("blocker", "BOOT-002", str(target.relative_to(root)), None, "find_kernel_boot_image() was not found"))
        else:
            body, start = parsed
            for forbidden in ("vendor_boot", "init_boot"):
                # Comments may explain excluded partitions; only command lines
                # that pass them to find_block are blocking.
                match = re.search(rf"(?m)^[^#\n]*find_block[^\n]*\b{forbidden}\b", body)
                if match:
                    findings.append(Finding("blocker", "BOOT-003", str(target.relative_to(root)), line_number(target_text, start + match.start()), f"boot-only resolver searches {forbidden}", match.group(0).strip()))
        for forbidden in ("vendor_boot", "init_boot"):
            if forbidden not in guard_text:
                findings.append(Finding("blocker", "BOOT-004", str(guard.relative_to(root)), None, f"flash guard does not explicitly reject {forbidden}"))
        return

    # Compatibility fallback for older branches and unit-test fixtures.
    util = root / "module/patch/util_functions.sh"
    if not util.exists():
        findings.append(Finding("blocker", "BOOT-001", str(util.relative_to(root)), None, "boot helper is missing"))
        return
    text = read_text(util)
    parsed = function_body(text, "find_boot_image")
    if not parsed:
        findings.append(Finding("blocker", "BOOT-002", str(util.relative_to(root)), None, "find_boot_image() was not found"))
        return
    body, start = parsed
    fallback = re.search(r"vendor_boot|init_boot", body)
    if fallback:
        findings.append(Finding("blocker", "BOOT-003", str(util.relative_to(root)), line_number(text, start + fallback.start()), "KernelPatch must not silently fall back from boot to vendor_boot/init_boot", fallback.group(0)))


def check_flash_contract(root: Path, findings: list[Finding]) -> None:
    path = root / "module/patch/flash_guard.sh"
    if not path.exists():
        path = root / "module/patch/util_functions.sh"
    if not path.exists():
        findings.append(Finding("blocker", "FLASH-000", str(path.relative_to(root)), None, "no flash implementation found"))
        return
    text = read_text(path)
    required = {
        "FLASH-001": ("verify_block_image_prefix", "block writes have no readback verifier"),
        "FLASH-002": ("sha256sum", "flash verification has no SHA-256 comparison"),
        "FLASH-003": ("blockdev --getsize64", "target capacity is not checked"),
        "FLASH-004": ("blockdev --getro", "target read-only state is not checked"),
        "FLASH-006": ("Character-device boot flashing is not verified and is disabled", "unverified character-device flashing is not fail-closed"),
    }
    for check_id, (token, message) in required.items():
        if token not in text:
            findings.append(Finding("blocker", check_id, str(path.relative_to(root)), None, message, token))
    if "Not block or char device, storing image" in text:
        findings.append(Finding("error", "FLASH-005", str(path.relative_to(root)), None, "direct flash helper can silently treat a regular file as a successful device write"))


def check_backup_contract(root: Path, findings: list[Finding]) -> None:
    patch_path = root / "module/patch/boot_patch.sh"
    unpatch_path = root / "module/patch/boot_unpatch.sh"
    if patch_path.exists():
        text = read_text(patch_path)
        if not re.search(r"date \+%[yY][^\n]*%S", text):
            findings.append(Finding("error", "BACKUP-001", str(patch_path.relative_to(root)), None, "backup names lack second-level uniqueness"))
        required = {
            "BACKUP-002": ("backup_sha256", "backup manifest does not persist a digest"),
            "BACKUP-003": ("backup_verified", "backup manifest does not persist verification state"),
            "BACKUP-004": ("validate_boot_image", "backup/repacked image is not independently unpack-tested"),
            "BACKUP-005": ("Refusing to replace recovery backup with an already patched boot image", "forced backup can overwrite the recovery base with patched content"),
        }
        for check_id, (token, message) in required.items():
            if token not in text:
                findings.append(Finding("blocker", check_id, str(patch_path.relative_to(root)), None, message, token))
    if unpatch_path.exists():
        text = read_text(unpatch_path)
        required = {
            "RECOVERY-001": ("backup_verified", "recovery does not require a verified manifest"),
            "RECOVERY-002": ("backup_sha256", "recovery does not validate the backup digest"),
            "RECOVERY-003": ("partition_name_for_target", "recovery is not bound to the logical target partition"),
            "RECOVERY-005": ("rm -f kernel kernel.ori new-boot.img", "stale work artifacts are not cleared"),
        }
        for check_id, (token, message) in required.items():
            if token not in text:
                findings.append(Finding("blocker", check_id, str(unpatch_path.relative_to(root)), None, message, token))
        add_regex_findings(findings, root=root, path=unpatch_path, text=text, pattern=r"(?im)^.*found backup boot\.img.*recovery.*$", severity="error", check_id="RECOVERY-004", message="unpatch may reuse a stale work-directory image")


def check_shell_hazards(root: Path, findings: list[Finding]) -> None:
    for path in iter_text_files(root):
        if path.suffix.lower() != ".sh":
            continue
        text = read_text(path)
        add_regex_findings(findings, root=root, path=path, text=text, pattern=r"(?m)^[^#\n]*\beval\b.*$", severity="warning", check_id="SHELL-001", message="root shell path contains eval; verify variable name and value constraints")
        add_regex_findings(findings, root=root, path=path, text=text, pattern=r"(?m)\brm\s+-rf\s+\$[A-Za-z_][A-Za-z0-9_]*\b", severity="error", check_id="SHELL-002", message="unquoted variable passed to rm -rf")
        add_regex_findings(findings, root=root, path=path, text=text, pattern=r"(?m)\bdd\b[^\n]*\bof=\$[A-Za-z_][A-Za-z0-9_]*\b", severity="error", check_id="SHELL-003", message="unquoted dd output target")
        if path.name == "boot_patch.sh" and re.search(r"(?m)^\s*set\s+-x\b", text):
            findings.append(Finding("blocker", "SHELL-004", str(path.relative_to(root)), None, "boot patcher traces potentially sensitive kptools arguments"))


def check_webui_bridges(root: Path, findings: list[Finding]) -> None:
    webui = root / "webui"
    if not webui.exists():
        return
    for path in sorted(webui.rglob("*.js")):
        if any(part in EXCLUDED_DIRS for part in path.parts):
            continue
        text = read_text(path)
        add_regex_findings(findings, root=root, path=path, text=text, pattern=r"(?s)(?:innerHTML\s*=|insertAdjacentHTML\s*\()[^;\n]*\$\{", severity="error", check_id="WEBUI-001", message="dynamic value is interpolated into an HTML sink")
        for match in re.finditer(r"(?s)\bexec\s*\(\s*`(?P<cmd>.*?)`", text):
            command = match.group("cmd")
            if "${" not in command:
                continue
            unescaped = re.findall(r"\$\{(?!escapeShell\()[^}]+\}", command)
            if unescaped:
                findings.append(Finding("warning", "WEBUI-002", str(path.relative_to(root)), line_number(text, match.start()), "privileged exec() interpolation is not visibly wrapped by escapeShell", " ".join(unescaped)[:240]))


def check_repository_hygiene(root: Path, findings: list[Finding]) -> None:
    forbidden = {".log", ".tar", ".gz", ".tgz", ".7z", ".rar"}
    for path in root.rglob("*"):
        if not path.is_file() or any(part in EXCLUDED_DIRS for part in path.parts):
            continue
        relative = str(path.relative_to(root))
        if path.suffix.lower() in forbidden and not relative.startswith("module/"):
            findings.append(Finding("warning", "HYGIENE-001", relative, None, "archive or log is checked into source"))
        if path.stat().st_size > 20 * 1024 * 1024:
            findings.append(Finding("warning", "HYGIENE-002", relative, None, "source file exceeds 20 MiB", str(path.stat().st_size)))


def run_syntax_checks(root: Path, findings: list[Finding]) -> None:
    shell = shutil.which("bash") or shutil.which("sh")
    node = shutil.which("node")
    for path in iter_text_files(root):
        command: list[str] | None = None
        check_id = ""
        if path.suffix.lower() == ".sh" and shell:
            command, check_id = [shell, "-n", str(path)], "SYNTAX-SH"
        elif path.suffix.lower() in {".js", ".mjs", ".cjs"} and node:
            command, check_id = [node, "--check", str(path)], "SYNTAX-JS"
        if not command:
            continue
        result = subprocess.run(command, cwd=root, text=True, capture_output=True, check=False)
        if result.returncode != 0:
            findings.append(Finding("error", check_id, str(path.relative_to(root)), None, f"{' '.join(command[:2])} failed", (result.stderr or result.stdout).strip()[:500]))


def deduplicate(findings: Iterable[Finding]) -> list[Finding]:
    unique = {(item.severity, item.check_id, item.path, item.line, item.message, item.evidence): item for item in findings}
    return sorted(unique.values(), key=lambda item: (-SEVERITY_ORDER[item.severity], item.path, item.line or 0, item.check_id))


def render_markdown(root: Path, findings: Sequence[Finding]) -> str:
    counts = {severity: 0 for severity in SEVERITY_ORDER}
    for finding in findings:
        counts[finding.severity] += 1
    lines = ["# PatchNest offline audit report", "", f"Generated: {dt.datetime.now(dt.timezone.utc).isoformat()}", f"Repository: `{root}`", "", "| Severity | Count |", "|---|---:|"]
    for severity in ("blocker", "error", "warning", "info"):
        lines.append(f"| {severity} | {counts[severity]} |")
    lines.extend(["", "## Findings", ""])
    if not findings:
        lines.append("No findings.")
    for finding in findings:
        location = finding.path + (f":{finding.line}" if finding.line else "")
        lines.extend([f"### [{finding.severity.upper()}] {finding.check_id}", "", f"- Location: `{location}`", f"- {finding.message}"])
        if finding.evidence:
            lines.append(f"- Evidence: `{finding.evidence.replace('`', chr(92) + '`')}`")
        lines.append("")
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    root = Path(args.root).resolve()
    if not (root / "module").exists() or not (root / "webui").exists():
        print(f"error: {root} does not look like PatchNest-Module", file=sys.stderr)
        return 2
    findings: list[Finding] = []
    check_boot_partition_selection(root, findings)
    check_flash_contract(root, findings)
    check_backup_contract(root, findings)
    check_shell_hazards(root, findings)
    check_webui_bridges(root, findings)
    check_repository_hygiene(root, findings)
    if not args.no_syntax:
        run_syntax_checks(root, findings)
    final = deduplicate(findings)

    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = root / output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {"schemaVersion": 1, "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "root": str(root), "findings": [item.as_dict() for item in final]}
    (output_dir / "offline-audit.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (output_dir / "offline-audit.md").write_text(render_markdown(root, final), encoding="utf-8")

    counts = {severity: 0 for severity in SEVERITY_ORDER}
    for finding in final:
        counts[finding.severity] += 1
    print("offline audit: " + ", ".join(f"{severity}={counts[severity]}" for severity in ("blocker", "error", "warning", "info")))
    if args.enforce and any(item.severity in {"blocker", "error"} for item in final):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
