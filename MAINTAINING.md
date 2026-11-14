# Maintaining the ProFont mirror

This guide is for maintainers, contributors, and anyone reproducing or refreshing the mirror.
For downloads and licensing information, see the [README](README.md).

## Prerequisites

Use Bash 3.2 or newer on macOS or Linux; on Windows, use WSL.
You need Git, curl, [`uv`](https://docs.astral.sh/uv/), and standard Unix command-line tools.
SHA-256 hashing requires either `shasum` or `sha256sum`.
Run the commands below from the repository root.

## Rebuild the mirror

```bash
./run mirror
```

The [Bash script](scripts/mirror.bash)
discovers same-origin download and asset references at runtime,
skips decorative embedded images,
reports progress,
updates the SHA-256 manifests,
and regenerates `docs/`.
Newly discovered upstream files are mirrored automatically.
Review generated changes before committing or publishing them.

## Runner setup

The runner performs setup before running `mirror`, `prek`, or `tests`.
Uncached setup installs prek through uv if no `prek` executable is found on `PATH`,
or upgrades prek if one is found.
It installs a Git hook if none exists,
force-replaces an existing hook containing the literal text ` pre-commit `,
and leaves other existing hooks untouched.

The `._done-setup-prek` marker caches successful setup,
so later runs skip both installation/upgrades and hook checks.
Use `./run setup` to perform setup when the marker is absent,
or `./run setup force` to repeat the entire setup despite the marker.

## Source files and GitHub Pages

The text pages are maintained as Markdown templates
and rendered by GitHub Pages' Jekyll build.
Edit pages, layouts, configuration, and styles in [`templates/`](templates/),
not their generated copies in [`docs/`](docs/).
Rebuild after changing templates.

The site's directory links open the downloads folder on GitHub.
If the repository or branch changes, update `downloads_directory_url`
in `templates/_config.yml` and the directory link in `README.md`.

`docs/` is the publish directory.
For branch-based GitHub Pages publishing, open the repository's **Settings > Pages**,
choose **Deploy from a branch**, and select the branch containing the generated site
with the **/docs** folder.

## Timestamps and integrity

Each mirror run writes the UTC mirror time to [`docs/_data/mirror.yml`](docs/_data/mirror.yml),
which GitHub Pages displays in the site footer,
and to both checksum manifests:
[`scripts/upstream-sha256sums.txt`](scripts/upstream-sha256sums.txt) and
[`docs/SHA256SUMS`](docs/SHA256SUMS).

Formatting hooks exclude generated `docs/` files so downloaded bytes remain unchanged.
A read-only checksum hook verifies them against both manifests.
Git newline conversion is disabled for mirrored assets and downloads.

## Checks and tests

Run the configured manual checks and isolated regression tests with:

```bash
./run prek
./run tests
```

The tests themselves are offline,
but uncached runner setup may need network access to install or upgrade prek.

## Publication and recovery

The complete site is assembled and checked before publication.
Failed downloads, hashing, template copies, or unresolved mirrored links leave
the previous site and manifest intact;
publication failures trigger rollback.
Upstream assets that would overwrite maintained templates are rejected.

An exclusive lock prevents overlapping mirror runs, including during rollback.
If rollback is incomplete, the script retains recovery files and the lock
and reports their paths.
If a process is killed without cleanup, remove `._mirror-lock` only after
confirming that no mirror is still running and any retained recovery files have been handled.
