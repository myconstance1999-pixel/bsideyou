#!/usr/bin/env bash
# Build + run the in-house test executable (ADR-009). Exit != 0 = gate failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Task-local support for the WHOLE run. BSideTestRunner writes AppLog diagnostics
# (e.g. "desktop host installation strategy=test-*") and the control-state
# regression writes preferences under BSIDEMAC_SUPPORT_DIR; without an override
# both append to the REAL ~/Library/Application Support/BSideMac/control.log.
# Keep every test-side support/preference/log write inside one temp dir and remove
# it on ANY exit (success or error) so the user's real preferences and logs are
# never touched by a gate run.
TEST_SUPPORT="$(mktemp -d "${TMPDIR:-/tmp}/bsidemac-control-regression.XXXXXX")"
cleanup() {
    local rc=$?
    rm -rf "$TEST_SUPPORT" || true
    exit "$rc"
}
trap cleanup EXIT

swift build --product BSideTestRunner 2>&1 | tail -2
BSIDEMAC_SUPPORT_DIR="$TEST_SUPPORT" .build/debug/BSideTestRunner
swift build --product BSideControlApp 2>&1 | tail -2
BSIDEMAC_SUPPORT_DIR="$TEST_SUPPORT" .build/debug/BSideControlApp --verify-control-state
