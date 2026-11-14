#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly OUTPUT="$ROOT/docs"
readonly TEMPLATE_DIR="$ROOT/templates"
readonly LICENSE_DIR="$ROOT/LICENSES"
readonly CHECKSUMS="$ROOT/scripts/upstream-sha256sums.txt"
readonly LOCK_DIR="$ROOT/._mirror-lock"
readonly UPSTREAM_ORIGIN="https://tobiasjung.name"
readonly UPSTREAM_PAGE="$UPSTREAM_ORIGIN/profont/index.php"
readonly UPSTREAM_DIRECTORY="/profont"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

status() {
  printf '[mirror] %s\n' "$*"
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "neither shasum nor sha256sum is available"
  fi
}

for required in awk cp curl date dirname find grep mkdir mktemp mv rm rmdir sed sort tr wc; do
  command -v "$required" >/dev/null 2>&1 || fail "$required is required"
done

[[ -d "$TEMPLATE_DIR" ]] || fail "missing template directory: $TEMPLATE_DIR"
[[ -d "$LICENSE_DIR" ]] || fail "missing license directory: $LICENSE_DIR"
[[ "$ROOT" != "/" && "$OUTPUT" == "$ROOT/docs" ]] || fail "unsafe output directory"

STAGING="$(mktemp -d "$ROOT/.profont-mirror.XXXXXX")"
SOURCE_HTML="$STAGING/upstream.html"
MIRROR_ROOT="$STAGING/site"
CANDIDATES="$STAGING/candidates.tsv"
DISCOVERED="$STAGING/discovered.tsv"
CHECKSUMS_TMP="$STAGING/SHA256SUMS"
PUBLISH_STARTED=0
PUBLISH_COMPLETE=0
HAD_OUTPUT=0
HAD_CHECKSUMS=0
LOCK_HELD=0

cleanup() {
  local exit_status=$?
  local rollback_failed=0

  trap - EXIT
  if ((PUBLISH_STARTED && !PUBLISH_COMPLETE)); then
    status "Publication failed; restoring the previous site and checksum manifest." >&2 || true
    if [[ -e "$STAGING/previous-docs" || -L "$STAGING/previous-docs" ]]; then
      if ! rm -rf -- "$OUTPUT" || ! mv -- "$STAGING/previous-docs" "$OUTPUT"; then
        rollback_failed=1
      fi
    elif (( !HAD_OUTPUT )); then
      rm -rf -- "$OUTPUT" || rollback_failed=1
    fi

    if ((HAD_CHECKSUMS)); then
      mv -f -- "$STAGING/previous-checksums" "$CHECKSUMS" || rollback_failed=1
    else
      rm -f -- "$CHECKSUMS" || rollback_failed=1
    fi
  fi

  if ((rollback_failed)); then
    printf 'error: rollback incomplete; recovery files retained at %s; lock retained at %s\n' \
      "$STAGING" "$LOCK_DIR" >&2
    exit 1
  fi
  rm -rf -- "$STAGING"
  if ((LOCK_HELD)); then
    rmdir -- "$LOCK_DIR"
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

status "Acquiring exclusive mirror lock."
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another mirror run is active or a stale lock remains: $LOCK_DIR"
fi
LOCK_HELD=1

normalize_path() {
  local path="$1"
  local component
  local output=""

  while [[ -n "$path" ]]; do
    component="${path%%/*}"
    if [[ "$path" == */* ]]; then
      path="${path#*/}"
    else
      path=""
    fi
    case "$component" in
      ""|.)
        ;;
      ..)
        [[ -n "$output" ]] || fail "upstream reference escapes its root: $1"
        output="${output%/*}"
        ;;
      *)
        output+="/$component"
        ;;
    esac
  done

  printf '%s\n' "${output:-/}"
}

is_local_reference() {
  local reference="$1"

  case "$reference" in
    ""|\#*|data:*|javascript:*|mailto:*)
      return 1
      ;;
    "$UPSTREAM_ORIGIN"/*|http://tobiasjung.name/*|//tobiasjung.name/*)
      return 0
      ;;
    http://*|https://*|//*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

is_decorative_image() {
  local path="$1"
  local lowercase_path

  lowercase_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  case "$lowercase_path" in
    *.apng|*.avif|*.gif|*.ico|*.jpeg|*.jpg|*.png|*.svg|*.webp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_filename_extension() {
  local path="$1"
  local filename="${path##*/}"

  [[ "$filename" == *.* && "$filename" != .* ]]
}

file_parameter() {
  local query="$1"
  local parameter
  local -a parameters

  [[ -n "$query" ]] || return 1
  IFS='&' read -r -a parameters <<< "$query"
  for parameter in "${parameters[@]}"; do
    case "$parameter" in
      file=*)
        printf '%s\n' "${parameter#file=}"
        return 0
        ;;
    esac
  done
  return 1
}

asset_destination() {
  local path="$1"
  local filename="${path##*/}"
  local lowercase_filename

  lowercase_filename="$(printf '%s' "$filename" | tr '[:upper:]' '[:lower:]')"
  case "$lowercase_filename" in
    *.eot|*.otf|*.svg|*.ttf|*.woff|*.woff2)
      printf 'assets/fonts/%s\n' "$filename"
      ;;
    *.js)
      printf 'assets/js/%s\n' "$filename"
      ;;
    *)
      printf 'assets/%s\n' "$filename"
      ;;
  esac
}

is_safe_destination() {
  local destination="$1"
  local component
  local -a components

  [[ -n "$destination" && "$destination" != /* ]] || return 1
  IFS='/' read -r -a components <<< "$destination"
  for component in "${components[@]}"; do
    case "$component" in
      ""|.|..)
        return 1
        ;;
    esac
  done
}

record_reference() {
  local kind="$1"
  local reference="$2"
  local path_with_query
  local path
  local query=""
  local filename
  local destination
  local url

  reference="$(printf '%s' "$reference" | sed 's/&amp;/\&/g')"
  reference="${reference%%#*}"
  [[ -n "$reference" ]] || return 0
  is_local_reference "$reference" || return 0

  case "$reference" in
    "$UPSTREAM_ORIGIN"/*)
      path_with_query="${reference#"$UPSTREAM_ORIGIN"}"
      ;;
    http://tobiasjung.name/*)
      path_with_query="${reference#http://tobiasjung.name}"
      ;;
    //tobiasjung.name/*)
      path_with_query="${reference#//tobiasjung.name}"
      ;;
    /*)
      path_with_query="$reference"
      ;;
    *)
      path_with_query="$UPSTREAM_DIRECTORY/$reference"
      ;;
  esac

  if [[ "$path_with_query" == *\?* ]]; then
    path="${path_with_query%%\?*}"
    query="${path_with_query#*\?}"
  else
    path="$path_with_query"
  fi
  path="$(normalize_path "$path")"

  case "$path" in
    /downloadfile.php)
      filename="$(file_parameter "$query" || true)"
      [[ -n "$filename" ]] || return 0
      destination="downloads/${filename##*/}"
      ;;
    *)
      if [[ "$kind" == "href" ]]; then
        case "$path" in
          *.htm|*.html|*.php)
            return 0
            ;;
        esac
        has_filename_extension "$path" || return 0
      elif [[ "$kind" == "src" ]] && is_decorative_image "$path"; then
        return 0
      fi
      destination="$(asset_destination "$path")"
      ;;
  esac

  is_safe_destination "$destination" ||
    fail "unsafe destination from upstream reference: $destination"
  [[ ! -e "$TEMPLATE_DIR/$destination" && ! -L "$TEMPLATE_DIR/$destination" ]] ||
    fail "upstream asset conflicts with a maintained template: $destination"

  url="$UPSTREAM_ORIGIN$path"
  [[ -n "$query" ]] && url+="?$query"
  printf '%s\t%s\n' "$url" "$destination" >> "$CANDIDATES"
}

collect_references() {
  local kind
  local match
  local reference

  : > "$CANDIDATES"

  awk '
    BEGIN { RS = "<"; single_quote = sprintf("%c", 39) }
    /^[[:alpha:]][[:alnum:]:-]*[[:space:]>\/]/ {
      tag = $0
      sub(/^[^[:space:]>]+/, "", tag)
      while (length(tag)) {
        sub(/^[[:space:]]+/, "", tag)
        if (tag ~ /^[>\/]/) break
        if (!match(tag, /^[^[:space:]=\/>]+/)) break
        name = tolower(substr(tag, 1, RLENGTH))
        tag = substr(tag, RLENGTH + 1)
        sub(/^[[:space:]]+/, "", tag)
        if (substr(tag, 1, 1) != "=") continue
        tag = substr(tag, 2)
        sub(/^[[:space:]]+/, "", tag)
        quote = substr(tag, 1, 1)
        if (quote == "\"" || quote == single_quote) {
          tag = substr(tag, 2)
          end = index(tag, quote)
          if (!end) break
          value = substr(tag, 1, end - 1)
          tag = substr(tag, end + 1)
        } else {
          if (!match(tag, /^[^[:space:]>]+/)) break
          value = substr(tag, 1, RLENGTH)
          tag = substr(tag, RLENGTH + 1)
        }
        if (name == "href" || name == "src") {
          gsub(/[[:space:]]/, " ", value)
          print name "\t" value
        }
      }
    }
  ' "$SOURCE_HTML" > "$STAGING/attributes.tsv"

  while IFS=$'\t' read -r kind reference; do
    record_reference "$kind" "$reference"
  done < "$STAGING/attributes.tsv"

  while IFS= read -r match; do
    reference="${match#url(}"
    reference="${reference%)}"
    reference="$(printf '%s' "$reference" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$reference" in
      \"*\")
        reference="${reference#\"}"
        reference="${reference%\"}"
        ;;
      \'*\')
        reference="${reference#\'}"
        reference="${reference%\'}"
        ;;
    esac
    record_reference "css" "$reference"
  done < <(tr '\n' ' ' < "$SOURCE_HTML" | grep -Eo 'url\([^)]*\)' || true)
}

download() {
  local url="$1"
  local destination="$2"
  local output="$MIRROR_ROOT/$destination"

  mkdir -p "$(dirname "$output")"
  curl --fail --silent --show-error --location --retry 2 --output "$output" "$url"
  [[ -s "$output" ]] || fail "downloaded an empty file: $url"
}

write_checksum_file() {
  local output="$1"
  local mirrored_at="$2"
  local asset_count="$3"
  local file
  local digest

  {
    printf '# Mirrored at: %s\n' "$mirrored_at"
    printf '# Source: %s\n' "$UPSTREAM_PAGE"
    printf '# Files: %s\n' "$asset_count"
    while IFS= read -r file; do
      if ! digest="$(sha256 "$file")"; then
        fail "could not calculate SHA-256 for ${file#"$MIRROR_ROOT/"}"
      fi
      [[ ${#digest} == 64 && "$digest" != *[!0-9a-fA-F]* ]] ||
        fail "invalid SHA-256 for ${file#"$MIRROR_ROOT/"}"
      printf '%s  %s\n' "$digest" "${file#"$MIRROR_ROOT/"}"
    done < <(find "$MIRROR_ROOT" -type f -print | LC_ALL=C sort)
  } > "$output"
}

write_mirror_metadata() {
  local mirrored_at="$1"
  local asset_count="$2"

  mkdir -p "$MIRROR_ROOT/_data"
  {
    printf 'mirrored_at: "%s"\n' "$mirrored_at"
    printf 'source_url: "%s"\n' "$UPSTREAM_PAGE"
    printf 'asset_count: %s\n' "$asset_count"
  } > "$MIRROR_ROOT/_data/mirror.yml"
}

validate_page_links() {
  local page
  local target

  for page in "$MIRROR_ROOT"/*.md; do
    [[ -f "$page" ]] || continue
    while IFS= read -r target; do
      target="${target#\]\(}"
      target="${target%%#*}"
      [[ -f "$MIRROR_ROOT/$target" ]] ||
        fail "missing mirrored target in ${page##*/}: $target"
    done < <(grep -Eo '\]\((assets|downloads)/[^)]*' "$page" || true)
  done
}

publish() {
  if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    HAD_OUTPUT=1
  fi
  if [[ -e "$CHECKSUMS" ]]; then
    cp -p "$CHECKSUMS" "$STAGING/previous-checksums"
    HAD_CHECKSUMS=1
  fi

  PUBLISH_STARTED=1
  if ((HAD_OUTPUT)); then
    mv -- "$OUTPUT" "$STAGING/previous-docs"
  fi
  mv -- "$MIRROR_ROOT" "$OUTPUT"
  mv -f -- "$CHECKSUMS_TMP" "$CHECKSUMS"
  PUBLISH_COMPLETE=1
}

mkdir -p "$MIRROR_ROOT"
status "Fetching upstream page."
curl --fail --silent --show-error --location --retry 2 --output "$SOURCE_HTML" "$UPSTREAM_PAGE"

status "Discovering non-image assets."
collect_references
LC_ALL=C sort -u "$CANDIDATES" > "$DISCOVERED"
[[ -s "$DISCOVERED" ]] || fail "no upstream assets were discovered"

if ! awk -F '\t' '
  {
    if ($2 in urls && urls[$2] != $1) {
      print "conflicting upstream URLs for " $2
      exit 1
    }
    urls[$2] = $1
  }
' "$DISCOVERED"; then
  fail "multiple upstream URLs map to the same destination"
fi

asset_count="$(wc -l < "$DISCOVERED" | tr -d '[:space:]')"
status "Discovered $asset_count assets."

current_asset=0
while IFS=$'\t' read -r url destination; do
  current_asset=$((current_asset + 1))
  status "Downloading $current_asset/$asset_count: $destination"
  download "$url" "$destination"
done < "$DISCOVERED"

mirrored_count="$(find "$MIRROR_ROOT" -type f | wc -l | tr -d '[:space:]')"
[[ "$mirrored_count" == "$asset_count" ]] ||
  fail "download count mismatch: expected $asset_count, received $mirrored_count"

MIRRORED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
status "Writing timestamped SHA-256 manifests."
write_checksum_file "$CHECKSUMS_TMP" "$MIRRORED_AT" "$asset_count"
cp "$CHECKSUMS_TMP" "$MIRROR_ROOT/SHA256SUMS"
write_mirror_metadata "$MIRRORED_AT" "$asset_count"

status "Assembling and validating GitHub Pages files."
mkdir -p "$MIRROR_ROOT/assets"
cp -R "$LICENSE_DIR" "$MIRROR_ROOT/"
cp -R "$TEMPLATE_DIR/assets/." "$MIRROR_ROOT/assets/"
cp -R "$TEMPLATE_DIR/_layouts" "$MIRROR_ROOT/"
cp "$TEMPLATE_DIR/_config.yml" "$MIRROR_ROOT/_config.yml"
cp "$TEMPLATE_DIR/index.md" "$MIRROR_ROOT/index.md"
cp "$TEMPLATE_DIR/attribution.md" "$MIRROR_ROOT/attribution.md"
validate_page_links

status "Publishing the site and checksum manifest."
publish

status "Complete: $OUTPUT contains $asset_count assets mirrored at $MIRRORED_AT."
