# claude-box

A rootless-[Podman](https://podman.io/) sandbox for running Claude Code
unattended (permission prompts bypassed) without giving it access to your
credentials or host root.

## What it isolates

| Concern | How it's handled |
| --- | --- |
| Home-dir secrets (`~/.ssh`, `~/.aws`, `~/.config/gh`, browser data, …) | Not mounted into the container, so they don't exist inside it. Only `~/git` plus Claude's own config (`~/.claude`, `~/.claude.json`, `~/.gitconfig`) are mounted. |
| Passwordless `sudo` / host root | Rootless Podman + a non-root container user (`ubuntu`, UID 1000). There is no `sudo` binary in the image, and even container-root maps to your unprivileged user on the host. |
| File ownership | `--userns=keep-id` maps your host UID 1000 onto the container's UID 1000, so files Claude writes under `~/git` are owned by **you** on the host. Your IDE sees live diffs and edits them with no friction. |
| Network | Unrestricted (exfiltration isn't a concern for these mostly-public repos). |

## Usage

```sh
cd ~/git/<project>
claude-box                 # launch Claude with --dangerously-skip-permissions
claude-box "fix the bug"   # ... with an initial prompt
claude-box bash            # shell inside the sandbox (poke around / debug)
claude-box --rebuild       # rebuild the image after editing the Containerfile
```

`claude-box` refuses to run outside `~/git` so nothing else is ever exposed.

## Python / venvs

The image is **Ubuntu 24.04** specifically so `python3.12` lives at
`/usr/bin/python3.12` — the same path your host used to create its venvs.
That means `source venv/bin/activate` works unchanged inside the box for the
Flask projects. `python3.12-venv` and `pip` are installed so new venvs can be
created in-container too.

`uv` (pinned to the host's 0.7.19) and `uvx` are also installed. uv's managed
Pythons (`~/.local/share/uv`) are shared into the box, and uv's package cache
is relocated to `~/git/.cache/uv` (set via `UV_CACHE_DIR` in the image and
`~/.config/uv/uv.toml` on the host). Because that puts the cache on the same
`~/git` bind-mount as project `.venv`s, uv can **hardlink** wheels into venvs
(fast) both inside and outside the box, instead of falling back to copying.
Venvs on the system
`/usr/bin/python3.12` are fully portable between host and box; a venv pinned to
a **uv-managed** interpreter hardcodes a home-relative path, so since the
container's home differs (`/home/ubuntu`) it may need a `uv sync` to repair
inside the box. Normal `uv run` / `uv sync` / `uv add` handle this automatically.

## PHP

**PHP 8.3** (`cli` + `fpm`) is installed via Ubuntu 24.04's own repos, landing
at `/usr/bin/php` — the same path as the host's `php` (8.3.x) — so php scripts
run unchanged inside the box, the same logic as `python3.12`. The bundled
extensions mirror what the host projects use (`pgsql`, `sqlite3`, `gd`, `zip`)
along with `composer` for dependency management. If a project needs an extension
that isn't bundled, add the matching `php8.3-*` package to the `Containerfile`
and `claude-box --rebuild`.

## Browser tests (Chrome)

Google Chrome (matching the host version) is installed for browser-based tests
such as nmrhub's Angular/Karma unit tests. `CHROME_BIN` points at a shim
(`chrome-headless`) that adds the flags a containerized Chrome needs
(`--no-sandbox --headless=new --disable-gpu --disable-dev-shm-usage`), so a
`karma.conf.js` that says `browsers: ['Chrome']` runs unchanged. For a one-shot
run use Angular's non-watch flag, e.g. from `frontend/`:

```sh
npm test -- --watch=false      # or: ng test --watch=false
```

## Files

- `Containerfile` — image definition (Ubuntu 24.04 + Python 3.12 + Node 22 + PHP 8.3 + Claude Code).
- `box-entry` — container entrypoint (runs `claude` by default; `bash`/`shell` for a shell).
- `claude-box` — host launcher (symlinked into `~/.local/bin`).

## Notes

- **No `git push`**: SSH keys/tokens are intentionally not mounted, so Claude
  can commit but can't push. To allow pushing, mount a narrowly-scoped token
  rather than your SSH key.
- Your Claude login persists across runs because `~/.claude.json` is mounted
  read-write.
- The host `docker` group (daemon-based, root-equivalent) is unrelated to this
  setup and unused; everything here goes through rootless Podman.
