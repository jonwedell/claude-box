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
# git / cvs               - repo operations
# ripgrep                 - Claude's search tooling
# less / procps           - pager + process tools Claude shells out to
# ca-certificates/curl/gnupg - TLS + NodeSource setup
# nodejs (22.x, NodeSource) - runtime for Claude Code
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        python3.12 python3.12-venv python3-pip \
        git cvs ripgrep less procps \
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

# PostgreSQL 16 server for ephemeral test databases. Not a persistent service:
# the `pg-tmp` helper inits a throwaway cluster in a mktemp dir with `trust`
# auth, listening only on a unix socket in /tmp, and it vanishes with the
# container. Ubuntu 24.04 ships PostgreSQL 16; its server binaries live under
# /usr/lib/postgresql/16/bin (not on PATH), which pg-tmp calls directly. Runs
# as `ubuntu` — postgres refuses to run as root anyway, and initdb/pg_ctl are
# happy as an ordinary user against a data dir it owns. php8.3-pgsql (above)
# and postgresql-client cover the client side.
RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*
COPY pg-tmp /usr/local/bin/pg-tmp
RUN chmod +x /usr/local/bin/pg-tmp

# C toolchain + headers for building native extensions from source — pip/uv fall
# back to compiling when a project pins a version with no manylinux wheel (e.g.
# psycopg2, which needs libpq-dev's pg_config and libpq headers, plus Python.h
# from python3.12-dev). libpq-dev is interpreter-agnostic, so it also covers
# python2 builds; the py2 headers come from jammy in the layer below. Kept as its
# own layer, after the language runtimes, so adding to it doesn't invalidate them.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev python3.12-dev \
    && rm -rf /var/lib/apt/lists/*

# Python 2.7 — noble dropped python2 from its own repos, so pull jammy's .debs
# (python2.7 2.7.18-13ubuntu1.5). Jammy and noble both ship libssl3/openssl 3.0
# and jammy's build is patched for it, so ssl/hashlib work (a from-source 2.7.18
# would not, since upstream 2.7 predates openssl 3.0). Noble's time_t64 transition
# renamed only libdb5.3 -> libdb5.3t64 among the deps we need; it still provides
# libdb-5.3.so, so we install it first and --force-depends past the one jammy
# Depends line that still names the pre-t64 package. `apt-get download` (not a
# full jammy pin) resolves the current jammy version and grabs *only* these seven
# packages, so nothing else leaks in from jammy. python2 -> python2.7 and pip2
# (last py2 pip via get-pip) are added so legacy scripts run unchanged.
#
# The -dev packages (libpython2.7, libpython2.7-dev, python2.7-dev) are here
# rather than in the build-toolchain layer above because they carry strict
# `= <version>` depends on libpython2.7-stdlib: they have to be downloaded and
# unpacked in the same step as the runtime or the versions can skew. jammy-security
# is listed alongside jammy so every one of them resolves to the patched
# 2.7.18-13ubuntu1.5 (plain `jammy` alone still offers 13ubuntu1). libexpat1-dev
# is noble's and satisfies the one build-dep the py2 headers name.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libdb5.3t64 libncursesw6 libtinfo6 \
        libbz2-1.0 libffi8 libexpat1 libexpat1-dev libnsl2 libtirpc3 \
        libreadline8 libsqlite3-0 libssl3 libcrypt1 media-types; \
    { echo 'deb http://archive.ubuntu.com/ubuntu jammy main universe'; \
      echo 'deb http://security.ubuntu.com/ubuntu jammy-security main universe'; \
    } > /etc/apt/sources.list.d/jammy-py2.list; \
    apt-get update; \
    ( cd /tmp && apt-get download \
        libpython2.7-minimal python2.7-minimal libpython2.7-stdlib python2.7 \
        libpython2.7 libpython2.7-dev python2.7-dev ); \
    rm /etc/apt/sources.list.d/jammy-py2.list; \
    dpkg -i --force-depends \
        /tmp/libpython2.7-minimal_*.deb /tmp/python2.7-minimal_*.deb \
        /tmp/libpython2.7-stdlib_*.deb /tmp/python2.7_*.deb \
        /tmp/libpython2.7_*.deb /tmp/libpython2.7-dev_*.deb \
        /tmp/python2.7-dev_*.deb; \
    ln -sf /usr/bin/python2.7 /usr/local/bin/python2; \
    curl -fsSL https://bootstrap.pypa.io/pip/2.7/get-pip.py -o /tmp/get-pip.py; \
    python2 /tmp/get-pip.py; \
    rm -f /tmp/*.deb /tmp/get-pip.py; \
    rm -rf /var/lib/apt/lists/*

# OpenJDK 21 + Ant — mirrors the host, which runs noble's own openjdk-21 packages.
# Same repo, same version, so java/javac land at /usr/bin and the JDK at
# /usr/lib/jvm/java-21-openjdk-amd64 exactly as on the host; anything hardcoding
# either path (or JAVA_HOME) works unchanged. Bind-mounting the host's /usr/lib/jvm
# would break the isolation model, so it's installed rather than shared.
# The package split matches the host: -jdk-headless carries javac/jar (so this is a
# build environment, not just a runtime) and the full -jre adds the AWT/Swing native
# libs the Swing apps under dictionary/validator (mailpad, jedit) link against.
# ant because every Java project here builds with build.xml, not maven/gradle; their
# builds use only core tasks plus a local macrodef, so ant-contrib/ant-optional
# (present on the host but unused) are deliberately left out.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-21-jdk-headless openjdk-21-jre ant \
    && rm -rf /var/lib/apt/lists/*

# Claude Code itself. The version comes from a build ARG (default `latest`), so a
# plain `podman build` installs the newest release. `claude-box --rebuild`
# resolves npm's current version and passes it as --build-arg CLAUDE_VERSION=...;
# a concrete value there busts this layer's cache whenever a new release exists,
# so --rebuild reliably updates. A bare `@latest` RUN line would instead stay
# cached forever (--rebuild is a plain `podman build`, not --no-cache) and never
# move. The launcher separately checks npm on startup and nudges toward
# --rebuild when the running box is behind.
# Also expose claude at $HOME/.local/bin/claude — the location Claude's
# install-health check expects — and disable the auto-updater, which would
# otherwise warn and try to "repair"/update a global install it can't write to
# from inside the container.
# Pre-create ~/.local/{bin,share/applications} owned by `ubuntu` so they stay
# writable after the ~/.local/share/uv bind-mount (which otherwise leaves the
# parent root-owned) — Chrome's first-run writes to share/applications.
ARG CLAUDE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION} && npm cache clean --force \
    && mkdir -p /home/ubuntu/.local/bin /home/ubuntu/.local/share/applications \
    && ln -sf "$(command -v claude)" /home/ubuntu/.local/bin/claude \
    && chown -R ubuntu:ubuntu /home/ubuntu/.local
# Keep uv's cache under ~/git (the same absolute path on host and in the box).
# Because ~/git is a single bind-mount, the cache and any project's .venv share
# one filesystem, so uv can hardlink wheels into venvs (fast) instead of copying.
# CLAUDE_BOX marks the environment as this sandbox, so Claude can cheaply tell
# it's running in the box (test for $CLAUDE_BOX) without shelling out — e.g. to
# decide whether pg-tmp / the pre-baked toolchain are available.
ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_BOX=1 \
    UV_CACHE_DIR=/zdrive/work/home/jon/git/.cache/uv \
    CHROME_BIN=/usr/local/bin/chrome-headless \
    PATH="/home/ubuntu/.local/bin:${PATH}"

COPY box-entry /usr/local/bin/box-entry
RUN chmod +x /usr/local/bin/box-entry

# Ubuntu 24.04 ships a non-root `ubuntu` user at UID 1000. Never run as root.
USER ubuntu
WORKDIR /home/ubuntu
ENTRYPOINT ["/usr/local/bin/box-entry"]
