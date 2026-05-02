FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source

FROM debian:13.4

ENV PYTHONUNBUFFERED=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# 完整系统工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git openssh-client docker-cli tini \
        curl wget unzip sudo vim net-tools iputils-ping dnsutils \
        python3-pip python3-venv python-is-python3 \
        && rm -rf /var/lib/apt/lists/*

# 创建用户 + 免密 sudo（NAS 友好）
RUN useradd -u 10000 -m -d /opt/data hermes && \
    echo "hermes ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/hermes && \
    chmod 0440 /etc/sudoers.d/hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
#
# ui-tui/packages/hermes-ink/ is copied IN FULL (not just its manifests)
# because it is referenced as a `file:` workspace dependency from
# ui-tui/package.json.  Copying the tree up front lets npm resolve the
# workspace to real content instead of stopping at a bare package.json.
COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/
COPY ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

# `npm_config_install_links=false` forces npm to install `file:` deps as
# symlinks (the npm 10+ default) even on Debian's older bundled npm 9.x,
# which defaults to `install-links=true` and installs file deps as *copies*.
# The host-side package-lock.json is generated with a newer npm that uses
# symlinks, so an install-as-copy produces a hidden node_modules/.package-lock.json
# that permanently disagrees with the root lock on the @hermes/ink entry.
# That disagreement trips the TUI launcher's `_tui_need_npm_install()`
# check on every startup and triggers a runtime `npm install` that then
# fails with EACCES (node_modules/ is root-owned from build time).
ENV npm_config_install_links=false

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

COPY --chown=hermes:hermes . .

# Build browser dashboard and terminal UI assets.
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build

USER root
RUN chmod -R a+rX /opt/hermes

# 预置宽松配置
COPY --chown=hermes:hermes docker/custom-config.yaml /opt/hermes/hermes_cli/config/default.yaml

# Python 依赖
RUN uv venv && \
    uv pip install --no-cache-dir -e ".[all]" && \
    uv pip install --no-cache-dir requests httpx aiohttp beautifulsoup4 pandas numpy

ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/data/.local/bin:${PATH}"

VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]
