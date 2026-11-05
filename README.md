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
claude-box --rebuild       # rebuild the image (and upgrade Claude Code)
```

`claude-box` refuses to run outside `~/git` so nothing else is ever exposed.

## Hosts / architecture

Built and used on a **Linux/amd64** host; it also builds and runs on **macOS /
Apple Silicon (arm64)** via `podman machine`, with two differences the
`Containerfile` handles by checking `dpkg --print-architecture`:

| | Linux amd64 | macOS arm64 |
| --- | --- | --- |
| Google Chrome | installed | **skipped** — Google publishes no Linux arm64 build, and noble's `chromium-browser` is only a snap stub. `chrome-headless` exits 127 with an explanation. |
| Python 2.7 jammy `.deb`s | `archive`/`security.ubuntu.com` | `ports.ubuntu.com/ubuntu-ports` (arm64 and the other ports live there, not on `archive`) |

Everything else — python3.12, node, PHP, PostgreSQL, the build toolchain, uv —
is arch-independent and behaves the same. File ownership works on macOS too:
podman machine maps container UID 1000 back to your macOS UID, so files Claude
writes under `~/git` still show up owned by you.

One macOS-only wrinkle worth knowing about, since the fix looks like a
pointless detour otherwise: the launcher does **not** use `podman run -w "$PWD"`.
On macOS podman pre-creates the workdir as root inside the container's mount
namespace, so that single directory stats as `uid 0` while everything around it
is `uid 1000` — and git then refuses the very repo you're standing in with
`detected dubious ownership`. Instead the launcher passes `CLAUDE_BOX_CWD` and
`box-entry` cds into it, which avoids the anomaly and is a no-op difference on
Linux.

## Python / venvs

The image is **Ubuntu 24.04** specifically so `python3.12` lives at
`/usr/bin/python3.12` — the same path the **Linux** host used to create its
venvs. That means `source venv/bin/activate` works unchanged inside the box for
the Flask projects. `python3.12-venv` and `pip` are installed so new venvs can
be created in-container too.

That venv-sharing trick is Linux-only. Each machine has its own `~/git`
checkouts (nothing is shared between them), and on a Mac those working copies
hold **mac-native** venvs: the interpreter is at
`/Library/Frameworks/Python.framework/...` and the wheels are Mach-O
(`macosx-*-universal2`), so the Linux box can't use them — and a venv built
inside the box is equally useless to the macOS host. This is a host-vs-box split
on the same machine, not a cross-machine one. Give the box its own venv under a
different name (e.g. `.venv-box`, gitignored) rather than letting the two fight
over one `.venv`; `uv` handles it cleanly, since `uv run`/`uv sync` rebuild the
environment from `uv.lock` on demand.

### Python 2

Ubuntu 24.04 removed Python 2 from its own repos, so `python2.7` (plus `python2`
and `pip2`) is pulled from **jammy** (22.04)'s `.deb`s (from `archive.ubuntu.com`
on amd64, `ports.ubuntu.com` on arm64 — see above) — version
`2.7.18-13ubuntu1.5` — which is patched for OpenSSL 3.0. Both jammy and noble
ship `libssl3`, so `ssl`/`hashlib` work (a from-source 2.7.18 build would not,
as upstream 2.7 predates OpenSSL 3.0). The only friction is noble's `time_t64`
transition, which renamed `libdb5.3` → `libdb5.3t64`; it still provides
`libdb-5.3.so`, so the build installs that lib and `--force-depends` past the
one stale jammy dependency name. `apt-get download` fetches only those seven
packages, so nothing else bleeds in from jammy. This is a stopgap for legacy
Python 2 scripts, not a maintained interpreter.

The 2.7 headers (`python2.7-dev`) are installed too, so `pip2` can build C
extensions — `psycopg2` against `libpq-dev` is the case this was added for. They
live in the same build step as the runtime on purpose: the `-dev` packages carry
strict `= <version>` dependencies on `libpython2.7-stdlib`, so splitting them
across layers risks a version skew.

`uv` (pinned to the host's 0.7.19) and `uvx` are also installed. uv's managed
Pythons (`~/.local/share/uv`) are shared into the box, and uv's package cache
is relocated to `~/git/.cache/uv` (set via `UV_CACHE_DIR` in the image and
`~/.config/uv/uv.toml` on the host). Since your `~/git` is at a different
absolute path on each machine, the launcher passes it to the build as
`--build-arg HOST_GIT_DIR="$GIT_DIR"`; a bare `podman build .` falls back to the
Linux box's path. Because that puts the cache on the same
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

## PostgreSQL (ephemeral test databases)

**PostgreSQL 16** (server + client) is installed for tests that need a real
Postgres. It is **not** a persistent service — the `pg-tmp` helper spins up a
throwaway cluster in a `mktemp` data dir with `trust` auth, listening only on a
unix socket in `/tmp`, and everything vanishes when the container exits. It runs
as `ubuntu` (postgres refuses to run as root anyway; there is no `sudo` here).

```sh
eval "$(pg-tmp)"               # inits + starts a cluster, exports PGHOST etc.
createdb testdb
psql -c 'select version();'
```

`pg-tmp` prints the `export`s to stdout and all progress to stderr, so it's safe
to `eval`. For pg-specific behaviour this is the way; if a suite can run on
SQLite instead, `php8.3-sqlite3` is already installed and needs no setup.

## Build toolchain

`build-essential` (gcc/g++/make/libc headers), `libpq-dev`, and `python3.12-dev`
are installed so packages without a usable wheel can be compiled in place — most
often `psycopg2`, which needs `pg_config` and the libpq headers from `libpq-dev`
plus `Python.h` from `python3.12-dev` (or `python2.7-dev` for the py2 build).
`libpq-dev` is interpreter-agnostic and serves both. Since there is no `sudo` in the box,
anything else a source build needs has to be added to the `Containerfile`
followed by a `claude-box --rebuild`.

## Browser tests (Chrome) — amd64 only

Google Chrome (matching the host version) is installed for browser-based tests
such as nmrhub's Angular/Karma unit tests. `CHROME_BIN` points at a shim
(`chrome-headless`) that adds the flags a containerized Chrome needs
(`--no-sandbox --headless=new --disable-gpu --disable-dev-shm-usage`), so a
`karma.conf.js` that says `browsers: ['Chrome']` runs unchanged. For a one-shot
run use Angular's non-watch flag, e.g. from `frontend/`:

```sh
npm test -- --watch=false      # or: ng test --watch=false
```

On an arm64 host Chrome is absent (see the arch table above) and the shim exits
127 with a note. Run browser tests on the host or on the Linux box; if they're
ever needed in an arm64 box, Playwright's chromium does have Linux arm64 builds
(`npx playwright install --with-deps chromium`) and could back the shim.

## Files

- `Containerfile` — image definition (Ubuntu 24.04 + Python 3.12 / 2.7 + Node 22 + PHP 8.3 + PostgreSQL 16 + Claude Code).
- `box-entry` — container entrypoint (runs `claude` by default; `bash`/`shell` for a shell).
- `pg-tmp` — spins up a throwaway PostgreSQL for tests (`eval "$(pg-tmp)"`).
- `claude-box` — host launcher (symlinked into `~/.local/bin`).

## Upgrading Claude Code

Claude Code is baked into the image (`npm install -g @anthropic-ai/claude-code@latest`)
and its auto-updater is disabled — it can't write to a root-owned global install
from inside the box, so it would only warn and try to "repair" itself. Upgrading
is therefore a rebuild:

```sh
claude-box --rebuild
```

`--rebuild` passes `--build-arg CLAUDE_CODE_REFRESH=<timestamp>`, which the
`Containerfile` consumes in the npm layer purely to invalidate its cache. Without
that, nothing in the `Containerfile` changes when a new version is published, so
every layer is a cache hit and the box silently keeps the version from the first
build — the rebuild looks like it worked while Claude's UI still asks you to
upgrade. Layers before the npm step stay cached, so the rebuild is quick.

## Notes

- **No `git push`**: SSH keys/tokens are intentionally not mounted, so Claude
  can commit but can't push. To allow pushing, mount a narrowly-scoped token
  rather than your SSH key.
- Your Claude login persists across runs because `~/.claude.json` is mounted
  read-write.
- Because `~/.claude` is mounted, anything your host settings point at runs
  inside the box too — including a custom `statusLine` command. Those hooks
  execute against the *image's* PATH, not the host's, so the interpreters they
  use have to exist here: `jq` is installed for exactly this reason (the
  status-line script parses Claude's JSON with it). A helper that shells out to
  something the image lacks fails silently and the status line just degrades.
- The image sets `CLAUDE_BOX=1` as a cheap marker so Claude can tell it's in the
  sandbox (test `$CLAUDE_BOX`, no process spawned) — used by the global
  `~/.claude/CLAUDE.md` note to know that `pg-tmp` and the pre-baked toolchain
  are available and that `apt-get` isn't.
- The host `docker` group (daemon-based, root-equivalent) is unrelated to this
  setup and unused; everything here goes through rootless Podman.
