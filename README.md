# Caddy ハンズオン

AI × Docker の見本です。静的なサイトを [Caddy](https://caddyserver.com/) で配ります。手元は Docker Compose（Web と、逆プロキシ先の小さな API）。公開先は [Render](https://render.com/) の無料 Web サービスで、コンテナは 1 つだけです。

Apple Silicon の OrbStack でも、Render がビルドする linux/amd64 でも、同じ Dockerfile を使います。公式イメージ `caddy:2.11.9-alpine`（2026 年 11 月の安定版）は両方のアーキテクチャを含みます。`platform` では固定しません。

## 手元で動かす

Docker が使えれば足ります。OrbStack でも Docker Desktop でも同じです。

```bash
docker compose up --build
```

ブラウザで <http://localhost:8080/> を開きます。機能の説明は <http://localhost:8080/features/> 、生存確認は <http://localhost:8080/healthz> です。

止めるときは `docker compose down` です。

HTML や CSS はボリューム経由で読んでいるので、保存して再読み込みすれば反映されます。Caddyfile を直したあとは `docker compose restart web` が必要です。Render ではこのマウントは無く、イメージをビルドした時点のファイルが使われます。

## 確認スクリプト

Compose を起動し、`caddy validate` と curl によるスモークテストをまとめて走らせます。

```bash
./scripts/check.sh
```

行うことは次のとおりです。

- 公式イメージの中で `caddy validate` を実行する（公開用の Caddyfile、Compose が足す逆プロキシ、API 用 Caddyfile）
- `docker compose up -d --build --wait` で起動を待つ
- Compose の `http://127.0.0.1:8080/healthz` が `200` と本文 `ok` であること
- `Accept-Encoding: gzip` でトップページに `Content-Encoding: gzip` が付くこと
- `Accept-Encoding: zstd` で機能ページに `Content-Encoding: zstd` が付くこと
- `/api/hello` が 2 台目の JSON を返すこと
- マウントなしの単体コンテナ（Render と同じファイル構成）では `/healthz` と圧縮は成功し、`/api/hello` は 200 にならないこと

終わったあとも Compose は起動したままです。単体コンテナの確認用プロセスだけ消します。

## Caddyfile を節ごとに

ファイルはリポジトリ直下の `Caddyfile` です。`handle` で分けたルート以外のディレクティブは、書いた順ではなく Caddy が決めた順で実行されます。見出しの順は、読むための区切りです。

### グローバルオプション

サイトブロックの前に書きます。

- `auto_https off` は、証明書の自動取得と HTTP から HTTPS への転送を止めます。Render では TLS が入口で終わるため、コンテナの中で証明書を取りに行きません。
- サイトアドレスが `:ポート` だけなので、待受そのものも平文の HTTP です。`auto_https off` は、あとからホスト名を書いたときに証明書取得が始まらないための指定です。
- `servers { protocols h1 }` は、待ち受けを HTTP/1.1 だけにします。TLS が無いと HTTP/2 と HTTP/3 は使えず、指定しないと起動のたびに「skipped」という警告が出ます。ブラウザとの HTTP/2 は Render の入口が担当します。
- `admin off` は、設定変更用の管理 API を無効にします。この見本では使いません。起動ログの `admin endpoint disabled` は、その指定が効いているという意味で、失敗ではありません。
- グローバルの `log` は、起動や警告などプロセス自身のログを JSON で標準出力へ出します。

### 待ち受けアドレス

`:{$PORT:8080}` は、環境変数 `PORT` があればその番号、無ければ 8080 です。先頭のコロンは全インターフェース（`0.0.0.0`）を意味します。`127.0.0.1` だけにすると、Render のプロキシから届きません。

手元の Compose は `PORT=8080` です。`render.yaml` は `PORT=10000` を渡します。

### 圧縮

`encode zstd gzip` は本文を圧縮します。クライアントの `Accept-Encoding` で選び、q 値が同じなら先に書いた zstd を使います。gzip は、zstd を話さない相手向けです。

既定では本文が 512 バイト未満だと圧縮しません。`/healthz` の `ok` が平文なのはそのためです。圧縮した応答には `Content-Length` が付かず、`Vary: Accept-Encoding` が付きます。

### セキュリティヘッダ

スニペット `(security_headers)` にまとめ、通常の応答と 404 の両方から `import` します。404 は別のルートなので、サイトブロックに書いただけではヘッダが乗りません。

`header` ブロックに `defer` を付け、応答を返す直前に適用します。こうしないと、後段が付けた `Server` ヘッダを消せません。

付けているものは次のとおりです。

- `X-Content-Type-Options: nosniff` — 内容の型をブラウザに推測させない
- `X-Frame-Options: DENY` — 他サイトのフレームに埋め込まれない（古いクライアント向け）
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Content-Security-Policy` — 同一オリジンの CSS、JS、画像だけを読む。`frame-ancestors 'none'` が現在の埋め込み制御
- `Permissions-Policy` — カメラ、マイク、位置情報を使わない
- `Server` ヘッダの削除 — サーバ名を隠すだけで、これ自体は防御になりません

廃止された `X-XSS-Protection` は付けていません。

HSTS（`Strict-Transport-Security`）は、ブラウザに「このホストは以後 HTTPS で開け」と記憶させます。localhost や `127.0.0.1` に付けると、手元の HTTP が開けなくなるので、その 2 つのホストでは付けません。Render のホスト名で届いた応答にだけ、180 日の `max-age` を付けます。この見本はサブドメインを持たないので `includeSubDomains` は付けません。

### キャッシュ

HTML など文書は `Cache-Control: no-cache` です。保存はしてよいが、使う前に再検証します。`.css` `.js` `.svg` などの静的ファイルは `public, max-age=86400`（1 日）です。ファイル名に内容のハッシュを付けていないので `immutable` にはしません。`/healthz` は `no-store` です。

### アクセスログ

サイトブロックの `log` は、1 リクエストにつき 1 行の JSON を標準出力へ書きます。`docker compose logs web` や、Render のログ画面にそのまま出ます。

手前にプロキシがいるとき、記録されるクライアントアドレスは訪問者ではなく入口側になることがあります。この見本では直しません。

### ヘルスチェック

`handle /healthz` は `200` と本文 `ok` だけを返します。データベースなどの問い合わせはしません。Render の `healthCheckPath` も `/healthz` です。

### 静的ファイル

`root * /srv` と `file_server` で、イメージにコピーした `site/` を配ります。公式イメージの初期ページは `/usr/share/caddy` にありますが、この見本では使いません。ディレクトリを開くと `index.html` が返ります。

存在しないパスは `handle_errors 404` が状態コード 404 のまま、`site/404.html` の本文に差し替えます。502 のような別のエラーは、このページにすり替えません。

### 手元だけの逆プロキシ

`import /etc/caddy/optional/*.caddy` は、そのディレクトリにある設定片をサイトブロックの中へ読み込みます。

- イメージに入っている `optional/noop.caddy` はコメントだけです。空の glob だと Caddy が警告を出すので、何もしないファイルを置いています。
- `compose/proxy.caddy` は Compose が実行時にマウントします。`/api/*` をサービス名 `api` の 8080 番へ渡します。パスは剥がしません。
- API 用コンテナはホストのポートを開けません。`docker-compose.yml` の `api` サービスだけが受けます。
- Dockerfile は `compose/proxy.caddy` をコピーしません。Render では `/api/hello` を配らないので、404 になります。

`http://localhost:8080/features/` のボタンから、手元では 2 台目の JSON を確認できます。

## Render の無料枠へ出す

このリポジトリは Blueprint の定義だけを含みます。ここからの手順は、読者自身がダッシュボードで行います。

デプロイしたいブランチに、この `render.yaml` と Dockerfile が入っている必要があります。通常は PR をマージして、既定ブランチ（`main`）に入った状態にします。ブランチを直接公開したい場合は、手順 4 でそのブランチを選びます。

1. [Render Dashboard](https://dashboard.render.com) を開く。アカウントが無ければ無料の登録をする。
2. **New > Blueprint** を選ぶ。
3. Git プロバイダをまだ接続していなければ接続し、このリポジトリの **Connect** を押す。
4. Blueprint の名前を付け、リンクするブランチを選ぶ。**Blueprint Path** は空欄のままでよい（リポジトリ直下の `render.yaml` が使われる）。
5. 適用される変更を確認する。Web サービス `caddy-handson` が 1 つ、`runtime: docker`、`plan: free`、ヘルスチェックパス `/healthz`、リージョン `singapore` であること。`PORT` は `10000`。
6. **Deploy Blueprint** を押す。
7. デプロイが完了したら `https://<サービス名>.onrender.com/` と、同じホストの `/healthz` を開く。`/healthz` は `200` と `ok` を返す。

`render.yaml` の `region` は、日本からの読者向けに `singapore` にしています。未指定時の既定は `oregon` です。作成後にリージョンは変更できないので、変えるなら最初の適用前にファイルを編集します。

接続したブランチへ push し、`render.yaml` かサービス定義に関係する変更があると、Render が再デプロイします（`autoDeployTrigger: commit`）。

### 無料枠で知っておくこと

- 受信が 15 分無いと、無料の Web サービスはスリープする。次のリクエストで起動し、1 分ほどかかることがある。その間、ブラウザには Render の起動画面が出る。
- スリープ中は無料インスタンス時間を消費しない。ワークスペースあたり月 750 時間で、使い切るとその月のあいだ無料 Web サービスは停止する。
- ローカルファイルシステムは再デプロイ、再起動、スリープで消える。この見本は配るファイルをイメージにコピーしているだけで、書き込みデータは持たない。無料枠には永続ディスクを付けられない。
- 無料枠の Web サービスはインスタンス 1 つで、水平スケールできない。だから API 用の 2 台目は Render には置かない。
- スリープ中の `/robots.txt` には、Render が `Disallow: /` を返す。この応答はコンテナに届かず、スリープ解除のきっかけにもならない。起動中はリポジトリの `site/robots.txt` が返る。
- アウトバウンドの転送量と、ビルドのパイプライン分は、ワークスペースの月間含まれる量にカウントされる。

TLS 証明書は Render が入口で付けます。コンテナ内の Caddy は平文 HTTP だけです。

## ファイル

| パス | 役割 |
| --- | --- |
| `Caddyfile` | Web サーバの設定。日本語のコメント付き |
| `Dockerfile` | `caddy:2.11.9-alpine` に設定と `site/` を入れる |
| `docker-compose.yml` | 手元用。Web と API の 2 サービス |
| `compose/proxy.caddy` | 手元だけでマウントする逆プロキシ |
| `optional/noop.caddy` | イメージに入れる、何もしない設定片 |
| `api/Caddyfile` | 2 台目。`/api/hello` の JSON |
| `site/` | 静的ファイル |
| `render.yaml` | 無料 Docker Web サービスの Blueprint |
| `scripts/check.sh` | `caddy validate` とスモークテスト |

名称は説明のための記載です。この見本は Caddy、Docker、Render の公式サイトではなく、ロゴ画像も置いていません。

## ライセンス

[MIT License](./LICENSE) です。
