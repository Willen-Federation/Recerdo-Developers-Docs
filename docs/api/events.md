# Events API

`recuerdo-events-svc` が提供するイベント・招待・参加者管理APIです。

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
      "location": "渋谷区文化センター"
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
        "created_at": "2026-04-14T00:00:00Z"
      }
    }
    ```

---

### GET `/api/orgs/{org_id}/events`

組織のイベント一覧を取得します。

**クエリパラメータ**

| パラメータ | 型 | 説明 |
|---------|---|------|
| `status` | string | `draft` / `active` / `archived` |
| `limit` | int | 取得件数（デフォルト20） |
| `cursor` | string | ページネーションカーソル |

---

### GET `/api/orgs/{org_id}/events/{event_id}`

イベント詳細を取得します。

---

### PUT `/api/orgs/{org_id}/events/{event_id}`

イベント情報を更新します。

---

### POST `/api/orgs/{org_id}/events/{event_id}/activate`

イベントをアクティブ化します。招待メールが送信されます。

---

### POST `/api/orgs/{org_id}/events/{event_id}/archive`

イベントをアーカイブします。

---

## 招待管理

### POST `/api/orgs/{org_id}/events/{event_id}/invitations`

メンバーをイベントに招待します。

=== "Request"

    ```json
    {
      "email": "friend@example.com",
      "message": "ぜひ参加してください！"
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
      "response": "accept"
    }
    ```

    > `response`: `"accept"` / `"decline"`

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
            "joined_at": "2026-04-14T00:00:00Z"
          }
        ],
        "total": 42
      }
    }
    ```

---

## リアクション

### POST `/api/orgs/{org_id}/events/{event_id}/reactions`

イベントにリアクションを追加します。

### DELETE `/api/orgs/{org_id}/events/{event_id}/reactions/{reaction_id}`

リアクションを削除します。

---

## コメント

### POST `/api/orgs/{org_id}/events/{event_id}/comments`

イベントにコメントを投稿します。

### GET `/api/orgs/{org_id}/events/{event_id}/comments`

コメント一覧を取得します。
