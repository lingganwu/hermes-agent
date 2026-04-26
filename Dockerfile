FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source

FROM debian:13.4

ENV PYTHONUNBUFFERED=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# 完整环境 + 回归 0.8 自由度（已包含所有你需要的工具）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git openssh-client docker-cli tini \
        curl wget unzip sudo vim net-tools iputils-ping dnsutils \
        python3-pip python3-venv python-is-python3 \
        && rm -rf /var/lib/apt/lists/*

RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd web && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

COPY --chown=hermes:hermes . .

RUN cd web && npm run build

USER root
RUN chmod -R a+rX /opt/hermes

# ---------- 关键：预置宽松配置（禁用 Tirith + 所有 0.9+ 安全限制） ----------
COPY --chown=hermes:hermes docker/custom-config.yaml /opt/hermes/hermes_cli/config/default.yaml

# Python 环境
RUN uv venv && \
    uv pip install --no-cache-dir -e ".[all]" && \
    uv pip install --no-cache-dir requests httpx aiohttp beautifulsoup4 pandas numpy

ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/data/.local/bin:${PATH}"

VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]
