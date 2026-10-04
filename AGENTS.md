# Cellar contributor and agent guidance

## Repository and scope

This repository is the source of truth for product code, tests, public documentation, and releases. The public upstream is `https://github.com/CAfeng11/Cellar.git`; the default branch is `main`.

Before editing, inspect the working directory, repository root, branch, remotes, HEAD, staged changes, and unstaged changes. A parent directory or another checkout may have unrelated history. Do not merge histories, copy an entire old checkout, or assume that matching branch names imply matching commits.

Preserve other contributors' changes. Stage explicit task files; do not use blanket staging, hard resets, or destructive cleanup. Do not publish private planning documents, local configuration, logs, credentials, or app backups. Follow CONTRIBUTING.md and docs/RELEASING.md for the applicable workflow; user instructions take precedence.

## Verification

Run `./script/test.sh` for code behavior changes and the relevant build. Documentation-only edits need content, links, and diff checks rather than a new app build. Use existing build and packaging scripts.

Keep simulated UI evidence distinct from real execution. A failed or cancelled check is not a healthy environment or an empty successful update result. Old snapshots must be identified as stale. Copying a repair command does not mean it ran. Do not accept licenses or execute administrator repairs as part of read-only diagnosis.

## Releases and installation

Before choosing a version, inspect existing remote tags and releases. Normally create a new version; replacing an existing tag or release requires explicit user authorization for that replacement. The 2.2.3 build 2 overwrite was a one-time authorized revision, not standing permission.

Build artifacts from identifiable committed source. Verify marketing version, build number, supported architectures, signing/notarization status, and archive checksum. Keep English and Chinese README, CHANGELOG, and release notes aligned. If an existing download was replaced, clearly tell users to download again. Do not label an unsigned preview as signed or notarized.

Keep source commit/push, remote CI, release publication, local installation, and live acceptance as separate facts. Documentation-only commits after a release do not require moving its tag or rebuilding its binary.

Before replacing or quitting an installed app, inspect its activity. Do not interrupt an active Homebrew task unless the user explicitly authorizes that interruption. Preserve a rollback copy, verify the installed version and executable path, and run fresh update, library, and runtime checks. Do not upgrade unrelated software during validation.

## Handoff

Report the repository used, commit and push status, tests and their limits, release/tag and artifact identity when applicable, and installation/verification status separately. Explicitly mention any untouched legacy checkout or uncommitted changes relevant to the next task. Do not claim another checkout was synchronized unless verified.

No parallel agent or separate-thread workflow is required by this file.
