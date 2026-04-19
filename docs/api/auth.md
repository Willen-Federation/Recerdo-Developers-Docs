# Authentication API

`recerdo-auth` が提供する認証・セッション管理APIです。

### Deprecated

管理性向上を目的に、本APIは AWS Cognito へ統合移行する。
認可（Authorization）処理は権限サービス（Permission Service）で実施する。

---

## ポリシー

AWS は **Cognito のみ** 利用する方針（他AWSサービスはOSS/OCIに置き換え）。

| 領域 | 採用プロダクト | 役割 |
| --- | --- | --- |
| 認証（Authentication） | AWS Cognito User Pool | ログイン・MFA・パスワードポリシー・JWT発行 |
| 認可（Authorization） | Permission Service（内製） | ロール・組織権限・リソースACL判定 |
| トークン検証 | Cognito JWKS | JWT の署名検証（`RS256`）・`iss`/`aud`/`exp` チェック |
| セッション管理 | Cognito + Permission Service | Refresh Token ローテーション・端末単位セッション失効 |

### トークン仕様

- **Access Token**: JWT (RS256), TTL 15分, Cognito JWKS で検証
- **Refresh Token**: TTL 7日, Cognito で管理
- **ID Token**: ユーザー属性用（サブクライム `sub` = Cognito UUID）

### 代表エンドポイント

| エンドポイント | 実体 | 用途 |
| --- | --- | --- |
| `POST /api/auth/login` | Cognito InitiateAuth へプロキシ | ログイン |
| `POST /api/auth/refresh` | Cognito InitiateAuth (REFRESH_TOKEN) | アクセストークン再発行 |
| `POST /api/auth/logout` | Cognito GlobalSignOut + Permission Svc | 全端末ログアウト |
| `GET  /.well-known/jwks.json` | Cognito JWKS プロキシ | 公開鍵配布 |

### 権限判定のフロー

1. API Gateway が `Authorization: Bearer` JWT を Cognito JWKS で検証
2. `sub`（Cognito UUID）をコンテキストに注入
3. Permission Service が `(user_id, org_id, resource, action)` を評価
4. OK の場合のみ業務サービスへルーティング

---

最終更新: 2026-04-19 ポリシー適用
