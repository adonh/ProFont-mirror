#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/profont-mirror-test.XXXXXX")"
REAL_CP="$(command -v cp)"
REAL_MV="$(command -v mv)"
REAL_HASH="$(command -v shasum || command -v sha256sum)"
MOCK_BIN="$TEST_ROOT/bin"

trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/curl" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --retry) shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *[[:space:]]*|*\"*|*\'*)
    printf 'invalid fixture URL: %s\n' "$url" >&2
    exit 3
    ;;
esac
printf '%s\n' "$url" >> "$REQUESTS"
if [[ "$url" == "https://tobiasjung.name/profont/index.php" ]]; then
  "$REAL_CP" "$HTML_FIXTURE" "$output"
else
  printf 'fixture asset: %s\n' "$url" > "$output"
fi
BASH

cat > "$MOCK_BIN/cp" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAIL_COPY:-0}" == 1 && "${1:-}" == */templates/index.md ]]; then
  printf 'injected template copy failure\n' >&2
  exit 7
fi
exec "$REAL_CP" "$@"
BASH

cat > "$MOCK_BIN/mv" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source=""
destination=""
for argument in "$@"; do
  source="$destination"
  destination="$argument"
done
if [[ "${PAUSE_PUBLICATION:-0}" == 1 && "$source" == */docs &&
      "$destination" == */previous-docs ]]; then
  "$REAL_MV" "$@"
  touch "$PAUSE_READY"
  while [[ ! -f "$PAUSE_RELEASE" ]]; do sleep 0.05; done
  exit 0
fi
if [[ "${PAUSE_ROLLBACK:-0}" == 1 && "$source" == */previous-docs ]]; then
  touch "$PAUSE_READY"
  while [[ ! -f "$PAUSE_RELEASE" ]]; do sleep 0.05; done
fi
if [[ "${FAIL_PUBLISH:-0}" == 1 && "$source" == */SHA256SUMS &&
      "$destination" == */scripts/upstream-sha256sums.txt ]]; then
  printf 'injected manifest publication failure\n' >&2
  exit 7
fi
exec "$REAL_MV" "$@"
BASH

cat > "$MOCK_BIN/shasum" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
case "${HASH_MODE:-ok}" in
  failure) exit 7 ;;
  malformed) printf 'not-a-digest\n'; exit 0 ;;
esac
if [[ "$REAL_HASH" == */shasum ]]; then
  exec "$REAL_HASH" -a 256 "${@: -1}"
else
  exec "$REAL_HASH" "${@: -1}"
fi
BASH

chmod +x "$MOCK_BIN/curl" "$MOCK_BIN/cp" "$MOCK_BIN/mv" "$MOCK_BIN/shasum"
ln -s shasum "$MOCK_BIN/sha256sum"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -f "$CASE/output.log" ]]; then
    cat "$CASE/output.log" >&2
  fi
  exit 1
}

setup_case() {
  CASE="$TEST_ROOT/$1"
  PROJECT="$CASE/repository with spaces"
  HTML_FIXTURE="$CASE/upstream.html"
  REQUESTS="$CASE/requests"
  mkdir -p "$PROJECT/scripts" "$PROJECT/templates/assets" \
    "$PROJECT/templates/_layouts" "$PROJECT/LICENSES" "$PROJECT/docs"
  "$REAL_CP" "$ROOT/scripts/mirror.bash" "$PROJECT/scripts/"
  "$REAL_CP" "$ROOT/scripts/check-mirror.bash" "$PROJECT/scripts/"
  printf '[Sample](downloads/sample.zip)\n' > "$PROJECT/templates/index.md"
  printf 'Attribution\n' > "$PROJECT/templates/attribution.md"
  printf 'maintained styles\n' > "$PROJECT/templates/assets/styles.css"
  printf '{{ content }}\n' > "$PROJECT/templates/_layouts/default.html"
  printf 'title: Fixture\n' > "$PROJECT/templates/_config.yml"
  printf 'fixture license\n' > "$PROJECT/LICENSES/LICENSE"
  printf 'previous site\n' > "$PROJECT/docs/previous.txt"
  printf 'previous manifest\n' > "$PROJECT/scripts/upstream-sha256sums.txt"
  "$REAL_CP" -R "$PROJECT/docs" "$CASE/previous-docs"
  "$REAL_CP" "$PROJECT/scripts/upstream-sha256sums.txt" "$CASE/previous-checksums"
  printf '<a href="/downloadfile.php?file=sample.zip">Download</a>\n' > "$HTML_FIXTURE"
}

run_mirror() {
  env PATH="$MOCK_BIN:$PATH" REAL_CP="$REAL_CP" REAL_MV="$REAL_MV" \
    REAL_HASH="$REAL_HASH" PROJECT="$PROJECT" HTML_FIXTURE="$HTML_FIXTURE" \
    REQUESTS="$REQUESTS" "$@" "$BASH" "$PROJECT/scripts/mirror.bash" > "${MIRROR_LOG:-$CASE/output.log}" 2>&1
}

assert_preserved() {
  diff -r "$CASE/previous-docs" "$PROJECT/docs" || fail "previous site changed"
  cmp -s "$CASE/previous-checksums" "$PROJECT/scripts/upstream-sha256sums.txt" ||
    fail "previous manifest changed"
}

expect_failure() {
  local message="$1"
  shift
  if run_mirror "$@"; then
    fail "mirror unexpectedly succeeded"
  fi
  grep -Fq "$message" "$CASE/output.log" || fail "missing error: $message"
  assert_preserved
}

setup_case attributes
cat > "$HTML_FIXTURE" <<'HTML'
<a href="/">Home</a>
<a href="/profont/./../">Parent</a>
<a href="/downloadfile.php">No file parameter</a>
<a HREF = '/downloadfile.php?file=sample.zip'>Download</a>
<a
  href
  =
  "/downloadfile.php?file=new.zip&amp;version=2"
>New download</a>
<a href=/downloadfile.php?file=unquoted.zip>Unquoted download</a>
<script SRC = "//tobiasjung.name/js/app.js"></script>
<script src = '//cdn.example.org/widget.js'></script>
<img src = 'decorative.png'>
<style>
@font-face {
  src: url('fixture.woff'), url( "double.woff" ), url( 'single.woff' ), url( bare.woff ), url(
    "multiline.woff"
  );
}
</style>
HTML
run_mirror || fail "valid attribute syntax or root links failed"
for path in downloads/sample.zip downloads/new.zip downloads/unquoted.zip \
  assets/js/app.js assets/fonts/fixture.woff assets/fonts/double.woff \
  assets/fonts/single.woff assets/fonts/bare.woff assets/fonts/multiline.woff; do
  [[ -f "$PROJECT/docs/$path" ]] || fail "missing discovered asset: $path"
done
if grep -Eq 'cdn\.example\.org|decorative\.png' "$REQUESTS"; then
  fail "external script or decorative image was requested"
fi
cmp -s "$PROJECT/docs/SHA256SUMS" "$PROJECT/scripts/upstream-sha256sums.txt" ||
  fail "published manifests differ"
while read -r expected path; do
  [[ "$expected" != "#" ]] || continue
  if [[ "$REAL_HASH" == */shasum ]]; then
    actual="$("$REAL_HASH" -a 256 "$PROJECT/docs/$path")"
  else
    actual="$("$REAL_HASH" "$PROJECT/docs/$path")"
  fi
  [[ "${actual%% *}" == "$expected" ]] || fail "published checksum mismatch: $path"
done < "$PROJECT/docs/SHA256SUMS"
timestamp="$(sed -n 's/^# Mirrored at: //p' "$PROJECT/docs/SHA256SUMS")"
grep -Fq "mirrored_at: \"$timestamp\"" "$PROJECT/docs/_data/mirror.yml" ||
  fail "metadata timestamp differs from manifest"
printf 'PASS: HTML attributes, root links, same-origin filtering, checksums, timestamps\n'

"$BASH" "$PROJECT/scripts/check-mirror.bash" > "$CASE/check-output.log" 2>&1 ||
  fail "read-only verification rejected a valid mirror"
printf 'changed bytes\n' >> "$PROJECT/docs/downloads/sample.zip"
cp "$PROJECT/docs/downloads/sample.zip" "$CASE/changed-asset"
if "$BASH" "$PROJECT/scripts/check-mirror.bash" > "$CASE/check-output.log" 2>&1; then
  fail "read-only verification accepted a changed asset"
fi
cmp -s "$CASE/changed-asset" "$PROJECT/docs/downloads/sample.zip" ||
  fail "verification modified the mirrored asset"
printf '# Changed manifest\n' >> "$PROJECT/scripts/upstream-sha256sums.txt"
if "$BASH" "$PROJECT/scripts/check-mirror.bash" > "$CASE/check-output.log" 2>&1; then
  fail "read-only verification accepted inconsistent manifests"
fi
grep -Fq 'manifests differ' "$CASE/check-output.log" || fail "manifest mismatch was not reported"
printf 'PASS: read-only verification detects changed assets and inconsistent manifests\n'

setup_case missing-link
printf '<script src="../js/app.js"></script>\n' > "$HTML_FIXTURE"
expect_failure "missing mirrored target"
printf 'PASS: incomplete inventories preserve the previous site and manifest\n'

setup_case hash-failure
expect_failure "could not calculate SHA-256" HASH_MODE=failure
printf 'PASS: hash command failures prevent publication\n'

setup_case malformed-hash
expect_failure "invalid SHA-256" HASH_MODE=malformed
printf 'PASS: malformed digests prevent publication\n'

setup_case missing-template
rm "$PROJECT/templates/index.md"
expect_failure "index.md"
printf 'PASS: missing templates preserve the previous site and manifest\n'

setup_case copy-failure
expect_failure "injected template copy failure" FAIL_COPY=1
printf 'PASS: template copy failures preserve the previous site and manifest\n'

setup_case publication-failure
expect_failure "injected manifest publication failure" FAIL_PUBLISH=1
printf 'PASS: publication failure rolls back the site and manifest together\n'

setup_case first-publication-failure
rm -rf -- "$PROJECT/docs"
rm "$PROJECT/scripts/upstream-sha256sums.txt"
if run_mirror FAIL_PUBLISH=1; then
  fail "first publication unexpectedly succeeded"
fi
[[ ! -e "$PROJECT/docs" && ! -e "$PROJECT/scripts/upstream-sha256sums.txt" ]] ||
  fail "failed first publication left partial output"
printf 'PASS: failed first publication leaves no partial output\n'

setup_case asset-collision
printf '<link href="styles.css" rel="stylesheet">\n' >> "$HTML_FIXTURE"
expect_failure "upstream asset conflicts with a maintained template"
printf 'PASS: upstream/template destination collisions prevent publication\n'

check_concurrent_run() {
  local first_pid
  local first_failed=0
  local second_succeeded=0
  local lock_held=0
  local attempt
  local ready="$CASE/paused"
  local release="$CASE/release"

  MIRROR_LOG="$CASE/first.log" run_mirror PAUSE_READY="$ready" PAUSE_RELEASE="$release" "$@" &
  first_pid=$!
  for ((attempt = 0; attempt < 400; attempt++)); do
    [[ ! -f "$ready" ]] || break
    sleep 0.05
  done
  if [[ ! -f "$ready" ]]; then
    touch "$release"
    wait "$first_pid" || true
    fail "first mirror did not reach the publication gate"
  fi

  if MIRROR_LOG="$CASE/second.log" run_mirror; then
    second_succeeded=1
  fi
  if [[ -d "$PROJECT/._mirror-lock" ]]; then
    lock_held=1
  fi
  touch "$release"
  wait "$first_pid" || first_failed=1

  (( !second_succeeded && lock_held )) || fail "overlapping mirror was not excluded"
  grep -Fq "another mirror run is active" "$CASE/second.log" ||
    fail "overlapping mirror did not report its lock"
  [[ ! -d "$PROJECT/._mirror-lock" ]] || fail "finished mirror left its lock behind"
  [[ ! -e "$PROJECT/docs/site" ]] || fail "publication nested the generated site"

  if [[ "${1:-}" == "PAUSE_ROLLBACK=1" ]]; then
    ((first_failed)) || fail "injected publication failure was ignored"
    assert_preserved
  else
    (( !first_failed )) || fail "first mirror failed"
    cmp -s "$PROJECT/docs/SHA256SUMS" "$PROJECT/scripts/upstream-sha256sums.txt" ||
      fail "concurrent publication split the manifests"
  fi
}

setup_case concurrent-publication
check_concurrent_run PAUSE_PUBLICATION=1
printf 'PASS: exclusive locking prevents overlapping publication\n'

setup_case concurrent-rollback
check_concurrent_run PAUSE_ROLLBACK=1 FAIL_PUBLISH=1
printf 'PASS: exclusive locking remains held throughout rollback\n'
