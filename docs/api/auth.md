# Authentication API

`recuerdo-auth-svc` が提供する認証・セッション管理APIです。

---

## POST `/api/auth/login`

ユーザーログイン。電話番号・パスワードで認証し、JWT Access/Refresh Tokenを返します。

**認証不要**

=== "Request"

    ```http
    POST /api/auth/login
    Content-Type: application/json
    ```

    ```json
    {
      "phone_number": "+81-90-1234-5678",
      "password": "SecurePass123!",
      "device_id": "device_01JXXXXXXXXX",
      "device_name": "iPhone 16 Pro",
      "device_type": "ios"
    }
    ```

=== "Response 200"

    ```json
    {
      "data": {
        "access_token": "eyJhbGci...",
        "refresh_token": "eyJhbGci...",
        "token_type": "Bearer",
        "expires_in": 900,
        "user_id": "usr_01JXXXXXXXXX",
        "session_id": "ses_01JXXXXXXXXX"
      }
    }
    ```

=== "Response 401"

    ```json
    {
      "error": {
        "code": "INVALID_CREDENTIALS",
        "message": "電話番号またはパスワードが正しくありません"
      }
    }
    ```

---

## POST `/api/auth/refresh`

Access Tokenをリフレッシュします。

**認証不要（Refresh Token使用）**

=== "Request"

    ```json
    {
      "refresh_token": "eyJhbGci..."
    }
    ```

=== "Response 200"

    ```json
    {
      "data": {
        "access_token": "eyJhbGci...",
        "expires_in": 900
      }
    }
    ```

---

## POST `/api/auth/logout`

現在のセッションをログアウトします。

**JWT認証必須**

=== "Request"

    ```http
    POST /api/auth/logout
    Authorization: Bearer <access_token>
    ```

=== "Response 204"

    ```
    (empty body)
    ```

---

## GET `/api/auth/sessions`

現在ユーザーのアクティブセッション一覧を取得します。

=== "Response 200"

    ```json
    {
      "data": {
        "sessions": [
          {
            "session_id": "ses_01JXXXXXXXXX",
            "device_id": "device_01JXXXXXXXXX",
            "device_name": "iPhone 16 Pro",
            "device_type": "ios",
            "created_at": "2026-04-14T00:00:00Z",
            "last_used_at": "2026-04-14T10:00:00Z"
          }
        ]
      }
    }
    ```

---

## DELETE `/api/auth/sessions/{session_id}`

指定セッションを失効させます。

| パラメータ | 説明 |
|---------|------|
| `session_id` | セッションID |

---

## POST `/api/auth/devices/{device_id}/archive`

デバイスをアーカイブ（登録解除）します。

---

## GET `/.well-known/jwks.json`

公開鍵（JWKS）を返します。API GatewayがJWT検証に使用します。

**認証不要**

=== "Response 200"

    ```json
    {
      "keys": [
        {
          "kty": "RSA",
          "use": "sig",
          "kid": "key_01JXXXXXXXXX",
          "alg": "RS256",
          "n": "...",
          "e": "AQAB"
        }
      ]
    }
    ```
