#!/usr/bin/env bash
# Caddyfile の検証と、起動中コンテナへのスモークテスト。
#
#   ./scripts/check.sh
#
# Compose が止まっていれば起動する。終了後も Compose は起動したままにする。
# 併せて、マウントなしの単体コンテナ（Render と同じファイル構成）も確認する。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

smoke() {
  local url="$1"
  local api_mode="$2"
  local body headers code encoding magic host_headers

  body="$(mktemp)"
  headers="$(mktemp)"
  host_headers="$(mktemp)"

  code="$(curl -sS -o "$body" -w "%{http_code}" "${url}/healthz")"
  if [[ "$code" != "200" || "$(cat "$body")" != "ok" ]]; then
    echo "FAIL ${url}/healthz が 200 ok ではありません (HTTP ${code})" >&2
    cat "$body" >&2 || true
    exit 1
  fi
  echo "OK ${url}/healthz 200"

  curl -sS -D "$headers" -o "$body" -H "Accept-Encoding: gzip" "${url}/"
  encoding="$(grep -i '^content-encoding:' "$headers" | head -n 1 | tr -d '\r' || true)"
  magic="$(od -An -tx1 -N2 "$body" | tr -d ' \n')"
  if [[ "$encoding" != *[Gg][Zz][Ii][Pp]* || "$magic" != "1f8b" ]]; then
    echo "FAIL ${url}/ の gzip が確認できません (${encoding:-なし}, magic=${magic})" >&2
    exit 1
  fi
  echo "OK ${url}/ ${encoding}"

  curl -sS -D "$headers" -o "$body" -H "Accept-Encoding: zstd" "${url}/features/"
  encoding="$(grep -i '^content-encoding:' "$headers" | head -n 1 | tr -d '\r' || true)"
  magic="$(od -An -tx1 -N4 "$body" | tr -d ' \n')"
  if [[ "$encoding" != *[Zz][Ss][Tt][Dd]* || "$magic" != "28b52ffd" ]]; then
    echo "FAIL ${url}/features/ の zstd が確認できません (${encoding:-なし}, magic=${magic})" >&2
    exit 1
  fi
  echo "OK ${url}/features/ ${encoding}"

  if ! grep -qi '^x-content-type-options:[[:space:]]*nosniff' "$headers"; then
    echo "FAIL X-Content-Type-Options: nosniff がありません" >&2
    exit 1
  fi
  echo "OK X-Content-Type-Options: nosniff"

  if grep -qi '^strict-transport-security:' "$headers"; then
    echo "FAIL 127.0.0.1 への応答に HSTS が付いています" >&2
    exit 1
  fi
  curl -sS -D "$host_headers" -o /dev/null -H "Host: handson.example" "${url}/"
  if ! grep -qi '^strict-transport-security:' "$host_headers"; then
    echo "FAIL 公開ホスト名への応答に HSTS がありません" >&2
    exit 1
  fi
  echo "OK HSTS は localhost / 127.0.0.1 以外だけ"

  code="$(curl -sS -D "$headers" -o "$body" -w "%{http_code}" "${url}/no-such-page")"
  if [[ "$code" != "404" ]] || ! grep -q "ページがありません" "$body"; then
    echo "FAIL ${url}/no-such-page が 404 の案内ページではありません (HTTP ${code})" >&2
    exit 1
  fi
  if ! grep -qi '^x-content-type-options:[[:space:]]*nosniff' "$headers"; then
    echo "FAIL 404 に X-Content-Type-Options: nosniff がありません" >&2
    exit 1
  fi
  if grep -qi '^server:' "$headers"; then
    echo "FAIL 404 に Server ヘッダが残っています" >&2
    exit 1
  fi
  echo "OK ${url}/no-such-page 404"

  code="$(curl -sS -o "$body" -w "%{http_code}" "${url}/api/hello")"
  if [[ "$api_mode" == "expect_api" ]]; then
    if [[ "$code" != "200" ]] || ! grep -q '"service":"api"' "$body"; then
      echo "FAIL ${url}/api/hello が API の JSON ではありません (HTTP ${code})" >&2
      exit 1
    fi
    echo "OK ${url}/api/hello 200"
  else
    if [[ "$code" == "200" ]]; then
      echo "FAIL 単体コンテナが /api/hello を 200 で返しています" >&2
      exit 1
    fi
    echo "OK ${url}/api/hello は HTTP ${code}（2 台目は同梱していない）"
  fi

  rm -f "$body" "$headers" "$host_headers"
}

version="$(sed -n 's/^ARG CADDY_VERSION=//p' Dockerfile | head -n 1 | tr -d '[:space:]')"
if [[ -z "$version" ]]; then
  echo "FAIL Dockerfile の ARG CADDY_VERSION を読めませんでした" >&2
  exit 1
fi
image="caddy:${version}-alpine"
if ! grep -q "image: ${image}" docker-compose.yml; then
  echo "FAIL docker-compose.yml の api イメージが ${image} と一致しません" >&2
  exit 1
fi

echo "==> caddy validate (${image}) 公開用 Caddyfile"
docker run --rm \
  -v "${root}/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "${root}/optional/noop.caddy:/etc/caddy/optional/noop.caddy:ro" \
  "${image}" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

echo "==> caddy validate (${image}) Compose の逆プロキシ込み"
docker run --rm \
  -v "${root}/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "${root}/optional/noop.caddy:/etc/caddy/optional/noop.caddy:ro" \
  -v "${root}/compose/proxy.caddy:/etc/caddy/optional/proxy.caddy:ro" \
  "${image}" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

echo "==> caddy validate (${image}) api コンテナ"
docker run --rm \
  -v "${root}/api/Caddyfile:/etc/caddy/Caddyfile:ro" \
  "${image}" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

echo "==> docker compose up"
docker compose up -d --build --wait

base="${BASE_URL:-http://127.0.0.1:8080}"
echo "==> smoke test ${base} （Compose。逆プロキシあり）"
smoke "$base" expect_api

# compose logs は標準エラーへ出る。
if docker compose logs web --no-color --since 3m 2>&1 | grep -q '"logger":"http.log.access'; then
  echo "OK JSON アクセスログが標準出力に出ている"
else
  echo "FAIL web のログに JSON アクセスログがありません" >&2
  docker compose logs web --no-color --tail 40 >&2 || true
  exit 1
fi

echo "==> 単体コンテナ（マウントなし。Render と同じファイル構成）"
renderlike="caddy-handson-renderlike"
docker rm -f "$renderlike" >/dev/null 2>&1 || true
docker run -d --name "$renderlike" -e PORT=8080 -p 18080:8080 caddy-handson:local >/dev/null
cleanup() {
  docker rm -f "$renderlike" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if curl -fsS "http://127.0.0.1:18080/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.4
done
if [[ "$ready" != "1" ]]; then
  echo "FAIL 単体コンテナが /healthz に応答しません" >&2
  docker logs "$renderlike" >&2 || true
  exit 1
fi

echo "==> smoke test http://127.0.0.1:18080 （単体コンテナ）"
smoke "http://127.0.0.1:18080" expect_no_api

echo "OK すべての確認が通りました"
echo "ブラウザで開く URL: http://localhost:8080/"
