# Storage API

`recerdo-storage` が提供するメディアアップロード・配信APIです。

## パイプライン概要

```
Client ──(multipart/form-data)──▶ Storage Svc
                                     │
                                     ├─▶ オブジェクトストレージ（Beta: Garage / 本番: OCI Object Storage）
                                     │     ※ S3互換プロトコルで統一
                                     │
                                     ├─▶ Queue（Beta: Redis+BullMQ/asynq / 本番: OCI Queue）
                                     │     └── 非同期ワーカーが以下を処理:
                                     │          ├─ 動画 → ffmpeg で HLS 変換（360p/720p/1080p, 6秒セグメント）
                                     │          ├─ HEIC → libheif で JPEG / WebP 生成
                                     │          └─ Live Photo → 画像 + HLS動画ペア（Apple `asset_identifier` で関連付け）
                                     │
                                     └─▶ MediaRecord(MySQL / MariaDB互換)
```

- 変換完了までメディアの `upload_status` は `processing` → `completed`
- 変換中でも `original_url` で原本配信可能（クライアントは `variants` が揃うまでプレースホルダー表示）
- **ハイライトは自動生成しない**。ユーザーが `media_ids[]` を指定して作成する（下記「ハイライト作成」）

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
    live_photo_pair_id=<optional_uuid>   # Live Photo の image/video を紐付ける
    asset_identifier=<optional_string>   # Apple Live Photo の asset_identifier
    ```

=== "Response 201"

    ```json
    {
      "data": {
        "media_id": "med_01JXXXXXXXXX",
        "org_id": "org_01JXXXXXXXXX",
        "original_filename": "photo.heic",
        "mime_type": "image/heic",
        "file_size_bytes": 2048000,
        "upload_status": "processing",
        "created_at": "2026-04-19T00:00:00Z"
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

全チャンクをオブジェクトストレージにマージし、非同期変換ジョブ（HLS/HEIC/Live Photo）をキューに投入します。

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
        "upload_status": "processing"
      }
    }
    ```

---

## メディア取得・管理

### GET `/api/media/{org_id}/{media_id}`

メディアを配信します。オブジェクトストレージ（Beta: Garage / 本番: OCI Object Storage）の Presigned URL を返却します。`variants` には自動変換の結果が含まれます。

=== "Response 200"

    ```json
    {
      "data": {
        "media_id": "med_01JXXXXXXXXX",
        "mime_type": "image/heic",
        "upload_status": "completed",
        "original_url": "https://object.recerdo.app/media/org_01.../med_01...?sig=...",
        "expires_in": 3600,
        "variants": {
          "image_url": "https://object.recerdo.app/media/.../med_01.jpg?sig=...",
          "image_webp_url": "https://object.recerdo.app/media/.../med_01.webp?sig=...",
          "hls_master_url": "https://object.recerdo.app/media/.../med_01/master.m3u8?sig=...",
          "live_photo_video_url": "https://object.recerdo.app/media/.../med_01-live.m3u8?sig=...",
          "asset_identifier": "3F9A..."
        }
      }
    }
    ```

`variants` フィールド仕様:

| フィールド | 型 | 説明 |
| --- | --- | --- |
| `image_url` | string | 互換JPEG（HEIC から生成）または原本画像のPresigned URL |
| `image_webp_url` | string | WebP 派生（libheif + cwebp） |
| `hls_master_url` | string | 動画の HLS マスタープレイリスト（360p/720p/1080p, 6秒セグメント） |
| `live_photo_video_url` | string | Live Photo のコンパニオン動画 HLS |
| `asset_identifier` | string | Apple Live Photo の `asset_identifier`（画像と動画のペア識別子） |

---

### GET `/api/media/{org_id}/{media_id}/metadata`

メディアのメタデータ（撮影日時・EXIF・変換ジョブ状態）を取得します。

---

### DELETE `/api/media/{org_id}/{media_id}`

メディアを削除します（管理者・アップロード者のみ）。

**削除ポリシー（論理削除 + 30日保持）**:

1. リクエスト時点で `deleted_at` を記録し、以後クライアントから不可視化（ソフトデリート）。
2. 30日間の復元猶予期間を設け、同一ユーザー/管理者は `POST /api/media/{org_id}/{media_id}/restore` で復元可能。
3. 30日経過後、バッチジョブ（Beta: asynq / 本番: OCI Queue ワーカー）が以下を物理削除:
    - 原本オブジェクト
    - 全ての派生ファイル（HLSセグメント・マニフェスト、JPEG/WebP、Live Photo コンパニオン動画）
    - MediaRecord
4. 監査ログ（audit-svc）に `MEDIA_DELETE` を常に記録。GDPR削除要求時は `/gdpr/anonymize` と連動し、30日を待たず即時物理削除を行う。

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

## ハイライト作成

ハイライト動画は **ユーザーが選択したメディア** から生成します。**自動生成APIは提供しません**。

### POST `/api/media/{org_id}/highlights`

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
    | `title` | ✓ | ハイライトタイトル |
    | `media_ids[]` | ✓ | ユーザーが選択したメディアIDの配列（1〜30件） |
    | `transition` | – | `cut` / `crossfade` / `fade`（既定 `cut`） |
    | `music_track_id` | – | BGMトラックID（オプション） |

=== "Response 202"

    ```json
    {
      "data": {
        "highlight_id": "hlt_01JXXXXXXXXX",
        "status": "processing",
        "estimated_duration_sec": 42
      }
    }
    ```

生成は非同期。完了後 `GET /api/media/{org_id}/highlights/{highlight_id}` で HLS の `variants` を取得できます。

!!! note "自動ハイライトは提供しません"
    アルゴリズムによる自動選定・自動ダイジェスト生成は意図的にスコープ外です。ユーザーの明示的な選択を必須とします。

---

## イベント（キュー連携）

Storage Service は以下のイベントをキュー（Beta: Redis+BullMQ / 本番: OCI Queue）に発行します。

| イベント              | トリガー                   | ペイロード                                                    |
| --------------------- | -------------------------- | ------------------------------------------------------------- |
| `MediaUploaded`       | POST single / merge 成功時 | media_id, org_id, uploader_id, filename, mime_type, file_size |
| `MediaTranscoded`     | HLS/HEIC 変換完了時        | media_id, variants                                            |
| `LivePhotoPaired`     | Live Photo ペアリング完了  | media_id, asset_identifier, paired_media_id                   |
| `MediaDeleted`        | 論理削除時                 | media_id, org_id, uploader_id, deleted_at                     |
| `MediaPurged`         | 30日経過後の物理削除時     | media_id, org_id                                              |
| `HighlightGenerated`  | ハイライト生成完了時       | highlight_id, media_ids, hls_master_url                       |

---

最終更新: 2026-04-19 ポリシー適用
