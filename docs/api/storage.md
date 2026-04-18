# Storage API

`recuerdo-storage-svc` が提供するメディアアップロード・配信APIです。

---

## 通常アップロード

### POST `/api/media/{org_id}/single`

単一ファイルをアップロードします（`multipart/form-data`）。

=== "Request"

    ```http
    POST /api/media/org_01JXXXXXXXXX/single
    Content-Type: multipart/form-data
    Authorization: Bearer <token>

    file=<binary>
    ```

=== "Response 201"

    ```json
    {
      "data": {
        "media_id": "med_01JXXXXXXXXX",
        "org_id": "org_01JXXXXXXXXX",
        "original_filename": "photo.jpg",
        "mime_type": "image/jpeg",
        "file_size_bytes": 2048000,
        "upload_status": "completed",
        "created_at": "2026-04-14T00:00:00Z"
      }
    }
    ```

---

## チャンクアップロード（大容量ファイル）

大容量ファイル（動画など）は3ステップのチャンクアップロードを使用します。

### Step 1: POST `/api/media/{org_id}/upload`

アップロードを初期化します。

=== "Request"

    ```json
    {
      "filename": "event_video.mp4",
      "mime_type": "video/mp4",
      "file_size_bytes": 104857600,
      "chunk_size_bytes": 10485760
    }
    ```

=== "Response 201"

    ```json
    {
      "data": {
        "upload_id": "upl_01JXXXXXXXXX",
        "total_chunks": 10,
        "chunk_size_bytes": 10485760
      }
    }
    ```

---

### Step 2: PUT `/api/media/{org_id}/upload/{upload_id}/{chunk_index}`

各チャンクをアップロードします。

```http
PUT /api/media/org_01.../upload/upl_01.../0
Content-Type: application/octet-stream

<binary chunk data>
```

---

### Step 3: POST `/api/media/{org_id}/merge`

全チャンクをマージして完成させます。

=== "Request"

    ```json
    {
      "upload_id": "upl_01JXXXXXXXXX"
    }
    ```

=== "Response 201"

    ```json
    {
      "data": {
        "media_id": "med_01JXXXXXXXXX",
        "upload_status": "completed"
      }
    }
    ```

---

## メディア取得・管理

### GET `/api/media/{org_id}/{media_id}`

メディアを配信します（Presigned URL返却）。

=== "Response 200"

    ```json
    {
      "data": {
        "url": "https://s3.ap-northeast-1.amazonaws.com/recuerdo-media/...",
        "expires_in": 3600
      }
    }
    ```

---

### GET `/api/media/{org_id}/{media_id}/metadata`

メディアのメタデータを取得します。

---

### DELETE `/api/media/{org_id}/{media_id}`

メディアを削除します（管理者・アップロード者のみ）。
#### TODO
* データは論理削除とした上で、ビジネスポリシーに従って処理する。


---

### GET `/api/media/{org_id}`

組織のメディア一覧を取得します（ページネーション対応）。

**クエリパラメータ**

| パラメータ  | 型     | 説明                              |
| ----------- | ------ | --------------------------------- |
| `limit`     | int    | 取得件数（デフォルト20、最大100） |
| `cursor`    | string | ページネーションカーソル          |
| `mime_type` | string | フィルター（例: `image/jpeg`）    |

---

## イベント（SQSメッセージ）

Storage Serviceは以下のイベントをSQS `recuerdo-media-events` に発行します。

| イベント        | トリガー                   | ペイロード                                                    |
| --------------- | -------------------------- | ------------------------------------------------------------- |
| `MediaUploaded` | POST single / merge 成功時 | media_id, org_id, uploader_id, filename, mime_type, file_size |
| `MediaDeleted`  | DELETE 成功時              | media_id, org_id, uploader_id                                 |
