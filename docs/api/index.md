# API リファレンス

Recerdoのバックエンドが公開するREST APIの一覧と共通仕様をまとめます。  
全APIは `API Gateway (recuerdo-api-gateway)` を経由し、JWT (RS256) による認可が適用されます。

## ベースURL

```
https://api.recerdo.app/v1
```

| 環境 | URL |
|-----|-----|
| 本番 | `https://api.recerdo.app/v1` |
| ステージング | `https://api.staging.recerdo.app/v1` |
| 開発 | `http://localhost:8080/v1` |

---

## 認証

全エンドポイント（`/health`, `/.well-known/jwks.json` を除く）にJWT Bearer認証が必要です。

```http
Authorization: Bearer <access_token>
```

- トークンはログイン時に `POST /api/auth/login` で取得
- 有効期限は15分（Access Token）/ 7日（Refresh Token）
- 期限切れ時は `POST /api/auth/refresh` で更新

---

## 共通レスポンス形式

```json
{
  "data": { ... },
  "meta": {
    "request_id": "req_01JXXXXXXXXX",
    "timestamp": "2026-04-14T00:00:00Z"
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

| サービス | パスプレフィックス | 主な機能 |
|---------|----------------|---------|
| [Authentication](auth.md) | `/api/auth/` | ログイン・トークン・セッション |
| [Events](events.md) | `/api/orgs/{org_id}/events/` | イベント・招待・参加者 |
| [Album](album.md) | `/api/orgs/{org_id}/albums/` | アルバム・写真 |
| [Storage](storage.md) | `/api/media/` | メディアアップロード・配信 |
| [Timeline](timeline.md) | `/api/users/`, `/api/orgs/` | タイムライン・フィード |
| [Audit (Admin)](audit.md) | `/admin/audit/` | 監査ログ（管理者専用） |

---

## HTTPステータスコード

| コード | 意味 | 典型的なシナリオ |
|-------|------|---------------|
| `200` | OK | 取得成功 |
| `201` | Created | 作成成功 |
| `204` | No Content | 削除成功 |
| `400` | Bad Request | バリデーションエラー |
| `401` | Unauthorized | トークン未設定・期限切れ |
| `403` | Forbidden | 権限不足 |
| `404` | Not Found | リソース未存在 |
| `409` | Conflict | 重複登録 |
| `422` | Unprocessable Entity | ビジネスルール違反 |
| `429` | Too Many Requests | レート制限超過 |
| `500` | Internal Server Error | サーバーエラー |
