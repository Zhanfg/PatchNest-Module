#!/usr/bin/env python3
"""Verify that release provenance is bound to a clean, stable Git checkout."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from release_gate.common import GateError, emit, git_head, root_path, run

IN_PROGRESS = (
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "BISECT_LOG",
    "rebase-apply",
    "rebase-merge",
)


def check(root: Path, *, expected_commit: str | None, release_ready: bool) -> dict:
    inside = run(["git", "rev-parse", "--is-inside-work-tree"], cwd=root).stdout.strip()
    if inside != "true":
        raise GateError("root is not a Git work tree")

    head = git_head(root)
    if expected_commit and head != expected_commit:
        raise GateError(f"HEAD {head} does not match expected commit {expected_commit}")

    dirty = run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=root
    ).stdout
    if dirty.strip():
        lines = dirty.splitlines()[:20]
        raise GateError("working tree is not clean:\n" + "\n".join(lines))

    git_dir_text = run(["git", "rev-parse", "--git-dir"], cwd=root).stdout.strip()
    git_dir = (root / git_dir_text).resolve() if not Path(git_dir_text).is_absolute() else Path(git_dir_text)
    active = [name for name in IN_PROGRESS if (git_dir / name).exists()]
    if active:
        raise GateError("Git operation is still in progress: " + ", ".join(active))

    shallow = run(["git", "rev-parse", "--is-shallow-repository"], cwd=root).stdout.strip()
    if shallow not in {"true", "false"}:
        raise GateError("cannot determine whether repository is shallow")
    if release_ready and shallow == "true":
        raise GateError("release-ready verification requires a non-shallow checkout")

    branch = run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], cwd=root, check=False)
    branch_name = branch.stdout.strip() or "DETACHED"
    return {
        "gate": "git-clean",
        "status": "pass",
        "head": head,
        "branch": branch_name,
        "shallow": shallow == "true",
        "summary": f"Git tree clean at {head}",
        "details": [f"branch={branch_name}", f"shallow={shallow}"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--expected-commit")
    parser.add_argument("--release-ready", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        emit(check(root_path(args.root), expected_commit=args.expected_commit, release_ready=args.release_ready), as_json=args.json)
        return 0
    except GateError as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
