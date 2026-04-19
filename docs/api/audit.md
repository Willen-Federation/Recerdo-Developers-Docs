# Audit API

`recerdo-audit` が提供する監査ログ管理APIです。

!!! warning "管理者専用"
    このAPIは管理者ロール (`ROLE_ADMIN`) を持つユーザーのみアクセス可能です。

---

## 監査ログ検索

### POST `/admin/audit/query`

監査ログを検索します。

=== "Request"

    ```json
    {
      "filters": {
        "actor_id": "usr_01JXXXXXXXXX",
        "action": "LOGIN",
        "resource_type": "session",
        "from": "2026-04-01T00:00:00Z",
        "to": "2026-04-14T23:59:59Z"
      },
      "sort": "desc",
      "limit": 50,
      "cursor": null
    }
    ```

=== "Response 200"

    ```json
    {
      "data": {
        "logs": [
          {
            "audit_id": "aud_01JXXXXXXXXX",
            "actor_id": "usr_01JXXXXXXXXX",
            "action": "LOGIN",
            "resource_type": "session",
            "resource_id": "ses_01JXXXXXXXXX",
            "result": "success",
            "ip_address": "203.0.113.1",
            "user_agent": "RecerdoApp/1.0 iOS/18.0",
            "occurred_at": "2026-04-14T10:00:00Z"
          }
        ],
        "next_cursor": "cursor_01JXXXXXXXXX",
        "total": 1024
      }
    }
    ```

---

## 監査ログエクスポート

### POST `/admin/audit/export`

監査ログをCSV/JSONでエクスポートします。

=== "Request"

    ```json
    {
      "format": "csv",
      "filters": {
        "from": "2026-04-01T00:00:00Z",
        "to": "2026-04-14T23:59:59Z"
      }
    }
    ```

=== "Response 202"

    ```json
    {
      "data": {
        "export_id": "exp_01JXXXXXXXXX",
        "status": "processing",
        "download_url": null
      }
    }
    ```

エクスポートは非同期処理。完了後にダウンロードURLが設定されます。
メール宛に出力結果を送信できるようにもします。

---

## GDPRデータ匿名化

### POST `/gdpr/anonymize`

ユーザーデータを匿名化します（GDPR削除要求対応）。

=== "Request"

    ```json
    {
      "user_id": "usr_01JXXXXXXXXX",
      "reason": "user_deletion_request",
      "requested_by": "admin_01JXXXXXXXXX"
    }
    ```

!!! danger "不可逆操作"
    この操作は元に戻せません。監査ログ内のユーザー情報が匿名化されます。

---

## 監査アクション一覧

| アクション        | 説明                     |
| ----------------- | ------------------------ |
| `LOGIN`           | ユーザーログイン         |
| `LOGOUT`          | ユーザーログアウト       |
| `TOKEN_REFRESH`   | トークンリフレッシュ     |
| `SESSION_REVOKE`  | セッション失効           |
| `EVENT_CREATE`    | イベント作成             |
| `EVENT_INVITE`    | イベント招待             |
| `EVENT_ACTION`    | イベント関連のアクション |
| `EVENT_ACTIVATE`  | イベントアクティブ化     |
| `EVENT_ARCHIVE`   | イベントアーカイブ化     |
| `COMMENT_CREATE`  | イベント作成             |
| `COMMENT_DELETE`  | コメント削除             |
| `REACTION_CREATE` | リアクション作成         |
| `REACTION_DELETE` | リアクション削除         |
| `ALBUM_CREATE`    | アルバム作成             |
| `ALBUM_ACTION`    | アルバム関連のアクション |
| `MEDIA_UPLOAD`    | メディアアップロード     |
| `MEDIA_DELETE`    | メディア削除             |
| `MEMBER_INVITE`   | メンバー招待             |
| `GDPR_ANONYMIZE`  | GDPRデータ匿名化         |
| `ADMIN_ACTION`    | 管理者操作               |

---

## ヘルスチェック

### GET `/health`
サービスのヘルスチェック（認証不要）。

### GET `/metrics`
Prometheusメトリクスエンドポイント（認証不要、内部ネットワーク限定）。

---

## 長期保管（オブジェクトストレージアーカイブ）

監査ログは 90日経過後、オブジェクトストレージへアーカイブされます（Beta: Garage / 本番: OCI Object Storage / Archive Storage）。保持期間は 7年間（GDPR / 法令要件）。

| フェーズ | 保管場所 | 期間 |
| --- | --- | --- |
| ホット | MySQL（MariaDB互換） | 0〜90日 |
| ウォーム | オブジェクトストレージ 標準クラス（JSONL 日次パーティション） | 90日〜2年 |
| コールド | Beta: Garage コールドバケット / 本番: OCI Archive Storage | 2〜7年 |
| パージ | 物理削除 | 7年経過後 |

---

最終更新: 2026-04-19 ポリシー適用
