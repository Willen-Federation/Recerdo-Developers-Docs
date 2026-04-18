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
      "location_name": "渋谷区文化センター",
      "location_geo": [35.65576342201527, 139.70006821534054],
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
      "location_geo": [35.65576342201527, 139.70006821534054],
    }
    ```

---

### POST `/api/orgs/{org_id}/events/{event_id}/activate`

イベントをアクティブ化します。
招待通知が送信されます。

##### TODO
  - [ ] 通知サービスに接続する。
  - [ ] 通知情報やHTMLなどの表示内容・コンテンツを設定できるようにする。
    * 招待通知の方法
      * メールアドレスへのメール通知
      * アプリケーションクライアントへのプッシュ通知
      * Webhockによる通知
      * その他Coreサービスで定める連携通知方法


---

### POST `/api/orgs/{org_id}/events/{event_id}/archive`

イベントをアーカイブします。
アーカイブにすると、データを編集することができなくなります。
アクセス権限者による操作（復元・表示・ダウンロードなど）は引き続きされますが、アーカイブポリシーによってデータが処理されます。

##### TODO
  - [ ] アーカイブポリシーについては、別途検討すること。
  - [ ] アーカイブポリシーに基づいてストレージ等の処理などビジネスロジックを作成すること。

---

## 招待管理

### POST `/api/orgs/{org_id}/events/{event_id}/invitations`

メンバーをイベントに招待します。

##### TODO
  - [ ] 招待識別に利用するコードについては柔軟性を持たせる


=== "Request"

    ```json
    {
      "email": "friend@example.com",  ## Optional if other user  contact id is filled
      "phone_number": "+819012345678", ### Optional if other user  contact id is filled
      "uuid": "hsajdhiwoefhlfhlk", ## Optional if other user  contact id is filled
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
      "response": "accept",
      "message": "ご招待ありがとうございます！"
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

## コメント

##### TODO
  - [ ] データの論理削除（送信取消・管理者権限削除など）の対応項目について検討・ポリシー策定
  - [ ] APIにおける構造（送信内容やデータ）については要検討
  - [ ] コメントの対応項目について検討
      > action_destination :　[ "meta","comment","media"]

### POST `/api/orgs/{org_id}/events/{event_id}/{action_destination}/{action_id}/comments`

コメントを投稿します。

### GET `/api/orgs/{org_id}/events/{event_id}/{action_destination}/{action_id}/comments/{comment_id}`

コメント一覧を取得します。

### DELETE `/api/orgs/{org_id}/events/{event_id}/{action_destination}/{action_id}/comments/{comment_id}`

コメントを論理削除します。

---

## リアクション

##### TODO
  - [ ] 具体的なリアクション項目について検討
  - [ ] EmojiやStickerを事前用意すると思われるが、どういう設定にするかを要検討
  - [ ] APIにおける構造（送信内容やデータ）については要検討
  - [ ] リアクションの対応項目について検討
      > action_destination :　[ "meta","comment","message","media"]




### POST `/api/orgs/{org_id}/events/{event_id}/reactions/{action_destination}`

各種アクションに対してリアクションを追加します。

### DELETE `/api/orgs/{org_id}/events/{event_id}/reactions/{action_destination}/{reaction_id}`

各種アクションに対してリアクションを削除します。

---

