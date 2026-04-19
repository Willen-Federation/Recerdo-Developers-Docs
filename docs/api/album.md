# Album API

`recerdo-album` が提供するアルバム・メディア管理APIです。

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
        "created_at": "2026-04-19T00:00:00Z"
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

| パラメータ | 型     | 説明                     |
| ---------- | ------ | ------------------------ |
| `limit`    | int    | 取得件数                 |
| `cursor`   | string | ページネーションカーソル |

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

アルバムからメディアを削除します（アルバムからの除外。原本の物理削除は Storage Service の論理削除＋30日保持ポリシーに従う）。

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

アルバムのメディア一覧を取得します。Live Photo はペアリング済みの画像+動画を **1件のメディア** として返却します（UI上も1カード扱い）。

=== "Response 200"

    ```json
    {
      "data": {
        "media": [
          {
            "media_id": "med_01JXXXXXXXXX",
            "mime_type": "image/heic",
            "caption": "みんなで乾杯！",
            "uploader_id": "usr_01JXXXXXXXXX",
            "created_at": "2026-04-19T00:00:00Z",
            "variants": {
              "image_url": "https://object.recerdo.app/media/.../med_01.jpg?sig=...",
              "image_webp_url": "https://object.recerdo.app/media/.../med_01.webp?sig=...",
              "hls_master_url": null,
              "live_photo_video_url": "https://object.recerdo.app/media/.../med_01-live.m3u8?sig=...",
              "asset_identifier": "3F9A..."
            }
          }
        ],
        "total": 128
      }
    }
    ```

!!! note "Live Photo の扱い"
    Live Photo は Apple の `asset_identifier` で画像と動画をペアリングし、アルバムには **1件のメディアとして表示** します。`variants.image_url` と `variants.live_photo_video_url` の両方が返却され、対応クライアントはロングタップで動画再生、非対応クライアントは静止画のみ表示します。

---

### PATCH `/api/orgs/{org_id}/albums/{album_id}/media/{media_id}`

メディアのキャプションを更新します。

---

## ハイライト動画

!!! info "ユーザー選択方式"
    ハイライト動画は **自動生成しません**。ユーザーが `media_ids[]` を明示的に選択して作成します。

### POST `/api/orgs/{org_id}/albums/{album_id}/highlights`

アルバム内メディアから **ユーザーが選択した** メディアでハイライト動画を生成します。

=== "Request"

    ```json
    {
      "title": "2026年 同窓会ハイライト",
      "media_ids": [
        "med_01JXXXXXXXXX",
        "med_02JXXXXXXXXX",
        "med_03JXXXXXXXXX"
      ],
      "transition": "crossfade",
      "music_track_id": "trk_01JXXXXXXXXX"
    }
    ```

    | フィールド | 必須 | 説明 |
    | --- | --- | --- |
    | `media_ids[]` | ✓ | ユーザーが選択したメディアID（1〜30件）。順序はハイライト内の再生順 |
    | `title` | ✓ | ハイライトタイトル |
    | `transition` | – | `cut` / `crossfade` / `fade`（既定 `cut`） |
    | `music_track_id` | – | BGMトラックID |

=== "Response 202"

    ```json
    {
      "data": {
        "highlight_id": "hlt_01JXXXXXXXXX",
        "album_id": "alb_01JXXXXXXXXX",
        "status": "processing"
      }
    }
    ```

生成完了後、Storage Service 経由で HLS `variants` が返却されます（`GET /api/media/{org_id}/highlights/{highlight_id}`）。

---

最終更新: 2026-04-19 ポリシー適用
