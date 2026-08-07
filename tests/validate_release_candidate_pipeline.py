#!/usr/bin/env python3
"""Lock the release-candidate wrapper to the complete evidence-gated pipeline."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts" / "build_release_candidate.sh"
EVIDENCE_GATE = ROOT / "scripts" / "run_evidence_gate_checks.sh"


def require(text: str, token: str, source: Path, *, start: int = 0) -> int:
    position = text.find(token, start)
    if position < 0:
        raise SystemExit(f"{source}: missing required token: {token}")
    return position


def main() -> int:
    wrapper = WRAPPER.read_text(encoding="utf-8")
    evidence = EVIDENCE_GATE.read_text(encoding="utf-8")

    signing = require(
        wrapper,
        "python3 scripts/verify_signing_key_policy.py --root \"$ROOT\" --release-ready",
        WRAPPER,
    )
    matrix = require(wrapper, "MATRIX_DIR=${PATCHNEST_MATRIX_DIR:-}", WRAPPER)
    build = require(wrapper, "bash \"$ROOT/build.sh\"", WRAPPER)
    gate = require(wrapper, "bash \"$ROOT/scripts/run_evidence_gate_checks.sh\"", WRAPPER)
    candidate = require(wrapper, "\"$ROOT/out/PatchNest-Module.zip\"", WRAPPER, start=gate)
    matrix_arg = require(wrapper, "\"$MATRIX_DIR\"", WRAPPER, start=candidate + 1)

    if not signing < matrix < build < gate < candidate < matrix_arg:
        raise SystemExit("build_release_candidate.sh: release pipeline order is unsafe")
    if "run_release_gate_checks.sh" in wrapper:
        raise SystemExit("build_release_candidate.sh: wrapper bypasses the complete evidence gate")
    if "exec bash \"$ROOT/build.sh\"" in wrapper:
        raise SystemExit("build_release_candidate.sh: exec prevents post-build evidence validation")

    base_gate = require(evidence, "scripts/run_release_gate_checks.sh", EVIDENCE_GATE)
    binding = require(evidence, "check_matrix_candidate_binding.py", EVIDENCE_GATE)
    if base_gate >= binding:
        raise SystemExit("run_evidence_gate_checks.sh: candidate binding runs before base gates")
    require(evidence, "--release-ready", EVIDENCE_GATE)
    require(evidence, "--candidate \"$CANDIDATE\"", EVIDENCE_GATE)
    require(evidence, "--matrix-dir \"$MATRIX_DIR\"", EVIDENCE_GATE)

    print("Release-candidate pipeline contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
