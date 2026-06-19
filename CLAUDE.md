# claude-box

This directory defines `claude-box`: a rootless-Podman sandbox for running
Claude Code unattended. Before editing anything here, **read `README.md`** — it
explains the isolation model and the rationale behind each piece of the image
(why Ubuntu 24.04, the Python/venv path matching, uv cache layout, Chrome
shim, PHP, etc.). That saves you from scanning every file to rebuild context.

## Files

- `Containerfile` — image definition. Mirror host tools at their host paths
  (e.g. `python3.12` at `/usr/bin/python3.12`, `php` at `/usr/bin/php`) rather
  than bind-mounting host binaries, which would break isolation.
- `box-entry` — container entrypoint.
- `claude-box` — host launcher (symlinked into `~/.local/bin`).

After changing the `Containerfile`, rebuild with `claude-box --rebuild` and keep
`README.md` in sync with the change.
