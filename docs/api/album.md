# Album API

`recuerdo-album-svc` が提供するアルバム・メディア管理APIです。

---

## アルバム管理

### POST `/api/orgs/{org_id}/albums`

アルバムを新規作成します。

=== "Request"

    ```json
    {
      "title": "2026年 同窓会アルバム",
      "description": "みんなの思い出",
      "event_id": "evt_01JXXXXXXXXX",
      "visibility": "members"
    }
    ```

=== "Response 201"

    ```json
    {
      "data": {
        "album_id": "alb_01JXXXXXXXXX",
        "org_id": "org_01JXXXXXXXXX",
        "title": "2026年 同窓会アルバム",
        "media_count": 0,
        "created_at": "2026-04-14T00:00:00Z"
      }
    }
    ```

---

### GET `/api/orgs/{org_id}/albums/{album_id}`

アルバム詳細を取得します。

---

### GET `/api/orgs/{org_id}/events/{event_id}/album`

イベントに紐づくアルバムを取得します。

---

### GET `/api/orgs/{org_id}/albums`

組織のアルバム一覧を取得します。

**クエリパラメータ**

| パラメータ | 型 | 説明 |
|---------|---|------|
| `limit` | int | 取得件数 |
| `cursor` | string | ページネーションカーソル |

---

### PATCH `/api/orgs/{org_id}/albums/{album_id}`

アルバムのメタデータを更新します（タイトル・説明など）。

---

## メディア管理

### POST `/api/orgs/{org_id}/albums/{album_id}/media`

アルバムにメディアを追加します（Storage Serviceでアップロード後のmedia_idを指定）。

=== "Request"

    ```json
    {
      "media_id": "med_01JXXXXXXXXX",
      "caption": "みんなで乾杯！"
    }
    ```

---

### DELETE `/api/orgs/{org_id}/albums/{album_id}/media/{media_id}`

アルバムからメディアを削除します。

---

### POST `/api/orgs/{org_id}/albums/{album_id}/media/reorder`

アルバム内のメディア順序を並び替えます。

=== "Request"

    ```json
    {
      "media_ids": [
        "med_01JXXXXXXXXX",
        "med_02JXXXXXXXXX",
        "med_03JXXXXXXXXX"
      ]
    }
    ```

---

### GET `/api/orgs/{org_id}/albums/{album_id}/media`

アルバムのメディア一覧を取得します。

=== "Response 200"

    ```json
    {
      "data": {
        "media": [
          {
            "media_id": "med_01JXXXXXXXXX",
            "url": "https://media.recerdo.app/...",
            "thumbnail_url": "https://media.recerdo.app/.../thumb",
            "caption": "みんなで乾杯！",
            "uploader_id": "usr_01JXXXXXXXXX",
            "created_at": "2026-04-14T00:00:00Z"
          }
        ],
        "total": 128
      }
    }
    ```

---

### PATCH `/api/orgs/{org_id}/albums/{album_id}/media/{media_id}`

メディアのキャプションを更新します。
