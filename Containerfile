# claude-box: a rootless-Podman sandbox for running Claude Code unattended.
#
# Base is Ubuntu 24.04 specifically so that python3.12 lives at
# /usr/bin/python3.12 — the same path your host used to create its venvs.
# That makes `source venv/bin/activate` work unchanged inside the box
# (the venv's bin/python symlink and pyvenv.cfg base-executable both point
# at /usr/bin/python3.12).
#
# The host UID (1000) maps to Ubuntu's built-in `ubuntu` user (also UID 1000)
# via `--userns=keep-id`, so files Claude writes under ~/git are owned by you
# on the host and your IDE edits them with no ownership friction.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# python3.12 + venv/pip   - matches host interpreter path for venv compatibility
# git                     - repo operations
# ripgrep                 - Claude's search tooling
# less / procps           - pager + process tools Claude shells out to
# ca-certificates/curl/gnupg - TLS + NodeSource setup
# nodejs (22.x, NodeSource) - runtime for Claude Code
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        python3.12 python3.12-venv python3-pip \
        git ripgrep less procps \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# uv (Astral), pinned to match the host version, for uv-managed projects.
# Copied as a static binary from the official image — no pip / PEP-668 hassle.
COPY --from=ghcr.io/astral-sh/uv:0.7.19 /uv /uvx /usr/local/bin/

# Google Chrome (matches the host) for browser-based tests — e.g. nmrhub's
# Angular/Karma unit tests via `ng test`. Installing the .deb from Google's apt
# repo pulls in all the runtime libs Chrome needs; fonts-liberation covers
# rendering. The chrome-headless shim (CHROME_BIN below) adds the flags a
# containerized Chrome requires, so karma.conf's `browsers: ['Chrome']` works.
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable fonts-liberation \
    && rm -rf /var/lib/apt/lists/*
COPY chrome-headless /usr/local/bin/chrome-headless
RUN chmod +x /usr/local/bin/chrome-headless

# PHP 8.3 — matches the host's /usr/bin/php (PHP 8.3.x). Ubuntu 24.04 ships
# PHP 8.3 in its own repos at the same /usr/bin/php path, so php scripts and
# tooling run unchanged inside the box, the same way python3.12 does.
# php8.3-cli pulls the interpreter and php8.3-fpm the FastCGI runtime; the
# extension set mirrors what the host projects actually use (pgsql/sqlite3 for
# DB access, gd for images, zip for archives). composer handles dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
        php8.3-cli php8.3-common php8.3-fpm \
        php8.3-pgsql php8.3-sqlite3 php8.3-gd php8.3-zip \
        composer \
    && rm -rf /var/lib/apt/lists/*

# Claude Code itself. Also expose it at $HOME/.local/bin/claude — the location
# Claude's install-health check expects — and disable the auto-updater, which
# would otherwise warn and try to "repair"/update a global install it can't
# write to from inside the container.
# Pre-create ~/.local/{bin,share/applications} owned by `ubuntu` so they stay
# writable after the ~/.local/share/uv bind-mount (which otherwise leaves the
# parent root-owned) — Chrome's first-run writes to share/applications.
RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force \
    && mkdir -p /home/ubuntu/.local/bin /home/ubuntu/.local/share/applications \
    && ln -sf "$(command -v claude)" /home/ubuntu/.local/bin/claude \
    && chown -R ubuntu:ubuntu /home/ubuntu/.local
# Keep uv's cache under ~/git (the same absolute path on host and in the box).
# Because ~/git is a single bind-mount, the cache and any project's .venv share
# one filesystem, so uv can hardlink wheels into venvs (fast) instead of copying.
ENV DISABLE_AUTOUPDATER=1 \
    UV_CACHE_DIR=/zdrive/work/home/jon/git/.cache/uv \
    CHROME_BIN=/usr/local/bin/chrome-headless \
    PATH="/home/ubuntu/.local/bin:${PATH}"

COPY box-entry /usr/local/bin/box-entry
RUN chmod +x /usr/local/bin/box-entry

# Ubuntu 24.04 ships a non-root `ubuntu` user at UID 1000. Never run as root.
USER ubuntu
WORKDIR /home/ubuntu
ENTRYPOINT ["/usr/local/bin/box-entry"]
