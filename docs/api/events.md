# Events API

`recerdo-events` が提供するイベント・招待・参加者管理APIです。

---

## イベント管理

### POST `/api/orgs/{org_id}/events`

新規イベントを作成します。

=== "Request"

    ```json
    {
      "title": "2026年 同窓会",
      "description": "10年ぶりの再会イベント",
      "start_at": "2026-07-01T12:00:00Z",
      "end_at": "2026-07-01T18:00:00Z",
      "location_name": "渋谷区文化センター",
      "location_geo": [35.65576342201527, 139.70006821534054]
    }
    ```

=== "Response 201"

    ```json
    {
      "data": {
        "event_id": "evt_01JXXXXXXXXX",
        "org_id": "org_01JXXXXXXXXX",
        "title": "2026年 同窓会",
        "status": "draft",
        "created_at": "2026-04-19T00:00:00Z"
      }
    }
    ```

---

### GET `/api/orgs/{org_id}/events`

組織のイベント一覧を取得します。

**クエリパラメータ**

| パラメータ | 型     | 説明                            |
| ---------- | ------ | ------------------------------- |
| `status`   | string | `draft` / `active` / `archived` |
| `limit`    | int    | 取得件数（デフォルト20）        |
| `cursor`   | string | ページネーションカーソル        |

---

### GET `/api/orgs/{org_id}/events/{event_id}`

イベント詳細を取得します。

---

### PUT `/api/orgs/{org_id}/events/{event_id}`

イベント情報を更新します。
更新する内容のみをリクエストに含めます。

=== "Request"

    ```json
    {
      "title": "2026年 同窓会",
      "description": "10年ぶりの再会イベント",
      "start_at": "2026-07-01T12:00:00Z",
      "end_at": "2026-07-01T18:00:00Z",
      "location_name": "渋谷区文化センター",
      "location_geo": [35.65576342201527, 139.70006821534054]
    }
    ```

---

### POST `/api/orgs/{org_id}/events/{event_id}/activate`

イベントをアクティブ化します。アクティブ化時に招待通知が送信されます。

**通知仕様**:

| 項目 | 内容 |
| --- | --- |
| 送信基盤 | Notification Service 経由（Port/Adapter で抽象化） |
| プッシュ | FCM（iOS/Android） |
| メール | Postfix + Dovecot + Rspamd（CoreServerV2 CORE+X ホスト） |
| Webhook | Core サービス連携（オプション、署名付き） |
| テンプレート | `EventInvitation.v1`（`title` / `invite_url` / `host_name` / `starts_at` を差し込み）。HTML + プレーンテキスト両方生成 |
| 開封/クリック計測 | Notification Service が集約し、`EVENT_INVITE` として audit-svc に記録 |

---

### POST `/api/orgs/{org_id}/events/{event_id}/archive`

イベントをアーカイブします。

**アーカイブポリシー**:

1. **論理アーカイブ**: `archived_at` タイムスタンプ付与。イベントは読み取り専用モード（編集・新規コメント/リアクション/メディア追加不可、閲覧・ダウンロードは可）。
2. **2年間アクティブ保持**: イベント関連データ（メディア・コメント・招待）は通常のオブジェクトストレージに保持。
3. **2年経過後、コールド階層へ移動**:
    - **Beta**: Garage のコールドバケット（低頻度アクセスクラス）
    - **本番**: OCI Archive Storage（取り出し数時間）
4. **7年経過後、ハードデリート**（GDPR／法的保存期間考慮）。メディア原本・派生ファイル・DBレコードを物理削除。
5. 各フェーズ移行は asynq（Beta）/ OCI Queue（本番）のスケジュールジョブが担当。`EVENT_ARCHIVE` / `EVENT_COLD_TIER` / `EVENT_PURGED` を audit-svc に記録。

---

## 招待管理

### POST `/api/orgs/{org_id}/events/{event_id}/invitations`

メンバーをイベントに招待します。

**招待コード仕様**:

- **Slug**: 8文字の大小文字区別なし英数字（例: `K3F9A2HQ`）。URL安全、読み上げ可能文字のみ（`0/O`、`1/I` などの紛らわしい文字は除外）
- **QRコード**: 招待URLをエンコード（オプション生成）
- **招待トークン**: JWT（HS256、サーバー署名）。有効期限1時間、ワンタイム（使用時に無効化）
- **再発行**: `POST /api/invitations/{invitation_id}/reissue` で即時再発行可能（旧トークンは無効化）
- **通知経路**: Notification Service 経由で FCM プッシュ + Postfix SMTP メール

=== "Request"

    ```json
    {
      "email": "friend@example.com",
      "phone_number": "+819012345678",
      "uuid": "usr_01JXXXXXXXXX",
      "message": "ぜひ参加してください！"
    }
    ```

    > `email` / `phone_number` / `uuid` のいずれか1つが必須

=== "Response 201"

    ```json
    {
      "data": {
        "invitation_id": "inv_01JXXXXXXXXX",
        "slug": "K3F9A2HQ",
        "invite_url": "https://recerdo.app/i/K3F9A2HQ",
        "qr_png_url": "https://object.recerdo.app/qr/K3F9A2HQ.png",
        "token_expires_at": "2026-04-19T01:00:00Z"
      }
    }
    ```

---

### GET `/api/orgs/{org_id}/events/{event_id}/invitations`

招待一覧を取得します。

---

### POST `/api/invitations/{invitation_id}/respond`

招待に対して参加・辞退を回答します。

=== "Request"

    ```json
    {
      "response": "accept",
      "message": "ご招待ありがとうございます！"
    }
    ```

    > `response`: `"accept"` / `"decline"`

---

### POST `/api/invitations/{invitation_id}/reissue`

有効期限切れ・紛失時の招待トークン再発行。旧トークンは即時無効化されます。

---

## 参加者管理

### GET `/api/orgs/{org_id}/events/{event_id}/participants`

イベント参加者一覧を取得します。

=== "Response 200"

    ```json
    {
      "data": {
        "participants": [
          {
            "user_id": "usr_01JXXXXXXXXX",
            "display_name": "田中 花子",
            "status": "accepted",
            "joined_at": "2026-04-19T00:00:00Z"
          }
        ],
        "total": 42
      }
    }
    ```

---

## コメント

**ポリシー**:

- **論理削除**: `deleted_at` + `deleted_reason` を記録。一覧/詳細 API からは除外
- **削除権限**: 投稿者本人 / イベントオーナー / 組織管理者
- **編集履歴**: 投稿後 15分以内は編集可能。編集内容は `comment_edits` テーブルに履歴保存（監査可能）
- **メディア添付**: Storage Service の `media_id` を配列で紐付け（最大4件）
- **メンション**: `@user_id` 形式。Notification Service に `USER_MENTIONED` を発火
- **対象**: `action_destination ∈ {meta, comment, media}`（meta=イベント本体 / comment=コメントへの返信 / media=メディアへのコメント）

### POST `/api/orgs/{org_id}/events/{event_id}/{action_destination}/{action_id}/comments`

コメントを投稿します。

=== "Request"

    ```json
    {
      "body": "楽しみにしています！ @usr_01JXXXXXXXXX",
      "media_ids": ["med_01JXXXXXXXXX"],
      "mentions": ["usr_01JXXXXXXXXX"]
    }
    ```

### GET `/api/orgs/{org_id}/events/{event_id}/{action_destination}/{action_id}/comments/{comment_id}`

コメント詳細を取得します。

### PATCH `/api/orgs/{org_id}/events/{event_id}/{action_destination}/{action_id}/comments/{comment_id}`

コメントを編集します（投稿後15分以内）。

### DELETE `/api/orgs/{org_id}/events/{event_id}/{action_destination}/{action_id}/comments/{comment_id}`

コメントを論理削除します。

=== "Request"

    ```json
    {
      "reason": "user_withdraw"
    }
    ```

---

## リアクション

**ポリシー**:

- **事前定義絵文字**: MVP は 6種類固定 `{❤️, 😂, 🎉, 😢, 👏, 🔥}`。カスタム絵文字・スタンプは現フェーズ対象外
- **制約**: 1ユーザー × 1対象 = 1リアクション（種類変更は上書き）
- **カウンタ**: Redis INCR（`reactions:count:{target}:{emoji}`）で即時集計。永続化は MySQL（MariaDB互換）に非同期書き戻し
- **Timeline 連携**: リアクション発火時に `reaction_added` を Timeline Service にファンアウト
- **対象**: `action_destination ∈ {meta, comment, message, media}`

### POST `/api/orgs/{org_id}/events/{event_id}/reactions/{action_destination}`

リアクションを追加または変更します。

=== "Request"

    ```json
    {
      "action_id": "med_01JXXXXXXXXX",
      "emoji": "❤️"
    }
    ```

=== "Response 201"

    ```json
    {
      "data": {
        "reaction_id": "rxn_01JXXXXXXXXX",
        "emoji": "❤️",
        "counts": { "❤️": 12, "😂": 3, "🎉": 5, "😢": 0, "👏": 2, "🔥": 1 }
      }
    }
    ```

### DELETE `/api/orgs/{org_id}/events/{event_id}/reactions/{action_destination}/{reaction_id}`

リアクションを削除します。

---

最終更新: 2026-04-19 ポリシー適用
