#!/usr/bin/env python3
"""PatchNest offline repository audit.

This scanner is intentionally independent from GitHub Actions. It can run on a
local checkout with Python 3 and, when available, local ``sh``, ``bash`` and
``node`` executables. The default mode is report-only and never modifies the
checkout. Pass ``--enforce`` to return a non-zero status when a blocking
invariant fails.

The scanner focuses on release integrity and recovery safety. It does not test
or improve root-hiding, anti-detection, or policy-bypass behavior.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
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
SHELL_SUFFIXES = {".sh"}
JS_SUFFIXES = {".js", ".mjs", ".cjs"}
TEXT_SUFFIXES = {
    ".sh",
    ".js",
    ".mjs",
    ".cjs",
    ".json",
    ".md",
    ".yml",
    ".yaml",
    ".py",
    ".html",
    ".css",
}

EXCLUDED_DIRS = {
    ".git",
    "node_modules",
    "dist",
    "build",
    "out",
    ".venv",
    "venv",
    "__pycache__",
}


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="repository root (default: inferred from this script)",
    )
    parser.add_argument(
        "--output-dir",
        default="audit-output",
        help="directory for JSON and Markdown reports, relative to root",
    )
    parser.add_argument(
        "--enforce",
        action="store_true",
        help="exit non-zero when an error or blocker is present",
    )
    parser.add_argument(
        "--no-syntax",
        action="store_true",
        help="skip optional local shell/JavaScript parser checks",
    )
    return parser.parse_args(argv)


def iter_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in EXCLUDED_DIRS for part in path.parts):
            continue
        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        yield path


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8", errors="replace")


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


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
        snippet = match.group(0).strip().replace("\n", " ")[:240]
        findings.append(
            Finding(
                severity=severity,
                check_id=check_id,
                path=str(path.relative_to(root)),
                line=line_number(text, match.start()),
                message=message,
                evidence=snippet,
            )
        )


def check_boot_partition_selection(root: Path, findings: list[Finding]) -> None:
    path = root / "module/patch/util_functions.sh"
    if not path.exists():
        findings.append(
            Finding("blocker", "BOOT-001", str(path.relative_to(root)), None, "boot helper is missing")
        )
        return

    text = read_text(path)
    function_match = re.search(
        r"(?ms)^find_boot_image\(\)\s*\{(?P<body>.*?)^\}", text
    )
    if not function_match:
        findings.append(
            Finding("blocker", "BOOT-002", str(path.relative_to(root)), None, "find_boot_image() was not found")
        )
        return

    body = function_match.group("body")
    fallback = re.search(r"vendor_boot|init_boot", body)
    if fallback:
        findings.append(
            Finding(
                "blocker",
                "BOOT-003",
                str(path.relative_to(root)),
                line_number(text, function_match.start("body") + fallback.start()),
                "KernelPatch must not silently fall back from boot to vendor_boot/init_boot; those images do not provide the kernel payload expected by this patcher.",
                fallback.group(0),
            )
        )


def check_flash_contract(root: Path, findings: list[Finding]) -> None:
    path = root / "module/patch/util_functions.sh"
    if not path.exists():
        return
    text = read_text(path)

    required_tokens = {
        "FLASH-001": ("verify_block_image_prefix", "block-device writes are not followed by a dedicated readback verifier"),
        "FLASH-002": ("sha256sum", "flash verification has no SHA-256 comparison"),
        "FLASH-003": ("blockdev --getsize64", "target block-device capacity is not checked"),
        "FLASH-004": ("blockdev --getro", "target read-only state is not checked"),
    }
    for check_id, (token, message) in required_tokens.items():
        if token not in text:
            findings.append(Finding("blocker", check_id, str(path.relative_to(root)), None, message, token))

    function_match = re.search(r"(?ms)^flash_image\(\)\s*\{(?P<body>.*?)^\}", text)
    if function_match and re.search(r"(?m)^\s*else\s*\{?\s*$", function_match.group("body")):
        if "Not block or char device, storing image" in function_match.group("body"):
            findings.append(
                Finding(
                    "error",
                    "FLASH-005",
                    str(path.relative_to(root)),
                    line_number(text, function_match.start("body")),
                    "flash_image() accepts regular files. Direct-to-device callers must reject non-device targets before reporting flash success.",
                    "Not block or char device, storing image",
                )
            )


def check_backup_contract(root: Path, findings: list[Finding]) -> None:
    patch_path = root / "module/patch/boot_patch.sh"
    unpatch_path = root / "module/patch/boot_unpatch.sh"

    if patch_path.exists():
        text = read_text(patch_path)
        if not re.search(r"date \+%[yY].*%S", text):
            findings.append(
                Finding(
                    "error",
                    "BACKUP-001",
                    str(patch_path.relative_to(root)),
                    None,
                    "backup names do not include second-level uniqueness",
                )
            )
        for token, check_id, message in [
            ("backup_sha256", "BACKUP-002", "backup manifest does not persist a backup digest"),
            ("backup_verified", "BACKUP-003", "backup manifest does not persist verification state"),
            ("magiskboot unpack", "BACKUP-004", "backup or repacked image is not unpack-tested"),
        ]:
            if token not in text:
                findings.append(Finding("blocker", check_id, str(patch_path.relative_to(root)), None, message, token))

    if unpatch_path.exists():
        text = read_text(unpatch_path)
        for token, check_id, message in [
            ("backup_verified", "RECOVERY-001", "recovery does not require a verified manifest"),
            ("backup_sha256", "RECOVERY-002", "recovery does not validate the stored backup digest"),
            ("boot_image", "RECOVERY-003", "recovery is not bound to a recorded target partition"),
        ]:
            if token not in text:
                findings.append(Finding("blocker", check_id, str(unpatch_path.relative_to(root)), None, message, token))

        stale_patterns = [
            r"found backup boot\.img.*recovery",
            r"\[\s*-f\s+[\"']?new-boot\.img",
        ]
        for pattern in stale_patterns:
            add_regex_findings(
                findings,
                root=root,
                path=unpatch_path,
                text=text,
                pattern=pattern,
                severity="error",
                check_id="RECOVERY-004",
                message="unpatch/recovery may reuse a stale new-boot.img from an interrupted operation",
                flags=re.IGNORECASE,
            )


def check_shell_hazards(root: Path, findings: list[Finding]) -> None:
    for path in iter_files(root):
        if path.suffix.lower() not in SHELL_SUFFIXES:
            continue
        text = read_text(path)
        relative = str(path.relative_to(root))

        # ``eval`` is not automatically a vulnerability, but every use in a
        # root installer is review-sensitive. Mark it as a warning rather than
        # a blocker and preserve the exact line for manual review.
        add_regex_findings(
            findings,
            root=root,
            path=path,
            text=text,
            pattern=r"(?m)^[^#\n]*\beval\b.*$",
            severity="warning",
            check_id="SHELL-001",
            message="root shell path contains eval; confirm both variable name and value are constrained",
        )

        add_regex_findings(
            findings,
            root=root,
            path=path,
            text=text,
            pattern=r"(?m)\brm\s+-rf\s+\$[A-Za-z_][A-Za-z0-9_]*\b",
            severity="error",
            check_id="SHELL-002",
            message="unquoted variable passed to rm -rf",
        )

        add_regex_findings(
            findings,
            root=root,
            path=path,
            text=text,
            pattern=r"(?m)\bdd\b[^\n]*\bof=\$[A-Za-z_][A-Za-z0-9_]*\b",
            severity="error",
            check_id="SHELL-003",
            message="unquoted dd output target",
        )

        if relative.startswith("module/") and re.search(r"(?m)^\s*set\s+-x\b", text):
            findings.append(
                Finding(
                    "warning",
                    "SHELL-004",
                    relative,
                    None,
                    "installer enables shell tracing; secrets or paths may leak into logs",
                )
            )


def check_webui_bridges(root: Path, findings: list[Finding]) -> None:
    webui = root / "webui"
    if not webui.exists():
        return

    for path in sorted(webui.rglob("*.js")):
        if any(part in EXCLUDED_DIRS for part in path.parts):
            continue
        text = read_text(path)

        # Dynamic HTML insertion is review-sensitive because repository data,
        # manifests, logs and remote catalog metadata may become attacker-
        # controlled inputs. Static literals are not reported.
        add_regex_findings(
            findings,
            root=root,
            path=path,
            text=text,
            pattern=r"(?s)(?:innerHTML\s*=|insertAdjacentHTML\s*\()[^;\n]*\$\{",
            severity="error",
            check_id="WEBUI-001",
            message="dynamic value is interpolated into an HTML sink",
        )

        # Record template-literal commands sent through the privileged bridge.
        # This is intentionally a warning: values wrapped by escapeShell() can
        # be safe, while hand-built fragments require manual review.
        for match in re.finditer(r"(?s)\bexec\s*\(\s*`(?P<cmd>.*?)`", text):
            cmd = match.group("cmd")
            if "${" not in cmd:
                continue
            unescaped = re.findall(r"\$\{(?!escapeShell\()[^}]+\}", cmd)
            if unescaped:
                findings.append(
                    Finding(
                        "warning",
                        "WEBUI-002",
                        str(path.relative_to(root)),
                        line_number(text, match.start()),
                        "privileged exec() template contains interpolation not visibly wrapped by escapeShell(); manually verify it is a constant or validated identifier",
                        " ".join(unescaped)[:240],
                    )
                )


def check_repository_hygiene(root: Path, findings: list[Finding]) -> None:
    forbidden_suffixes = {".log", ".tar", ".gz", ".tgz", ".7z", ".rar"}
    for path in root.rglob("*"):
        if not path.is_file() or any(part in EXCLUDED_DIRS for part in path.parts):
            continue
        relative = str(path.relative_to(root))
        if path.suffix.lower() in forbidden_suffixes and not relative.startswith("module/"):
            findings.append(
                Finding(
                    "warning",
                    "HYGIENE-001",
                    relative,
                    None,
                    "archive or log is checked into source; confirm it is an intentional release fixture",
                )
            )
        if path.stat().st_size > 20 * 1024 * 1024:
            findings.append(
                Finding(
                    "warning",
                    "HYGIENE-002",
                    relative,
                    None,
                    "source file exceeds 20 MiB",
                    str(path.stat().st_size),
                )
            )


def run_syntax_checks(root: Path, findings: list[Finding]) -> None:
    shells = [tool for tool in ("sh", "bash") if shutil.which(tool)]
    node = shutil.which("node")

    for path in iter_files(root):
        relative = str(path.relative_to(root))
        if path.suffix.lower() in SHELL_SUFFIXES and shells:
            # Android scripts may intentionally use BusyBox ash extensions.
            # Prefer bash -n when available, then report sh -n as informational.
            tool = "bash" if "bash" in shells else shells[0]
            result = subprocess.run(
                [tool, "-n", str(path)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                findings.append(
                    Finding(
                        "error",
                        "SYNTAX-SH",
                        relative,
                        None,
                        f"{tool} -n failed",
                        (result.stderr or result.stdout).strip()[:500],
                    )
                )
        elif path.suffix.lower() in JS_SUFFIXES and node:
            result = subprocess.run(
                [node, "--check", str(path)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                findings.append(
                    Finding(
                        "error",
                        "SYNTAX-JS",
                        relative,
                        None,
                        "node --check failed",
                        (result.stderr or result.stdout).strip()[:500],
                    )
                )


def deduplicate(findings: Iterable[Finding]) -> list[Finding]:
    seen: set[tuple[object, ...]] = set()
    result: list[Finding] = []
    for finding in findings:
        key = (
            finding.severity,
            finding.check_id,
            finding.path,
            finding.line,
            finding.message,
            finding.evidence,
        )
        if key in seen:
            continue
        seen.add(key)
        result.append(finding)
    result.sort(
        key=lambda item: (
            -SEVERITY_ORDER[item.severity],
            item.path,
            item.line or 0,
            item.check_id,
        )
    )
    return result


def render_markdown(root: Path, findings: Sequence[Finding]) -> str:
    counts = {severity: 0 for severity in SEVERITY_ORDER}
    for finding in findings:
        counts[finding.severity] += 1

    lines = [
        "# PatchNest offline audit report",
        "",
        f"Generated: {dt.datetime.now(dt.timezone.utc).isoformat()}",
        f"Repository: `{root}`",
        "",
        "## Summary",
        "",
        "| Severity | Count |",
        "|---|---:|",
    ]
    for severity in ("blocker", "error", "warning", "info"):
        lines.append(f"| {severity} | {counts[severity]} |")

    lines.extend(["", "## Findings", ""])
    if not findings:
        lines.append("No findings.")
        return "\n".join(lines) + "\n"

    for finding in findings:
        location = finding.path
        if finding.line:
            location += f":{finding.line}"
        lines.extend(
            [
                f"### [{finding.severity.upper()}] {finding.check_id}",
                "",
                f"- Location: `{location}`",
                f"- {finding.message}",
            ]
        )
        if finding.evidence:
            lines.append(f"- Evidence: `{finding.evidence.replace('`', '\\`')}`")
        lines.append("")

    return "\n".join(lines)


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

    payload = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "root": str(root),
        "findings": [finding.as_dict() for finding in final],
    }
    json_path = output_dir / "offline-audit.json"
    md_path = output_dir / "offline-audit.md"
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(root, final), encoding="utf-8")

    counts = {severity: 0 for severity in SEVERITY_ORDER}
    for finding in final:
        counts[finding.severity] += 1
    print(
        "offline audit: "
        + ", ".join(f"{severity}={counts[severity]}" for severity in ("blocker", "error", "warning", "info"))
    )
    print(f"JSON: {json_path}")
    print(f"Markdown: {md_path}")

    if args.enforce and any(f.severity in {"blocker", "error"} for f in final):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
