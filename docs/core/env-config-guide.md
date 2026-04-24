# Beta/Prod 環境設定ガイド

**参照**: `policy.md §4.1 (12-factor)` · `environment-abstraction.md §3.2, §4.1, §8`  
**最終更新**: 2026-04-24

---

## 1. 原則

- 全環境で **同一 OCI Image (同一 SHA)** を使用
- 差異は **環境変数のみ** で吸収（12-Factor App §3）
- `STORAGE_PROVIDER=aws-s3` / `QUEUE_PROVIDER=aws-sqs` / `MAIL_PROVIDER=aws-ses` は**禁止**（CI grep で検出）

---

## 2. 環境変数カタログ

### 2.1 インフラ切替（Feature Flag と対応）

| 変数名 | Beta 値 | Prod 値 | Flipt フラグ |
|---|---|---|---|
| `STORAGE_PROVIDER` | `garage` | `oci-oss` | `infra.storage.provider` |
| `QUEUE_PROVIDER` | `redis-bullmq` | `oci-queue` | `infra.queue.provider` |
| `MAIL_PROVIDER` | `postfix-smtp` | `postfix-smtp` | `infra.mail.provider` |
| `DB_HOST` | `mysql` (compose) | OCI MySQL FQDN | — |
| `REDIS_HOST` | `redis` (compose) | OCI Redis FQDN | — |

### 2.2 認証

| 変数名 | 説明 |
|---|---|
| `COGNITO_USER_POOL_ID` | Cognito ユーザープール ID |
| `COGNITO_CLIENT_ID` | Cognito アプリクライアント ID |
| `COGNITO_JWKS_URI` | `https://cognito-idp.{region}.amazonaws.com/{pool}/.well-known/jwks.json` |
| `JWT_EXPIRY_SEC` | アクセストークン有効秒（デフォルト: 3600） |

### 2.3 ストレージ

| 変数名 | Beta 値 | Prod 値 |
|---|---|---|
| `GARAGE_ENDPOINT` | `http://garage:3900` | — |
| `OCI_NAMESPACE` | — | OCI Object Storage namespace |
| `OCI_BUCKET_MEDIA` | — | OCI バケット名 |
| `PRESIGNED_URL_TTL_SEC` | `3600` | `3600` |

### 2.4 メール (Postfix STARTTLS)

| 変数名 | 値 |
|---|---|
| `SMTP_HOST` | Postfix ホスト |
| `SMTP_PORT` | `587` (Submission) |
| `SMTP_TLS_MODE` | `starttls` (必須) |
| `SMTP_FROM` | `noreply@recerdo.app` |

### 2.5 Saga タイムアウト

| 変数名 | デフォルト | 説明 |
|---|---|---|
| `SAGA_TIMEOUT_SEC` | `600` | Saga 全体 SLA 10 分 (policy.md §8.6) |
| `OUTBOX_MAX_RETRY` | `3` | 3 回失敗で `DEAD` |
| `OUTBOX_POLL_INTERVAL_MS` | `5000` | Outbox ポーリング間隔 |

---

## 3. .env.example ファイル規約

各リポジトリのルートに以下 2 ファイルを配置する:

```
envs/
  beta.env.example    # Beta (XServer VPS / k3s) 用
  prod.env.example    # Prod (OCI) 用
```

### envs/beta.env.example テンプレート

```env
# === Infra ===
STORAGE_PROVIDER=garage
QUEUE_PROVIDER=redis-bullmq
MAIL_PROVIDER=postfix-smtp

# === Database ===
DB_HOST=mysql
DB_PORT=3306
DB_NAME=recerdo
DB_USER=recerdo
DB_PASSWORD=CHANGE_ME

# === Redis ===
REDIS_HOST=redis
REDIS_PORT=6379

# === Cognito ===
COGNITO_USER_POOL_ID=ap-northeast-1_XXXXXXXXX
COGNITO_CLIENT_ID=XXXXXXXXXX
COGNITO_JWKS_URI=https://cognito-idp.ap-northeast-1.amazonaws.com/ap-northeast-1_XXXXXXXXX/.well-known/jwks.json

# === Garage (Beta S3-compatible) ===
GARAGE_ENDPOINT=http://garage:3900
GARAGE_ACCESS_KEY=CHANGE_ME
GARAGE_SECRET_KEY=CHANGE_ME

# === Saga ===
SAGA_TIMEOUT_SEC=600
OUTBOX_MAX_RETRY=3
OUTBOX_POLL_INTERVAL_MS=5000

# === SMTP ===
SMTP_HOST=localhost
SMTP_PORT=587
SMTP_TLS_MODE=starttls
SMTP_FROM=noreply@recerdo.app
SMTP_USER=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
```

---

## 4. Feature Flag 初期投入

`recerdo-infra/scripts/flipt-init.sh` で以下フラグを Flipt に登録する:

```bash
# scripts/flipt-init.sh 参照
infra.queue.provider        # beta: redis-bullmq / prod: oci-queue
infra.storage.provider      # beta: garage       / prod: oci-oss
infra.mail.provider         # beta: postfix-smtp / prod: postfix-smtp
infra.queue.killswitch      # kill switch: OFF
infra.dualWrite.enabled     # dual write: OFF (移行期のみ ON)
INFRA_BETA_K3S_ENABLED      # k3s モード: false
```

実行:
```bash
cd recerdo-infra
bash scripts/flipt-init.sh http://localhost:8080
```

---

## 5. 禁止キーワード CI チェック

`.github/workflows/security.yml` に以下 grep ルールを追加済み:

```yaml
- name: Prohibited provider keywords
  run: |
    ! grep -rE 'STORAGE_PROVIDER=aws-s3|QUEUE_PROVIDER=aws-sqs|MAIL_PROVIDER=aws-ses' \
      envs/ .env* 2>/dev/null \
      || (echo "ERROR: prohibited AWS provider found" && exit 1)
```

---

## 6. SMTP STARTTLS 確認コマンド

```bash
# TLS 1.2+ で接続確認
openssl s_client -starttls smtp -connect <SMTP_HOST>:587 -brief

# 期待出力: Protocol: TLSv1.2 or TLSv1.3
# setup-mail-server.sh で smtpd_tls_security_level=encrypt を確認済み
```

---

## 7. MariaDB 10.11 CI Matrix

全バックエンドリポジトリの `test.yml` に以下 matrix を設定:

```yaml
strategy:
  matrix:
    db-version: [mysql:8.0, mariadb:10.11]
services:
  db:
    image: ${{ matrix.db-version }}
```

`ci-templates/test.yml` を参照して全リポジトリに適用する (policy.md §3.1)。
