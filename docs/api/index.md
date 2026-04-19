# API リファレンス

Recerdoのバックエンドが公開するREST APIの一覧と共通仕様をまとめます。  
全APIは `API Gateway (recuerdo-api-gateway)` を経由し、JWT (RS256) による認可が適用されます。

## ベースURL

| 環境         | URL                                  |
| ------------ | ------------------------------------ |
| 本番         | `https://api.recerdo.app/v1`         |
| ステージング | `https://api.staging.recerdo.app/v1` |
| 開発         | `http://localhost:8080/v1`           |

---

## 認証

全エンドポイント（`/health`, `/.well-known/jwks.json` を除く）にJWT Bearer認証が必要です。

```http
Authorization: Bearer <access_token>
```

- トークンはログイン時に AWS Cognito User Pool 経由で発行
- 有効期限は15分（Access Token）/ 7日（Refresh Token）
- 期限切れ時は `POST /api/auth/refresh` で更新
- JWT 検証は Cognito JWKS（`/.well-known/jwks.json`）で実施
- 認可（ロール・権限）は Permission Service が担当

---

## 共通レスポンス形式

```json
{
  "data": { ... },
  "meta": {
    "request_id": "req_01JXXXXXXXXX",
    "timestamp": "2026-04-19T00:00:00Z"
  }
}
```

エラー時:

```json
{
  "error": {
    "code": "UNAUTHORIZED",
    "message": "トークンが無効です",
    "request_id": "req_01JXXXXXXXXX"
  }
}
```

---

## サービス別APIマップ

| サービス                             | パスプレフィックス           | 主な機能                           |
| ------------------------------------ | ---------------------------- | ---------------------------------- |
| Deprecated [Authentication](auth.md) | `/api/auth/`                 | ログイン・トークン・セッション     |
| [Permission](permission.md)          | `/api/auth/`                 | トークン・セッション・権限関係操作 |
| [Events](events.md)                  | `/api/orgs/{org_id}/events/` | イベント・招待・参加者             |
| [Album](album.md)                    | `/api/orgs/{org_id}/albums/` | アルバム・写真                     |
| [Storage](storage.md)                | `/api/media/`                | メディアアップロード・配信         |
| [Timeline](timeline.md)              | `/api/users/`, `/api/orgs/`  | タイムライン・フィード             |
| [Audit (Admin)](audit.md)            | `/admin/audit/`              | 監査ログ（管理者専用）             |

---

## HTTPステータスコード

| コード | 意味                  | 典型的なシナリオ         |
| ------ | --------------------- | ------------------------ |
| `200`  | OK                    | 取得成功                 |
| `201`  | Created               | 作成成功                 |
| `204`  | No Content            | 削除成功                 |
| `400`  | Bad Request           | バリデーションエラー     |
| `401`  | Unauthorized          | トークン未設定・期限切れ |
| `404`  | Not Found             | リソース未存在・権限不足 |
| `409`  | Conflict              | 重複登録                 |
| `422`  | Unprocessable Entity  | ビジネスルール違反       |
| `429`  | Too Many Requests     | レート制限超過           |
| `500`  | Internal Server Error | サーバーエラー           |

---

最終更新: 2026-04-19 ポリシー適用
