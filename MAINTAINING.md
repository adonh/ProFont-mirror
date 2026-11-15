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
In the repository's **Settings > Pages**, set **Source** to **GitHub Actions**.
The [publishing workflow](.github/workflows/pages.yml) builds `docs/` with Jekyll
and deploys it when site changes are pushed to `main`.
It can also be run manually from the Actions tab.
If the default branch changes, update the workflow's `push.branches` filter.

## Automatic refreshes

The [refresh workflow](.github/workflows/mirror.yml) checks upstream every Monday
at 06:23 UTC and can also be started from **Actions > Refresh ProFont mirror > Run workflow**.
Run it on the default branch.
It invokes the mirror script directly, without installing local development hooks,
verifies the checksums, and commits changed files in `docs/`
and `scripts/upstream-sha256sums.txt` as `github-actions[bot]`.

Timestamp-only updates are not committed.
The published mirror time therefore describes the last committed snapshot,
not the last scheduled check.
After every successful check, the refresh workflow calls the publishing workflow explicitly:
commits made with the built-in `GITHUB_TOKEN` do not trigger ordinary push workflows.
Publishing uses a fresh checkout of the committed snapshot, even when upstream is unchanged,
so a failed deployment can recover on the next weekly run without a new commit.

No extra token secret is required.
Repository rules must allow the workflow to push directly to the default branch.
Pushes are never forced.
A failed run stops without workflow retries or back-off;
the next weekly run tries again, or you can start a manual run sooner.
GitHub may delay scheduled runs and disables schedules in public repositories
after 60 days without repository activity; re-enable the workflow in Actions if needed.

## License files

The repository-authored MIT license is stored in [`LICENSES/Mirror-MIT.txt`](LICENSES/Mirror-MIT.txt).
Keep the root [`LICENSE`](LICENSE) identical for GitHub's license detection.
The mirror copies `LICENSES/` into `docs/LICENSES/` during rebuilds.

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
