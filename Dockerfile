# syntax=docker/dockerfile:1

# 公式の Caddy イメージ。動くタグの latest ではなく、安定版を固定する。
# 2.11.9-alpine は linux/amd64 と linux/arm64 の両方がある。
# Apple Silicon の OrbStack では arm64、Render のビルドでは amd64 になる。
# どちらか一方に固定する platform 指定は書かない。
ARG CADDY_VERSION=2.11.9
FROM caddy:${CADDY_VERSION}-alpine

# 待受ポートは Caddyfile の {$PORT} が決める。
# EXPOSE は手元の既定 8080 を示すだけで、Render では PORT（10000）で待つ。
EXPOSE 8080

COPY Caddyfile /etc/caddy/Caddyfile
# 中身はコメントだけ。glob の import が空振り警告にならないようにする。
# 逆プロキシの設定はここへコピーしない（Render はコンテナ 1 つ）。
COPY optional/noop.caddy /etc/caddy/optional/noop.caddy
COPY site /srv

# 公式イメージの CMD を使う:
# caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
