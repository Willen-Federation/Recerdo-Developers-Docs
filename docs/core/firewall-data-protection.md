# ファイアウォール & データプロテクション

> **対象フェーズ**: PoC/Beta（段階的に強化）  
> **最終更新**: 2026-04-15  
> **ステータス**: 承認待ち

---

## 1. セキュリティアーキテクチャ概要

### 1.1 PoC/Beta セキュリティレイヤー

```
                        Internet
                           │
                    ┌──────▼──────┐
                    │  Cloudflare │  ← Layer 1: CDN + DDoS + WAF
                    │  (Free Plan)│
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  VPS        │  ← Layer 2: OS Firewall
                    │  iptables / │
                    │  ufw        │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  nginx      │  ← Layer 3: Reverse Proxy
                    │  (TLS/Rate  │     TLS終端 + Rate Limiting
                    │   Limiting) │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼────┐ ┌────▼─────┐ ┌────▼─────┐
        │ Go Auth  │ │ Go Core  │ │ Go Event │  ← Layer 4: App Security
        │ (JWT)    │ │ (RBAC)   │ │ (AuthZ)  │     認証・認可・バリデーション
        └─────┬────┘ └────┬─────┘ └────┬─────┘
              │            │            │
        ┌─────▼────────────▼────────────▼─────┐
        │           MySQL 8.0                  │  ← Layer 5: Data Security
        │    (暗号化 at rest + TLS接続)          │     暗号化 + アクセス制御
        └─────────────────────────────────────┘
```

---

## 2. Layer 1: Cloudflare（CDN + DDoS + WAF）

### 2.1 なぜ Cloudflare Free Plan か

| 機能 | Cloudflare Free | AWS WAF | 備考 |
|---|---|---|---|
| DDoS防御 | **無制限・無料** | Shield Standard (L3/L4のみ) | Cloudflare は L7 まで無料で防御 |
| WAF ルール | 5 カスタムルール | $5/ACL + $1/ルール + $0.60/100万リクエスト | PoC/Beta では AWS WAF は過剰 |
| SSL/TLS | **無料** | ACM無料（但しALB必要: $16/月） | Cloudflare は CDN 経由で TLS 提供 |
| Rate Limiting | 1ルール無料 | WAF Rate-based Rule | 基本的な防御は無料枠で可能 |
| 月額コスト | **$0** | **$30〜50+** | |

### 2.2 Cloudflare 設定

```
DNS設定:
  api.recerdo.app  → A  → VPS_IP (Proxied: ON)
  app.recerdo.app  → A  → VPS_IP (Proxied: ON)

SSL/TLS:
  暗号化モード: Full (Strict)
  最小TLSバージョン: TLS 1.2
  自動HTTPS書き換え: ON
  HSTS: ON (max-age=31536000, includeSubDomains)

Firewall Rules (5ルール上限):
  1. Block: 既知の悪意あるBot (cf.client.bot AND NOT cf.client.bot)
  2. Challenge: 非日本・非米国からの/api/auth/* アクセス
  3. Block: /admin/* への外部アクセス
  4. Rate Limit: /api/auth/login → 10 req/min per IP
  5. Block: User-Agent が空のリクエスト

Security Level: Medium
Bot Fight Mode: ON
Browser Integrity Check: ON
```

### 2.3 Cloudflare → Origin 通信の保護

```
# nginx で Cloudflare の IP のみ許可
# Cloudflare IP ranges: https://www.cloudflare.com/ips/

# /etc/nginx/conf.d/cloudflare-only.conf
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
real_ip_header CF-Connecting-IP;
```

---

## 3. Layer 2: OS ファイアウォール（ufw / iptables）

### 3.1 ufw 設定

```bash
# デフォルトポリシー
ufw default deny incoming
ufw default allow outgoing

# SSH（管理用 — IP制限推奨）
ufw allow from YOUR_ADMIN_IP to any port 22

# HTTP/HTTPS（Cloudflare経由）
ufw allow 80/tcp
ufw allow 443/tcp

# 他のポートはすべてブロック
# MySQL (3306), Redis (6379) は外部公開しない

ufw enable
```

### 3.2 SSH ハードニング

```bash
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
AllowUsers deploy
Protocol 2

# fail2ban 設定
# /etc/fail2ban/jail.local
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
```

### 3.3 Docker ネットワーク分離

```yaml
# docker-compose.yml
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true  # 外部アクセス不可

services:
  nginx:
    networks:
      - frontend
      - backend

  core-svc:
    networks:
      - backend  # nginx経由でのみアクセス可能

  mysql:
    networks:
      - backend  # Go サービスからのみアクセス可能

  redis:
    networks:
      - backend
```

---

## 4. Layer 3: nginx セキュリティ設定

### 4.1 TLS 設定

```nginx
# /etc/nginx/conf.d/ssl.conf
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
```

### 4.2 セキュリティヘッダー

```nginx
# /etc/nginx/conf.d/security-headers.conf
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self' https://api.recerdo.app wss://api.recerdo.app" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
```

### 4.3 Rate Limiting

```nginx
# /etc/nginx/conf.d/rate-limit.conf

# ゾーン定義
limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=api:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=upload:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=ws:10m rate=2r/s;

# 接続数制限
limit_conn_zone $binary_remote_addr zone=connlimit:10m;

server {
    # 認証エンドポイント（ブルートフォース防止）
    location /api/auth/login {
        limit_req zone=auth burst=3 nodelay;
        limit_conn connlimit 5;
        proxy_pass http://auth-svc:8080;
    }

    # 一般 API
    location /api/ {
        limit_req zone=api burst=50 nodelay;
        limit_conn connlimit 20;
        proxy_pass http://core-svc:8080;
    }

    # ファイルアップロード
    location /api/storage/upload {
        limit_req zone=upload burst=2 nodelay;
        client_max_body_size 10m;
        proxy_pass http://storage-svc:8080;
    }

    # WebSocket
    location /ws/ {
        limit_req zone=ws burst=5 nodelay;
        proxy_pass http://core-svc:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
    }
}
```

---

## 5. Layer 4: アプリケーションセキュリティ

### 5.1 JWT 検証ミドルウェア

```go
// middleware/auth.go — Firebase Auth JWT 検証
package middleware

import (
    "context"
    "net/http"
    "strings"

    firebase "firebase.google.com/go/v4"
    "firebase.google.com/go/v4/auth"
    "github.com/gin-gonic/gin"
)

type AuthMiddleware struct {
    client *auth.Client
}

func NewAuthMiddleware(app *firebase.App) (*AuthMiddleware, error) {
    client, err := app.Auth(context.Background())
    if err != nil {
        return nil, err
    }
    return &AuthMiddleware{client: client}, nil
}

func (m *AuthMiddleware) Authenticate() gin.HandlerFunc {
    return func(c *gin.Context) {
        // Bearer トークン抽出
        authHeader := c.GetHeader("Authorization")
        if authHeader == "" {
            c.AbortWithStatusJSON(http.StatusUnauthorized,
                gin.H{"error": "missing authorization header"})
            return
        }

        parts := strings.SplitN(authHeader, " ", 2)
        if len(parts) != 2 || parts[0] != "Bearer" {
            c.AbortWithStatusJSON(http.StatusUnauthorized,
                gin.H{"error": "invalid authorization format"})
            return
        }

        // Firebase ID Token 検証
        token, err := m.client.VerifyIDToken(
            c.Request.Context(), parts[1])
        if err != nil {
            c.AbortWithStatusJSON(http.StatusUnauthorized,
                gin.H{"error": "invalid token"})
            return
        }

        // コンテキストにユーザー情報を設定
        c.Set("uid", token.UID)
        c.Set("email", token.Claims["email"])
        c.Next()
    }
}
```

### 5.2 入力バリデーション

```go
// 全 API エンドポイントで binding タグによるバリデーション
type CreateEventRequest struct {
    Title       string `json:"title" binding:"required,min=1,max=200"`
    Description string `json:"description" binding:"max=2000"`
    StartDate   string `json:"start_date" binding:"required,datetime=2006-01-02T15:04:05Z07:00"`
    EndDate     string `json:"end_date" binding:"required,datetime=2006-01-02T15:04:05Z07:00,gtfield=StartDate"`
    Location    string `json:"location" binding:"max=500"`
    OrgID       uint   `json:"org_id" binding:"required,gt=0"`
}

// SQL インジェクション防御: GORM のパラメータバインディングを必須化
// NG: db.Where("name = '" + name + "'")
// OK: db.Where("name = ?", name)
```

### 5.3 RBAC（ロールベースアクセス制御）

```go
// middleware/rbac.go
func RequireOrgRole(roles ...string) gin.HandlerFunc {
    return func(c *gin.Context) {
        uid := c.GetString("uid")
        orgID := c.Param("org_id")

        var orgUser models.OrgUser
        if err := db.Where("user_uid = ? AND organization_id = ?",
            uid, orgID).First(&orgUser).Error; err != nil {
            c.AbortWithStatusJSON(http.StatusForbidden,
                gin.H{"error": "not a member of this organization"})
            return
        }

        roleAllowed := false
        for _, role := range roles {
            if orgUser.OrgRole == role {
                roleAllowed = true
                break
            }
        }

        if !roleAllowed {
            c.AbortWithStatusJSON(http.StatusForbidden,
                gin.H{"error": "insufficient permissions"})
            return
        }

        c.Set("org_role", orgUser.OrgRole)
        c.Next()
    }
}
```

---

## 6. Layer 5: データセキュリティ

### 6.1 暗号化

| レイヤー | 方式 | 実装 |
|---|---|---|
| 通信中 (in transit) | TLS 1.2/1.3 | Cloudflare + nginx + MySQL TLS接続 |
| 保存時 (at rest) | AES-256 | MySQL: InnoDB tablespace encryption |
| アプリケーション | bcrypt / SHA-256 | パスワード: bcrypt, 連絡先ハッシュ: SHA-256 |
| バックアップ | AES-256 | mysqldump → gpg 暗号化 → S3 |

### 6.2 MySQL 暗号化設定

```sql
-- InnoDB テーブルスペース暗号化を有効化
-- my.cnf
[mysqld]
early-plugin-load=keyring_file.so
keyring_file_data=/var/lib/mysql-keyring/keyring
innodb_encrypt_tables=ON
innodb_encrypt_log=ON

-- テーブル作成時に暗号化を指定
CREATE TABLE users (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    ...
) ENGINE=InnoDB ENCRYPTION='Y';
```

### 6.3 MySQL TLS 接続

```yaml
# docker-compose.yml
mysql:
  command: >
    --require-secure-transport=ON
    --ssl-ca=/etc/mysql/ssl/ca.pem
    --ssl-cert=/etc/mysql/ssl/server-cert.pem
    --ssl-key=/etc/mysql/ssl/server-key.pem
```

```go
// Go 接続文字列
dsn := "user:pass@tcp(mysql:3306)/recerdo?tls=true&parseTime=true"
```

### 6.4 機密データの取り扱い

| データ種別 | 保存方法 | アクセス制御 |
|---|---|---|
| パスワード | bcrypt (cost=12) ハッシュ | 平文保存禁止 |
| メールアドレス | 平文（検索用） | 本人 + 組織管理者のみ |
| 電話番号 | AES-256 暗号化 | 本人のみ |
| 連絡先ハッシュ | SHA-256 + SALT | フレンド提案処理のみ |
| Firebase トークン | 環境変数 | アプリケーション内部のみ |
| AWS クレデンシャル | 環境変数 or IAM Role | デプロイ環境のみ |

---

## 7. バックアップ & リカバリ

### 7.1 PoC/Beta バックアップ戦略

| 対象 | 方式 | 頻度 | 保持期間 | 保存先 |
|---|---|---|---|---|
| MySQL | mysqldump + gzip + gpg | 日次 | 30日 | S3 (別リージョン) |
| Redis | RDB スナップショット | 6時間毎 | 7日 | VPS ローカル |
| アプリ設定 | Git リポジトリ | コミット毎 | 無期限 | GitHub |
| S3 メディア | S3 バージョニング | 自動 | 30日 | S3 |

### 7.2 バックアップスクリプト

```bash
#!/bin/bash
# /opt/recerdo/scripts/backup-db.sh
set -euo pipefail

BACKUP_DIR="/tmp/backup"
S3_BUCKET="s3://recerdo-backups"
DATE=$(date +%Y%m%d_%H%M%S)
GPG_RECIPIENT="backup@recerdo.app"

mkdir -p "$BACKUP_DIR"

# MySQL ダンプ
docker exec recerdo-mysql mysqldump \
  --single-transaction \
  --routines \
  --triggers \
  --all-databases \
  | gzip \
  | gpg --encrypt --recipient "$GPG_RECIPIENT" \
  > "$BACKUP_DIR/mysql_${DATE}.sql.gz.gpg"

# S3 アップロード
aws s3 cp "$BACKUP_DIR/mysql_${DATE}.sql.gz.gpg" \
  "$S3_BUCKET/mysql/" \
  --storage-class STANDARD_IA

# 古いバックアップ削除（ローカル）
find "$BACKUP_DIR" -name "*.gpg" -mtime +7 -delete

echo "Backup completed: mysql_${DATE}.sql.gz.gpg"
```

### 7.3 RPO / RTO

| 指標 | PoC/Beta | Production (目標) |
|---|---|---|
| RPO (Recovery Point Objective) | 24時間 | 1時間 |
| RTO (Recovery Time Objective) | 4時間 | 30分 |

---

## 8. セキュリティ運用

### 8.1 PoC/Beta で実施するセキュリティタスク

| タスク | 頻度 | 担当 |
|---|---|---|
| OS セキュリティパッチ適用 | 週次 | `unattended-upgrades` 自動 |
| Docker イメージ更新 | 月次 | 手動 + Dependabot |
| 依存パッケージ脆弱性スキャン | CI/CD毎 | `govulncheck` + `npm audit` |
| アクセスログレビュー | 週次 | 手動 |
| SSL証明書更新 | 自動 | Let's Encrypt + certbot |
| バックアップ復元テスト | 月次 | 手動 |

### 8.2 セキュリティチェックリスト

| カテゴリ | チェック項目 | 状態 |
|---|---|---|
| ネットワーク | Cloudflare Proxy 有効 | [ ] |
| ネットワーク | ufw ファイアウォール有効 | [ ] |
| ネットワーク | SSH 鍵認証のみ | [ ] |
| ネットワーク | MySQL/Redis 外部非公開 | [ ] |
| TLS | TLS 1.2+ 強制 | [ ] |
| TLS | HSTS ヘッダー設定 | [ ] |
| 認証 | Firebase Auth JWT 検証 | [ ] |
| 認証 | ログイン Rate Limiting | [ ] |
| データ | MySQL at-rest 暗号化 | [ ] |
| データ | バックアップ暗号化 | [ ] |
| データ | 環境変数で機密管理 | [ ] |
| Docker | internal ネットワーク分離 | [ ] |
| Docker | non-root ユーザー実行 | [ ] |
| 監視 | fail2ban 有効 | [ ] |
| 監視 | 異常アクセスアラート | [ ] |

---

## 9. PoC → Production セキュリティ強化パス

| フェーズ | 追加するセキュリティ | コスト |
|---|---|---|
| PoC/Beta (現在) | Cloudflare Free + ufw + nginx + Firebase Auth | $0 |
| Growth | Cloudflare Pro ($20/月) + AWS WAF ($30/月) | $50/月 |
| Production | AWS Shield Advanced + WAF + GuardDuty + Secrets Manager | $3,000+/月 |

!!! warning "PoC/Beta のセキュリティ限界"
    Cloudflare Free の WAF は 5 ルールまで。高度な攻撃パターン（SQLi/XSS の詳細検知）には対応できないため、Growth フェーズで Cloudflare Pro または AWS WAF への移行が必要。

---

## 10. コンプライアンス考慮

### 10.1 PoC/Beta で最低限必要な対応

| 要件 | 対応 |
|---|---|
| 個人情報保護法（日本） | プライバシーポリシー掲載 + データ利用目的明示 |
| GDPR（EU ユーザー対象時） | 同意取得 + データ削除リクエスト対応（手動） |
| SSL/TLS 必須 | Cloudflare + Let's Encrypt で対応済み |
| パスワード安全保管 | bcrypt ハッシュ化 |

### 10.2 Production で追加必要な対応

| 要件 | 対応 |
|---|---|
| GDPR 自動データ削除 | 削除カスケード仕様（設計済み）の実装 |
| データポータビリティ | ユーザーデータエクスポート API |
| Cookie同意 | Cookie Banner + 同意管理 |
| インシデント対応 | 72時間以内通知プロセス |
| DPO (データ保護責任者) | 指名（ユーザー数に応じて） |
