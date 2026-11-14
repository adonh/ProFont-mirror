#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/profont-run-test.XXXXXX")"
MOCK_BIN="$TEST_ROOT/bin"
PREK_STUB="$TEST_ROOT/prek"
REAL_ENV="$(command -v env)"

trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$MOCK_BIN"
ln -s "$BASH" "$MOCK_BIN/bash"
for tool in dirname grep ln touch; do
  ln -s "$(command -v "$tool")" "$MOCK_BIN/$tool"
done

cat > "$MOCK_BIN/uv" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
[[ "$PWD" == "$PROJECT" ]] || exit 8
case "$*" in
  "tool install prek"|"tool upgrade prek")
    if [[ "$*" == "tool upgrade prek" && ! -f "$UV_STATE" ]]; then exit 7; fi
    [[ "${FAIL_INSTALL:-0}" != 1 ]] || exit 7
    touch "$UV_STATE"
    ln -sf "$PREK_STUB" "$MOCK_BIN/prek"
    ;;
  "tool run prek install"|"tool run prek install -f")
    [[ -f "$UV_STATE" && "${FAIL_HOOK:-0}" != 1 ]] || exit 7
    ;;
  "tool run prek run "*)
    [[ -f "$UV_STATE" ]] || exit 7
    ;;
  *)
    printf 'unexpected uv invocation: %s\n' "$*" >&2
    exit 9
    ;;
esac
BASH

cat > "$PREK_STUB" <<'BASH'
#!/usr/bin/env bash
exit 0
BASH
chmod +x "$MOCK_BIN/uv" "$PREK_STUB"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -f "$CASE/output.log" ]]; then cat "$CASE/output.log" >&2; fi
  exit 1
}

setup_case() {
  CASE="$TEST_ROOT/$1"
  PROJECT="$CASE/repository with spaces"
  mkdir -p "$PROJECT/scripts" "$PROJECT/tests"
  PROJECT="$(cd "$PROJECT" && pwd)"
  CALLS="$CASE/calls"
  UV_STATE="$CASE/uv-installed"
  rm -f "$MOCK_BIN/prek"
  cp "$ROOT/run" "$PROJECT/run"
  cat > "$PROJECT/scripts/mirror.bash" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf 'mirror %s\n' "$*" >> "$CALLS"
BASH
  chmod +x "$PROJECT/scripts/mirror.bash"
  cat > "$PROJECT/tests/tests" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf 'tests %s\n' "$*" >> "$CALLS"
BASH
  chmod +x "$PROJECT/tests/tests"
}

run_driver() {
  "$REAL_ENV" PATH="$MOCK_BIN" BASH_ENV=/dev/null PROJECT="$PROJECT" \
    CALLS="$CALLS" UV_STATE="$UV_STATE" PREK_STUB="$PREK_STUB" MOCK_BIN="$MOCK_BIN" \
    FAIL_INSTALL="${FAIL_INSTALL:-0}" FAIL_HOOK="${FAIL_HOOK:-0}" \
    "$BASH" "$PROJECT/run" "$@" > "$CASE/output.log" 2>&1
}

seed_installed_tool() {
  touch "$UV_STATE"
  ln -sf "$PREK_STUB" "$MOCK_BIN/prek"
}

setup_case fresh-setup
run_driver setup || fail "fresh setup failed with prek absent"
grep -Fxq 'tool install prek' "$CALLS" || fail "fresh setup did not install prek"
grep -Fxq 'tool run prek install' "$CALLS" || fail "fresh setup did not install hooks"
[[ -f "$PROJECT/._done-setup-prek" ]] || fail "successful setup did not mark completion"
if grep -q '^mirror ' "$CALLS"; then fail "setup dispatched to the mirror"; fi
printf 'PASS: fresh setup installs prek when the executable is absent\n'

setup_case installed-setup
seed_installed_tool
run_driver setup || fail "setup failed with prek installed"
grep -Fxq 'tool upgrade prek' "$CALLS" || fail "setup did not upgrade installed prek"
printf 'PASS: setup upgrades prek when the executable is present\n'

setup_case pre-commit-hook
mkdir -p "$PROJECT/.git/hooks"
printf '#!/bin/sh\nexec pre-commit run "$@"\n' > "$PROJECT/.git/hooks/pre-commit"
run_driver setup || fail "setup failed to replace the matching pre-commit shim"
grep -Fxq 'tool run prek install -f' "$CALLS" ||
  fail "matching pre-commit shim did not request forced installation"
printf 'PASS: matching pre-commit shims request forced installation\n'

setup_case custom-hook
mkdir -p "$PROJECT/.git/hooks"
printf 'custom hook bytes\n' > "$PROJECT/.git/hooks/pre-commit"
cp "$PROJECT/.git/hooks/pre-commit" "$CASE/original-hook"
run_driver setup || fail "setup failed with an unrelated custom hook"
if grep -q '^tool run prek install' "$CALLS"; then
  fail "setup attempted to replace an unrelated custom hook"
fi
cmp -s "$CASE/original-hook" "$PROJECT/.git/hooks/pre-commit" ||
  fail "runner modified the unrelated custom hook"
printf 'PASS: unrelated custom hooks are left untouched\n'

setup_case cached-setup
seed_installed_tool
touch "$PROJECT/._done-setup-prek"
run_driver setup || fail "cached setup failed"
run_driver setup || fail "repeated cached setup failed"
[[ ! -f "$CALLS" ]] || fail "cached setup invoked provisioning or hook installation"
printf 'PASS: cached setup skips all setup commands\n'

setup_case forced-setup
seed_installed_tool
touch "$PROJECT/._done-setup-prek"
run_driver setup force || fail "forced setup failed"
grep -Fxq 'tool upgrade prek' "$CALLS" ||
  fail "forced setup did not refresh tool provisioning"
grep -Fxq 'tool run prek install' "$CALLS" || fail "forced setup skipped hook installation"
printf 'PASS: forced setup refreshes provisioning despite the cached marker\n'

setup_case hook-failure
if FAIL_HOOK=1 run_driver setup; then fail "hook installation failure was ignored"; fi
[[ ! -f "$PROJECT/._done-setup-prek" ]] || fail "failed hook installation marked setup complete"
run_driver setup || fail "hook installation could not be retried"
[[ -f "$PROJECT/._done-setup-prek" ]] || fail "successful hook retry did not mark setup complete"
grep -Fxq 'tool upgrade prek' "$CALLS" || fail "hook retry did not use the installed tool"
printf 'PASS: hook failures leave setup uncached until a successful retry\n'

setup_case install-failure
if FAIL_INSTALL=1 run_driver setup; then fail "tool installation failure was ignored"; fi
[[ ! -f "$PROJECT/._done-setup-prek" ]] || fail "failed tool installation marked completion"
printf 'PASS: failed tool installation does not mark setup complete\n'

setup_case mirror-dispatch
run_driver mirror --fixture || fail "explicit mirror command failed"
grep -Fxq 'mirror --fixture' "$CALLS" || fail "mirror arguments were not forwarded"
printf 'PASS: explicit mirror dispatch forwards arguments from outside the repository\n'

setup_case prek-dispatch
run_driver prek check-yaml || fail "prek command failed"
grep -Fxq 'tool run prek run --all-files --hook-stage manual check-yaml' "$CALLS" ||
  fail "prek command or arguments were not forwarded"
if grep -q '^mirror ' "$CALLS"; then fail "prek dispatched to the mirror"; fi
printf 'PASS: prek dispatch forwards hook selection without running the mirror\n'

setup_case tests-dispatch
run_driver tests --fixture || fail "tests command failed"
grep -Fxq 'tests --fixture' "$CALLS" || fail "tests command or arguments were not forwarded"
if grep -q '^mirror ' "$CALLS"; then fail "tests dispatched to the mirror"; fi
printf 'PASS: tests dispatch preserves the test driver and arguments\n'

setup_case missing-command
exit_status=0
run_driver || exit_status=$?
[[ "$exit_status" == 2 ]] || fail "missing command did not return usage status"
grep -q '^Usage:' "$CASE/output.log" || fail "missing command did not print usage"
[[ ! -f "$CALLS" ]] || fail "missing command invoked tooling"
printf 'PASS: missing commands print usage without invoking tooling\n'

setup_case unknown-command
if run_driver unknown; then fail "unknown command was accepted"; fi
[[ ! -f "$CALLS" ]] || fail "unknown command invoked tooling"
printf 'PASS: unknown commands fail before installing tools or mirroring\n'
