# Storage Module (recerdo-storage)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoソーシャルメモリプラットフォームのメディアファイル管理を一元化する専用マイクロサービス。写真・ビデオなどの媒体をアップロード→処理→配信する完全なライフサイクルを管理し、ユーザーの思い出を安全かつ効率的に保存・共有できる基盤を提供する。単一ファイルアップロード・チャンク型大容量アップロード・自動画像変換（HEIC→JPEG/WebP, libheif）・動画 HLS 変換（FFmpeg, 360p/720p/1080p, 6秒セグメント）・Live Photo ペアリング（`com.apple.quicktime.content.identifier` キー）・ユーザー選択型ハイライト動画連結・サムネイル生成・アクセス制御・期間限定配信URLを一貫して処理し、フロントエンドに単純で使いやすいAPIを公開する。オブジェクトストレージは **Beta: Garage（S3互換 OSS、CoreServerV2 CORE+X 上）**、**本番: OCI Object Storage** を `StoragePort` 抽象化の裏側で切り替える（両者とも S3 互換 API を提供するため、`aws-sdk-go-v2/service/s3` を S3 互換クライアントとして利用）。

### ビジネスコンテキスト

解決する問題:
- ユーザーが古い友人グループとの思い出写真を安全に共有するには、ファイル保存・変換・アクセス制御が必要である（会話で特定された主要要件）
- iPhoneで撮影されたHEIC形式画像はWebブラウザで直接表示できないため、PNG変換が必須
- 数MB～数百MB規模のビデオアップロードはネットワーク不安定環境でのチャンク再試行機構が必須
- メディアアクセス権はプライベート（本人のみ）・組織メンバー・イベント参加者など複雑で、未処理の失敗ファイルにアクセスさせてはならない
- オブジェクトストレージ（Garage / OCI Object Storage）への直接アップロード・直接アクセスはセキュリティリスク（アクセス制御の迂回）のため、サービス経由の処理が必須

Key User Stories:
- モバイルアプリユーザーとして、不安定なネットワークでも写真をアップロードでき、失敗時は再開できるようにしてほしい
- バックエンド開発者として、メディアプロセッシング（変換・リサイズ・圧縮）をSTATELESSに非同期実行し、メイン処理ブロッキングなしに実施したい
- セキュリティ担当として、メディアアクセスは組織メンバーシップ・イベント参加情報を基に厳格に制御し、承認されたユーザー以外がアクセスできないようにしたい
- Product として、ユーザーは自分でアップロードしたメディアのみ削除でき、アクセス制御の誤設定でデータが露出しないようにしたい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ  | 説明                                                                                                                                  | 主要属性                                                                                                                                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MediaFile     | ユーザーがアップロードしたメディアファイルの核となるエンティティ。ステータスライフサイクル（UPLOADING→PROCESSING→READY/FAILED）を管理 | id (ULID), org_id, uploader_id, original_filename, mime_type, file_size_bytes, storage_key (オブジェクトストレージキー), status (UPLOADING/PROCESSING/READY/FAILED), access_policy (PRIVATE/ORG_MEMBERS/EVENT_MEMBERS), live_photo_pair_id (Apple Live Photos 用, nullable), media_kind (IMAGE/VIDEO/LIVE_PHOTO_IMAGE/LIVE_PHOTO_VIDEO), hls_manifest_key (動画のみ, nullable), created_at, updated_at |
| MediaChunk    | 大容量ファイルのチャンク型アップロードを管理。各チャンクはオブジェクトストレージに保存され、最後に CompleteMultipartUpload で統合     | id (ULID), media_id, chunk_index, storage_key, size_bytes, uploaded_at, expires_at (24時間後)                                                                                                                              |
| ProcessingJob | メディア処理（HLS 変換・HEIC 変換・サムネイル生成・Live Photo ペアリング）の非同期ジョブ。QueuePort 経由で実行                        | id (ULID), media_id, job_type (HLS_TRANSCODE/HEIC_CONVERT/THUMBNAIL_GEN/LIVE_PHOTO_PAIRING), status (PENDING/RUNNING/DONE/FAILED), started_at, completed_at, error_msg?, result_storage_key?                               |
| HighlightVideo | **ユーザーが明示的に選択** した複数動画を連結した1本のハイライト動画。ML による自動ハイライトは行わない。                          | id (ULID), owner_user_id, org_id?, selected_media_ids ([]ULID, 2件以上), output_storage_key, status, created_at                                                                                                            |

### 値オブジェクト

| 値オブジェクト | 説明                                                                           | バリデーションルール                                                                                                                 |
| -------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| MediaStatus    | ファイル処理状態の値オブジェクト                                               | UPLOADING（アップロード中）・PROCESSING（処理中）・READY（配信可能）・FAILED（処理失敗）のいずれか。状態遷移は定義済みの遷移図に従う |
| MimeType       | ファイルの種別を表す。アップロード時に厳格にバリデーション                     | 許可リスト: image/jpeg, image/png, image/heic, image/heif, image/webp, video/mp4, video/quicktime。拡張子とContent-Typeの両方をチェック。大文字・小文字区別しない |
| FileSize       | ファイルサイズの値オブジェクト。ファイル種別ごとに最大値を設定                 | image/*: 最大100MB、video/*: 最大2GB（Live Photo の .mov を含む）。0バイト以下は不許可                                               |
| StorageKey     | オブジェクトストレージ（Garage / OCI Object Storage）上のキー。組織ID・ファイルID・タイプで一意に決定される | 形式: `{org_id}/{media_id}/{type}` ただし type ∈ {original, optimized, thumb, hls/master.m3u8, hls/360p_XXX.ts, hls/720p_XXX.ts, hls/1080p_XXX.ts, live_photo_still, live_photo_motion}。パストラバーサル防止のため／を含む入力を拒否。Garage / OCI 双方で同一キー体系。 |
| AccessPolicy   | メディアアクセス制御ポリシー                                                   | PRIVATE（本人のみ）・ORG_MEMBERS（組織メンバー）・EVENT_MEMBERS（イベント参加者）のいずれか。デフォルトはPRIVATE                     |
| DeliveryType   | クライアントが要求する配信形式                                                 | original（元ファイル）・optimized（HEIC→JPEG/WebP 変換版）・hls（動画 HLS マニフェスト）・thumb（サムネイル最大1280px）のいずれか    |
| PresignedURL   | オブジェクトストレージ（S3互換 API）の一時的なアクセスURL。1時間の有効期限を持つ | HTTPS URL。URLには署名が含まれ、改ざん不可。有効期限切れ後は無効。Garage と OCI Object Storage の双方で S3 署名 v4 方式を使用。      |
| LivePhotoIdentifier | Apple Live Photos のペアリングに使う `com.apple.quicktime.content.identifier` 値 | HEIC 画像メタデータおよび QuickTime .mov の同値キーを抽出し、ペアリングに使用                                                   |

### ドメインルール / 不変条件

- メディアアクセス権：PRIVATE であれば本人（uploader_id）のみがアクセス可能。ORG_MEMBERS であれば org_id に属するメンバー。EVENT_MEMBERS であればそのイベント参加者のみ
- 状態遷移：MediaFile の status は UPLOADING → PROCESSING → READY または UPLOADING → FAILED のいずれか。逆遷移（READY → PROCESSING など）は禁止
- HEIC/HEIF 自動変換：mime_type が image/heic または image/heif のファイルは PROCESSING ステージで **libheif** を通じて JPEG（既定）と WebP（配信最適化）に変換される（optimized 形式で保存）
- 動画 HLS 変換：mime_type が video/mp4 または video/quicktime の場合、PROCESSING ステージで **FFmpeg** を用いて 360p / 720p / 1080p の 3 プロファイル、6 秒セグメント、H.264/AAC、独立したマスタープレイリスト（master.m3u8）付きで HLS に変換される（オリジナル解像度に応じて一部プロファイルを省略）
- Live Photo ペアリング：HEIC/JPEG（still）と .mov（motion）の組が同一 `com.apple.quicktime.content.identifier` を持つ場合、自動でペアリング。片方が欠けていたら single image / single video として扱う。ペアリングに成功したら両 MediaFile の `live_photo_pair_id` に共通 ULID を設定
- ハイライト動画はユーザー選択のみ：ハイライト動画は **ユーザーが明示的に選択した 2 件以上の動画** を FFmpeg concat で連結する。ML による自動選定・自動ハイライトは行わない
- サムネイル生成：すべてのメディア（画像・動画・HLS）は PROCESSING ステージでサムネイルを生成する。サムネイル長辺は1280px以下。動画は最初の I-frame をサンプル
- ファイル削除権：MediaFile は uploader_id またはOrg Admin のみが削除可能。組織メンバーであってもアップロード者でなければ削除不可
- FAILED状態のアクセス禁止：status が FAILED のメディアへのアクセスリクエストには必ず 404 を返す
- チャンク有効期限：MediaChunk の expires_at を超過したチャンクは削除対象。アップロード開始から24時間以内にマージが完了しないと全チャンク削除
- アップロード中の一時停止：チャンク型アップロードは最後のチャンク送信から24時間以内にマージリクエストがなければ全チャンク自動削除（ストレージ節約）

### ドメインイベント

| イベント              | トリガー                                             | 主要ペイロード                                                                                                 | 発行先                          |
| --------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| MediaUploaded         | POST /api/media/{org_id}/single または /merge 成功時 | media_id, org_id, uploader_id, original_filename, mime_type, file_size_bytes, timestamp                                             | QueuePort → Topic: `recuerdo.media.uploaded`   |
| MediaReady            | ProcessingJob が DONE になり全ジョブ（HLS/HEIC/thumb/pairing）完了時 | media_id, org_id, original_filename, storage_keys (original/optimized/hls/thumb/live_photo_*), live_photo_pair_id?, timestamp | QueuePort → Topic: `recuerdo.media.ready`      |
| MediaProcessingFailed | ProcessingJob が FAILED になった時                   | media_id, job_type, error_msg, timestamp                                                                                            | QueuePort → Topic: `recuerdo.media.failed`     |
| MediaDeleted          | DELETE /api/media/{org_id}/{media_id} 成功時         | media_id, org_id, uploader_id, timestamp                                                                                            | QueuePort → Topic: `recuerdo.media.deleted`    |
| HighlightVideoReady   | ユーザー選択の連結ジョブ完了時                        | highlight_id, owner_user_id, selected_media_ids, output_storage_key, timestamp                                                      | QueuePort → Topic: `recuerdo.highlight.ready`  |

QueuePort 実装は Beta: `RedisBullMQAdapter`（Node 相当は `BullMQ`、Go 側は `asynq`）、本番: `OCIQueueAdapter`。いずれも同一 Topic 名で運用（[キュー抽象化設計](queue-abstraction.md) 参照）。

### エンティティ定義（コードスケッチ）

```go
// MediaFile エンティティ
type MediaFile struct {
    ID               string    // ULID
    OrgID            string
    UploaderID       string
    OriginalFilename string
    MimeType         string
    FileSizeBytes    int64
    StorageKey       string    // オブジェクトストレージキー for original
    Status           string    // UPLOADING / PROCESSING / READY / FAILED
    AccessPolicy     string    // PRIVATE / ORG_MEMBERS / EVENT_MEMBERS
    CreatedAt        time.Time
    UpdatedAt        time.Time
    DeletedAt        *time.Time
}

func NewMediaFile(orgID, uploaderID, filename string, mimeType MimeType, sizeBytes int64) (*MediaFile, error) {
    if err := mimeType.Validate(); err != nil {
        return nil, ErrInvalidMimeType
    }
    if sizeBytes == 0 {
        return nil, ErrEmptyFile
    }
    if sizeBytes > mimeType.MaxBytes() {
        return nil, ErrFileTooLarge
    }
    
    return &MediaFile{
        ID:               ulid.Make().String(),
        OrgID:            orgID,
        UploaderID:       uploaderID,
        OriginalFilename: filename,
        MimeType:         mimeType.String(),
        FileSizeBytes:    sizeBytes,
        Status:           "UPLOADING",
        AccessPolicy:     "PRIVATE",
        CreatedAt:        time.Now(),
        UpdatedAt:        time.Now(),
    }, nil
}

func (m *MediaFile) TransitionTo(newStatus string) error {
    validTransitions := map[string][]string{
        "UPLOADING":  {"PROCESSING", "FAILED"},
        "PROCESSING": {"READY", "FAILED"},
        "READY":      {},
        "FAILED":     {},
    }
    
    allowed := validTransitions[m.Status]
    if !contains(allowed, newStatus) {
        return ErrInvalidStatusTransition
    }
    
    m.Status = newStatus
    m.UpdatedAt = time.Now()
    return nil
}

func (m *MediaFile) CanBeAccessedBy(userID string, orgMembers []string, eventMembers []string) bool {
    if m.Status == "FAILED" {
        return false
    }
    
    switch m.AccessPolicy {
    case "PRIVATE":
        return m.UploaderID == userID
    case "ORG_MEMBERS":
        return contains(orgMembers, userID)
    case "EVENT_MEMBERS":
        return contains(eventMembers, userID)
    default:
        return false
    }
}

func (m *MediaFile) CanBeDeletedBy(userID string) bool {
    // アップロード者またはOrg Adminのみ削除可能
    return m.UploaderID == userID
}

// MediaChunk エンティティ
type MediaChunk struct {
    ID         string
    MediaID    string
    ChunkIndex int
    StorageKey string    // オブジェクトストレージ（Garage / OCI Object Storage）のキー
    SizeBytes  int64
    UploadedAt time.Time
    ExpiresAt  time.Time
}

func NewMediaChunk(mediaID string, chunkIndex int, sizeBytes int64) *MediaChunk {
    return &MediaChunk{
        ID:         ulid.Make().String(),
        MediaID:    mediaID,
        ChunkIndex: chunkIndex,
        SizeBytes:  sizeBytes,
        UploadedAt: time.Now(),
        ExpiresAt:  time.Now().Add(24 * time.Hour),
    }
}

func (c *MediaChunk) IsExpired() bool {
    return time.Now().After(c.ExpiresAt)
}

// ProcessingJob エンティティ
type ProcessingJob struct {
    ID                 string
    MediaID            string
    JobType            string    // HLS_TRANSCODE / HEIC_CONVERT / THUMBNAIL_GEN / LIVE_PHOTO_PAIRING / HIGHLIGHT_CONCAT
    Status             string    // PENDING / RUNNING / DONE / FAILED
    StartedAt          *time.Time
    CompletedAt        *time.Time
    ErrorMsg           *string
    ResultStorageKey   *string
    CreatedAt          time.Time
}

func NewProcessingJob(mediaID, jobType string) *ProcessingJob {
    return &ProcessingJob{
        ID:        ulid.Make().String(),
        MediaID:   mediaID,
        JobType:   jobType,
        Status:    "PENDING",
        CreatedAt: time.Now(),
    }
}

func (p *ProcessingJob) StartProcessing() {
    now := time.Now()
    p.StartedAt = &now
    p.Status = "RUNNING"
}

func (p *ProcessingJob) Complete(resultStorageKey string) {
    now := time.Now()
    p.CompletedAt = &now
    p.Status = "DONE"
    p.ResultStorageKey = &resultStorageKey
}

func (p *ProcessingJob) Failed(errMsg string) {
    now := time.Now()
    p.CompletedAt = &now
    p.Status = "FAILED"
    p.ErrorMsg = &errMsg
}
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース          | 入力DTO                                                                                           | 出力DTO                                                                                                           | 説明                                                     |
| --------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| UploadMediaSingle     | UploadMediaSingleInput{org_id, uploader_id, file_content, filename, mime_type, access_policy?}    | UploadMediaSingleOutput{media_id, status, storage_key}                                                            | 100MB以下の単一ファイルアップロード。最重要ユースケース  |
| InitiateChunkedUpload | InitiateChunkedUploadInput{org_id, uploader_id, filename, mime_type, total_size_bytes}            | InitiateChunkedUploadOutput{media_id, chunk_size_bytes, total_chunks, upload_id}                                  | 大容量ファイルのチャンク型アップロード初期化             |
| UploadMediaChunk      | UploadMediaChunkInput{upload_id, chunk_index, chunk_data, chunk_hash}                             | UploadMediaChunkOutput{chunk_index, uploaded_bytes, s3_key}                                                       | 各チャンクのアップロード。再試行対応                     |
| MergeChunkedUpload    | MergeChunkedUploadInput{upload_id, media_id, total_chunks}                                        | MergeChunkedUploadOutput{media_id, status, storage_key}                                                           | 全チャンク受信後にS3で統合                               |
| DeliverMedia          | DeliverMediaInput{org_id, media_id, delivery_type (original/optimized/thumb), requesting_user_id} | DeliverMediaOutput{presigned_url, content_type, expires_at}                                                       | メディア配信。1時間有効なPresigned URLを生成             |
| GetMediaMetadata      | GetMediaMetadataInput{org_id, media_id, requesting_user_id}                                       | GetMediaMetadataOutput{media_id, filename, mime_type, size_bytes, status, access_policy, uploader_id, created_at} | メディアメタデータ取得（アクセス権チェック済み）         |
| DeleteMedia           | DeleteMediaInput{org_id, media_id, requesting_user_id}                                            | DeleteMediaOutput{success, deleted_at}                                                                            | メディア削除。アップロード者のみ可能                     |
| RetryProcessing       | RetryProcessingInput{media_id, job_type?}                                                         | RetryProcessingOutput{job_id, status}                                                                             | 失敗した処理ジョブの再実行                               |
| ListOrgMedia          | ListOrgMediaInput{org_id, requesting_user_id, limit, offset}                                      | ListOrgMediaOutput{media_list, total_count}                                                                       | 組織のメディア一覧取得。アクセス権に基づきフィルタリング |
| CleanupExpiredChunks  | CleanupExpiredChunksInput{}                                                                       | CleanupExpiredChunksOutput{deleted_count}                                                                         | 有効期限切れチャンクの自動削除（夜間バッチ）             |

### ユースケース詳細（主要ユースケース）

## UploadMediaSingle — 主要ユースケース詳細

### トリガー
iOSアプリ/WebアプリからのPOST /api/media/{org_id}/single (multipart/form-data)

### フロー
1. HTTPハンドラーがマルチパートリクエストを解析
   - ファイル取得（part "file"）
   - filename, mime_type をメタデータから取得
2. MediaFileエンティティ作成時のバリデーション:
   a. MimeType.Validate() — 許可リストに存在するか
   b. FileSize.Validate() — ファイルサイズ制限（image/*: 100MB, video/mp4: 500MB）チェック
   c. 拡張子とContent-Type の一致確認（HEIC.jpg等の詐称防止）
   - いずれか失敗 → 400 Bad Request
3. Permission Service へ org_id の所属メンバーシップ確認（gRPC）
   - 確認失敗 → 401 Unauthorized
4. MediaFile を新規作成（status="UPLOADING"）
5. MediaFileRepository.Save() でMySQLに保存
6. オブジェクトストレージ（Beta: Garage / 本番: OCI Object Storage）へのアップロード（`StoragePort` 経由）:
   a. StorageKey を生成: `{org_id}/{media_id}/original`
   b. PutObject で保存（S3 互換 API、署名 v4）
   c. バイナリ整合性チェック（MD5 / ETag 比較）
   - ストレージエラー → ロールバック＆500 Internal Server Error
7. MediaFile.TransitionTo("PROCESSING") でステータス更新
8. ProcessingJob を生成（メディア種別に応じて）:
   a. `HEIC_CONVERT`（mime_type が image/heic または image/heif の場合）→ libheif で JPEG/WebP 生成
   b. `HLS_TRANSCODE`（mime_type が video/mp4 / video/quicktime の場合）→ FFmpeg で 360p/720p/1080p、6秒セグメント
   c. `LIVE_PHOTO_PAIRING`（HEIC + QuickTime `.mov` の pair 判定）→ `com.apple.quicktime.content.identifier` でマッチング
   d. `THUMBNAIL_GEN`（全メディア対象）
   - すべて `QueuePort` 経由でキュー投入（Beta: Redis+BullMQ/asynq、本番: OCI Queue）
9. アップロード完了イベント発行：
   a. MediaUploaded イベント → `QueuePort.Publish("recuerdo.media.uploaded", ...)`
10. レスポンス返却：
    - media_id, status="PROCESSING", storage_key を返す
    - Location ヘッダーに GET /api/media/{org_id}/{media_id} を指定

### 注意事項
- ファイルハッシュは内部用（整合性検証）であり、クライアント送信ハッシュとの照合は行わない（帯域節約）
- オブジェクトストレージのアップロード失敗時は MediaFile delete & retry を考慮し、べき等性を確保
- 処理ジョブキュー投入失敗時は MediaFile を status="FAILED" に遷移。エンドユーザーには「処理失敗」と報告

## DeliverMedia — 配信ユースケース詳細

### トリガー
GET /api/media/{org_id}/{media_id}?type=original|optimized|thumb

### フロー
1. GetMediaMetadataUseCase.Execute() でメディア取得 & アクセス権チェック
   - 存在しない → 404 Not Found
   - status == "FAILED" → 404 Not Found
   - アクセス権なし → 403 Forbidden
2. MediaFile.CanBeAccessedBy(requesting_user_id, ...) で権限判定
   a. AccessPolicy に基づき Permission Service に照合（gRPC）
      - PRIVATE: uploader_id == requesting_user_id
      - ORG_MEMBERS: requesting_user_id が org_id メンバー
      - EVENT_MEMBERS: requesting_user_id がイベント参加者
3. delivery_type に応じた StorageKey を決定:
   - original → `{org_id}/{media_id}/original`
   - optimized → `{org_id}/{media_id}/optimized.jpg` または `.webp`（HEIC→JPEG/WebP 変換後、またはoriginal自体）
   - hls → `{org_id}/{media_id}/hls/master.m3u8`（動画の HLS マスタープレイリスト。セグメント URL もマニフェスト内で同一バケット内の相対パスを使用）
   - thumb → {org_id}/{media_id}/thumb
4. Redis キャッシュをチェック（PresignedURL の事前生成済みキャッシュ）
   - Hit → TTL確認 & キャッシュ値を返す
5. キャッシュミス時：
   a. `StoragePort.GeneratePresignedURL()`（Garage / OCI Object Storage 双方とも S3 互換 API 署名 v4 を利用）
      - TTL: 1時間
      - Method: GET
      - 署名付きURL生成
   b. Redis に キャッシュ保存（TTL: 50分）
6. Presigned URL とメタデータをレスポンス返却:
   - presigned_url, content_type, expires_at, file_size_bytes
   - Location ヘッダーに Presigned URL を指定し、クライアント側でリダイレクト

### 注意事項
- Presigned URL は署名付きのため、CDN キャッシュに不適切。直接オブジェクトストレージ（Garage / OCI）へのアクセスになる。CDN を将来導入する場合は、Beta では CoreServerV2 のリバースプロキシ、本番では OCI 標準配信機構を使用する（AWS CloudFront は採用しない）
- 複数リクエストで同一 URL が生成される（URL署名値の再生成）
- キャッシュミス時の生成遅延対策：Redis キャッシュ HIT 率 99%+ を目指す

### ポート・サービスインターフェース（レイヤー間通信）

```go
// Repository Ports
type MediaRepository interface {
    Save(ctx context.Context, media *MediaFile) error
    GetByID(ctx context.Context, orgID, mediaID string) (*MediaFile, error)
    GetByIDAndOrgID(ctx context.Context, orgID, mediaID string) (*MediaFile, error)
    Update(ctx context.Context, media *MediaFile) error
    Delete(ctx context.Context, mediaID string) error
    ListByOrg(ctx context.Context, orgID string, limit, offset int) ([]*MediaFile, int, error)
}

type MediaChunkRepository interface {
    Save(ctx context.Context, chunk *MediaChunk) error
    GetByMediaID(ctx context.Context, mediaID string) ([]*MediaChunk, error)
    GetByMediaIDAndIndex(ctx context.Context, mediaID string, index int) (*MediaChunk, error)
    DeleteByMediaID(ctx context.Context, mediaID string) error
    DeleteExpired(ctx context.Context) (int, error)
}

type ProcessingJobRepository interface {
    Save(ctx context.Context, job *ProcessingJob) error
    GetByID(ctx context.Context, jobID string) (*ProcessingJob, error)
    GetByMediaID(ctx context.Context, mediaID string) ([]*ProcessingJob, error)
    Update(ctx context.Context, job *ProcessingJob) error
    ListPending(ctx context.Context, limit int) ([]*ProcessingJob, error)
}

// Service Ports
type StoragePort interface {
    // オブジェクトストレージ操作（Garage / OCI Object Storage 両対応、S3 互換 API）
    UploadObject(ctx context.Context, key string, content []byte, contentType string) error
    MergeChunks(ctx context.Context, targetKey string, chunkKeys []string) error  // CompleteMultipartUpload
    GeneratePresignedURL(ctx context.Context, key string, ttl time.Duration) (string, error)
    DeleteObject(ctx context.Context, key string) error
    ObjectExists(ctx context.Context, key string) (bool, error)
}

// MediaTranscoderPort - FFmpeg HLS / libheif HEIC 変換・Live Photo ペアリングの抽象化
type MediaTranscoderPort interface {
    TranscodeToHLS(ctx context.Context, sourceKey string, targetPrefix string, profiles []HLSProfile) (manifestKey string, err error)
    ConvertHEIC(ctx context.Context, sourceKey string, outputFormat HEICTargetFormat) (optimizedKey string, err error)
    ExtractLivePhotoIdentifier(ctx context.Context, sourceKey string) (identifier string, err error)
    GenerateThumbnail(ctx context.Context, sourceKey string, maxEdgePx int) (thumbKey string, err error)
    ConcatenateVideos(ctx context.Context, sourceKeys []string, outputKey string) error  // ハイライト動画用
}

type QueuePort interface {
    // キュー抽象化（Beta: Redis+BullMQ/asynq、本番: OCI Queue）
    Publish(ctx context.Context, topic string, message []byte) error
    EnqueueJob(ctx context.Context, queueName string, job *ProcessingJob) error
    GetJobStatus(ctx context.Context, jobID string) (string, error)
}

type PermissionPort interface {
    // Permission Service gRPC 委譲
    CheckOrgMembership(ctx context.Context, userID, orgID string) (bool, error)
    CheckEventMembership(ctx context.Context, userID, eventID string) (bool, error)
}

type CachePort interface {
    // Redis キャッシュ操作
    Get(ctx context.Context, key string) (string, error)
    Set(ctx context.Context, key, value string, ttl time.Duration) error
    Delete(ctx context.Context, key string) error
}

type EventPublisherPort interface {
    // QueuePort 経由のドメインイベント発行（Beta: Redis+BullMQ、本番: OCI Queue）
    Publish(ctx context.Context, event DomainEvent) error
}

// Use Case Interfaces
type UploadMediaSingleUseCase interface {
    Execute(ctx context.Context, input UploadMediaSingleInput) (*UploadMediaSingleOutput, error)
}

type DeliverMediaUseCase interface {
    Execute(ctx context.Context, input DeliverMediaInput) (*DeliverMediaOutput, error)
}

type GetMediaMetadataUseCase interface {
    Execute(ctx context.Context, input GetMediaMetadataInput) (*GetMediaMetadataOutput, error)
}

type DeleteMediaUseCase interface {
    Execute(ctx context.Context, input DeleteMediaInput) (*DeleteMediaOutput, error)
}
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ             | ルート/トリガー                                          | ユースケース                 | 説明                                                  |
| ------------------------ | -------------------------------------------------------- | ---------------------------- | ----------------------------------------------------- |
| HTTPMediaHandler         | POST /api/media/{org_id}/single                          | UploadMediaSingleUseCase     | 単一ファイルアップロード（multipart/form-data）       |
| HTTPMediaHandler         | GET /api/media/{org_id}/{media_id}                       | DeliverMediaUseCase          | メディア配信（Presigned URL返却）                     |
| HTTPMediaHandler         | GET /api/media/{org_id}/{media_id}/metadata              | GetMediaMetadataUseCase      | メディアメタデータ取得                                |
| HTTPMediaHandler         | DELETE /api/media/{org_id}/{media_id}                    | DeleteMediaUseCase           | メディア削除（アップロード者のみ）                    |
| HTTPMediaHandler         | GET /api/media/{org_id}                                  | ListOrgMediaUseCase          | 組織メディア一覧（ページネーション対応）              |
| HTTPChunkedUploadHandler | POST /api/media/{org_id}/upload                          | InitiateChunkedUploadUseCase | チャンク型アップロード初期化                          |
| HTTPChunkedUploadHandler | PUT /api/media/{org_id}/upload/{upload_id}/{chunk_index} | UploadMediaChunkUseCase      | 各チャンクアップロード                                |
| HTTPChunkedUploadHandler | POST /api/media/{org_id}/merge                           | MergeChunkedUploadUseCase    | チャンクマージ完了                                    |
| HealthHandler            | GET /health                                              | ヘルスチェック               | 依存サービス（オブジェクトストレージ/Redis/MySQL・MariaDB）の状態確認 |
| MetricsHandler           | GET /metrics                                             | Prometheusメトリクス         | アップロード件数・処理時間・エラー率                  |
| AsyncJobWorker           | QueuePort Consumer（Beta: asynq / 本番: OCI Queue poll） | ProcessingJobUseCase         | HLS_TRANSCODE・HEIC_CONVERT・THUMBNAIL_GEN・LIVE_PHOTO_PAIRING・HIGHLIGHT_CONCAT ジョブ実行 |
| BatchCleanupWorker       | cron: 夜間 02:00                                         | CleanupExpiredChunksUseCase  | 有効期限切れチャンク削除                              |

### リポジトリ実装

| ポートインターフェース  | 実装クラス                   | データストア                  | 説明                     |
| ----------------------- | ---------------------------- | ----------------------------- | ------------------------ |
| MediaRepository         | MySQLMediaRepository         | MySQL 8.0 / MariaDB 10.11 (media_files table)     | MediaFile の永続化・検索 |
| MediaChunkRepository    | MySQLMediaChunkRepository    | MySQL 8.0 / MariaDB 10.11 (media_chunks table)    | MediaChunk の管理        |
| ProcessingJobRepository | MySQLProcessingJobRepository | MySQL 8.0 / MariaDB 10.11 (processing_jobs table) | ProcessingJob の状態管理 |
| CachePort               | RedisCacheAdapter            | Redis 7.x（Beta: XServer VPS / 本番: OCI Cache with Redis） | Presigned URL キャッシュ |

### 外部サービスアダプタ

| ポートインターフェース | アダプタクラス               | 外部システム                    | 説明                                                          |
| ---------------------- | ---------------------------- | ------------------------------- | ------------------------------------------------------------- |
| StoragePort            | **Beta:** `GarageStorageAdapter` / **本番:** `OCIObjectStorageAdapter` | Garage（S3互換 OSS, CoreServerV2 CORE+X）/ OCI Object Storage | ファイルアップロード・Presigned URL 生成・Multipart マージ。いずれも `aws-sdk-go-v2/service/s3` を S3 互換クライアントとして利用（エンドポイント URL とリージョン差分のみ） |
| MediaTranscoderPort    | `FFmpegHLSAdapter` / `LibheifAdapter`                                  | FFmpeg（動画 HLS 変換・concat）/ libheif（HEIC→JPEG/WebP 変換・Live Photo 識別子抽出） | ワーカープロセス内で実行。Beta はコンテナ同居、本番は OCI Container Instances 上の専用ワーカー |
| QueuePort              | **Beta:** `RedisBullMQAdapter`（Node）または `AsynqAdapter`（Go）/ **本番:** `OCIQueueAdapter` | Redis 7.x + BullMQ/asynq / OCI Queue Service | ジョブキュー管理（PENDING/RUNNING/DONE/FAILED）・ドメインイベント発行 |
| PermissionPort         | `PermissionServiceGRPCAdapter`                                         | recerdo-permission (gRPC)  | 組織メンバーシップ・イベント参加状態の確認                    |
| EventPublisherPort     | `QueueEventPublisher`（QueuePort を委譲）                              | Topic: `recuerdo.media.*`       | MediaUploaded・MediaReady・MediaProcessingFailed・HighlightVideoReady イベント発行 |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + net/http (HTTPサーバー) + gorilla/mux (ルーティング) + gorilla/handlers (CORS・ロギング)

### データベース

**MySQL 8.0 / MariaDB 10.11** (`go-sql-driver/mysql`, pool max 50):
- media_files テーブル（MediaFile永続化）
- media_chunks テーブル（チャンク管理）
- processing_jobs テーブル（処理ジョブ状態）
- MariaDB 互換テストは CI で必須（全クエリを MySQL 8.0 と MariaDB 10.11 の両方で実行）

**Redis 7.x** (go-redis/v9, pool max 20):
- Presigned URL キャッシュ
- Beta ではジョブキュー（asynq）も同居。本番は OCI Queue に切替

**オブジェクトストレージ** (aws-sdk-go-v2/service/s3 を S3 互換クライアントとして利用):
- Beta: Garage（S3 互換 OSS、CoreServerV2 CORE+X 6GB 上で運用）
- 本番: OCI Object Storage
- バケット配下のキー構造:
  - `{org_id}/{media_id}/original` — アップロード直後のオリジナル
  - `{org_id}/{media_id}/optimized.jpg|.webp` — HEIC→JPEG/WebP 変換後
  - `{org_id}/{media_id}/hls/master.m3u8` + `{org_id}/{media_id}/hls/{360p|720p|1080p}_NNN.ts` — HLS マニフェストとセグメント
  - `{org_id}/{media_id}/thumb` — サムネイル
  - `{org_id}/{media_id}/live_photo_still` / `{org_id}/{media_id}/live_photo_motion` — Live Photo ペア
  - `{org_id}/highlights/{highlight_id}/output.mp4` — ユーザー選択ハイライト動画連結結果

### SQL スキーマ定義

```sql
-- media_files テーブル
CREATE TABLE media_files (
    id VARCHAR(26) PRIMARY KEY,
    org_id VARCHAR(26) NOT NULL,
    uploader_id VARCHAR(26) NOT NULL,
    original_filename VARCHAR(255) NOT NULL,
    mime_type VARCHAR(50) NOT NULL,
    file_size_bytes BIGINT NOT NULL CHECK (file_size_bytes > 0),
    storage_key VARCHAR(512) NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('UPLOADING', 'PROCESSING', 'READY', 'FAILED')),
    access_policy VARCHAR(20) NOT NULL DEFAULT 'PRIVATE' CHECK (access_policy IN ('PRIVATE', 'ORG_MEMBERS', 'EVENT_MEMBERS')),
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMP,
    FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE,
    FOREIGN KEY (uploader_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT valid_mime_type CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/heic', 'video/mp4')),
    CONSTRAINT valid_file_size CHECK (
        (mime_type LIKE 'image/%' AND file_size_bytes <= 104857600) OR
        (mime_type = 'video/mp4' AND file_size_bytes <= 524288000)
    )
);

CREATE INDEX idx_media_files_org_id ON media_files(org_id);
CREATE INDEX idx_media_files_uploader_id ON media_files(uploader_id);
CREATE INDEX idx_media_files_status ON media_files(status);
CREATE INDEX idx_media_files_created_at ON media_files(created_at);

-- media_chunks テーブル
CREATE TABLE media_chunks (
    id VARCHAR(26) PRIMARY KEY,
    media_id VARCHAR(26) NOT NULL,
    chunk_index INT NOT NULL,
    s3_key VARCHAR(512) NOT NULL,
    size_bytes BIGINT NOT NULL CHECK (size_bytes > 0),
    uploaded_at TIMESTAMP NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMP NOT NULL,
    FOREIGN KEY (media_id) REFERENCES media_files(id) ON DELETE CASCADE,
    CONSTRAINT unique_chunk_per_media UNIQUE (media_id, chunk_index)
);

CREATE INDEX idx_media_chunks_media_id ON media_chunks(media_id);
CREATE INDEX idx_media_chunks_expires_at ON media_chunks(expires_at);

-- processing_jobs テーブル
CREATE TABLE processing_jobs (
    id VARCHAR(26) PRIMARY KEY,
    media_id VARCHAR(26) NOT NULL,
    job_type VARCHAR(50) NOT NULL CHECK (job_type IN ('HEIC_CONVERT', 'THUMBNAIL_GEN')),
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'RUNNING', 'DONE', 'FAILED')),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    error_msg TEXT,
    result_storage_key VARCHAR(512),
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (media_id) REFERENCES media_files(id) ON DELETE CASCADE
);

CREATE INDEX idx_processing_jobs_media_id ON processing_jobs(media_id);
CREATE INDEX idx_processing_jobs_status ON processing_jobs(status);
CREATE INDEX idx_processing_jobs_created_at ON processing_jobs(created_at);
```

### 主要ライブラリ・SDK

| ライブラリ                              | 目的                                                                    | レイヤー       |
| --------------------------------------- | ----------------------------------------------------------------------- | -------------- |
| github.com/oklog/ulid/v2                | MediaFile・Chunk・ProcessingJob の ID生成（順序付き・UUID互換）         | Domain         |
| github.com/gorilla/mux                  | HTTPルーティング                                                        | Adapter        |
| github.com/aws/aws-sdk-go-v2/service/s3 | **S3 互換 API クライアント** として Garage および OCI Object Storage の両方で利用 | Infrastructure |
| hibiken/asynq                           | Beta のみ：Redis キューによるジョブスケジューリング（HLS/HEIC/thumb/Live Photo ペアリング） | Infrastructure |
| （OCI SDK）                              | 本番のみ：OCI Queue Service・OCI Object Storage（S3 互換エンドポイント）設定自動化 | Infrastructure |
| go-redis/redis/v9                       | Redis キャッシュ・asynq ジョブキュー（Beta）                            | Infrastructure |
| go-sql-driver/mysql                     | MySQL 8.0 / MariaDB 10.11 両対応ドライバー（接続プーリング）            | Infrastructure |
| strukturag/libheif (cgo バインディング)  | HEIC/HEIF → JPEG/WebP 変換、Live Photo 識別子抽出                       | Infrastructure |
| FFmpeg (サブプロセス実行)                | 動画 HLS 変換（360p/720p/1080p、6秒セグメント、H.264/AAC）、concat     | Infrastructure |
| davidbyttow/govips/v2                   | 画像リサイズ・サムネイル生成                                            | Infrastructure |
| google.golang.org/grpc                  | Permission Service gRPC クライアント                                    | Infrastructure |
| uber-go/fx                              | 依存性注入コンテナ                                                      | Infrastructure |
| uber-go/zap                             | 構造化ログ（JSON形式）                                                  | Infrastructure |
| go.opentelemetry.io/otel                | 分散トレーシング・W3C Trace Context                                     | Infrastructure |
| prometheus/client_golang                | メトリクス収集                                                          | Infrastructure |

### 依存性注入

uber-go/fx を使用。全ポートをインターフェースとして登録。

```go
fx.Provide(
    // Repositories
    NewMySQLMediaRepository,            // → MediaRepository
    NewMySQLMediaChunkRepository,       // → MediaChunkRepository
    NewMySQLProcessingJobRepository,    // → ProcessingJobRepository
    NewRedisCacheAdapter,                    // → CachePort
    
    // External Service Adapters（Feature Flag で Beta / 本番切替）
    NewGarageStorageAdapter,                 // → StoragePort (Beta: Garage)
    NewOCIObjectStorageAdapter,              // → StoragePort (本番: OCI Object Storage)
    NewFFmpegHLSAdapter,                     // → MediaTranscoderPort（HLS/concat）
    NewLibheifAdapter,                       // → MediaTranscoderPort（HEIC 変換・Live Photo 識別子）
    NewRedisBullMQAdapter,                   // → QueuePort (Beta)
    NewOCIQueueAdapter,                      // → QueuePort (本番)
    NewPermissionServiceGRPCAdapter,         // → PermissionPort
    NewQueueEventPublisher,                  // → EventPublisherPort (QueuePort ラッパ)
    
    // Use Cases
    NewUploadMediaSingleUseCase,
    NewInitiateChunkedUploadUseCase,
    NewUploadMediaChunkUseCase,
    NewMergeChunkedUploadUseCase,
    NewDeliverMediaUseCase,
    NewGetMediaMetadataUseCase,
    NewDeleteMediaUseCase,
    NewRetryProcessingUseCase,
    NewListOrgMediaUseCase,
    NewCleanupExpiredChunksUseCase,
    
    // Controllers / Handlers
    NewHTTPMediaHandler,
    NewHTTPChunkedUploadHandler,
    NewHealthHandler,
    NewMetricsHandler,
    NewAsyncJobWorker,
    NewBatchCleanupWorker,
)
```

## 6. ディレクトリ構成

### ディレクトリツリー

```
recerdo-storage/
├── cmd/
│   ├── server/
│   │   └── main.go                 # アプリケーション起動
│   └── worker/
│       └── main.go                 # 非同期ジョブワーカー起動
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── media_file.go       # MediaFile エンティティ
│   │   │   ├── media_chunk.go      # MediaChunk エンティティ
│   │   │   ├── processing_job.go   # ProcessingJob エンティティ
│   │   │   └── status.go           # ステータス値オブジェクト
│   │   ├── valueobject/
│   │   │   ├── media_status.go     # MediaStatus 値オブジェクト
│   │   │   ├── mime_type.go        # MimeType 値オブジェクト + バリデーション
│   │   │   ├── file_size.go        # FileSize 値オブジェクト
│   │   │   ├── storage_key.go      # StorageKey パス構築
│   │   │   ├── access_policy.go    # AccessPolicy 値オブジェクト
│   │   │   ├── delivery_type.go    # DeliveryType 値オブジェクト
│   │   │   └── presigned_url.go    # PresignedURL 値オブジェクト
│   │   ├── event/
│   │   │   └── domain_events.go    # MediaUploaded・MediaReady・MediaProcessingFailed イベント
│   │   └── errors.go               # ドメイン固有エラー
│   ├── usecase/
│   │   ├── upload_media_single.go
│   │   ├── initiate_chunked_upload.go
│   │   ├── upload_media_chunk.go
│   │   ├── merge_chunked_upload.go
│   │   ├── deliver_media.go        # 最重要ユースケース（Presigned URL生成）
│   │   ├── get_media_metadata.go
│   │   ├── delete_media.go
│   │   ├── retry_processing.go
│   │   ├── list_org_media.go
│   │   ├── cleanup_expired_chunks.go
│   │   └── port/
│   │       ├── repository.go       # MediaRepository・MediaChunkRepository・ProcessingJobRepository
│   │       └── service.go          # StoragePort・ProcessingQueuePort・PermissionPort・CachePort・EventPublisherPort
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── media_handler.go    # POST/GET/DELETE メディアハンドラ
│   │   │   ├── chunked_upload_handler.go  # チャンク型アップロード
│   │   │   ├── health_handler.go
│   │   │   ├── metrics_handler.go
│   │   │   ├── middleware/
│   │   │   │   ├── auth.go         # JWT認証・X-User-Id ヘッダー抽出
│   │   │   │   ├── trace.go        # W3C Trace Context 伝播
│   │   │   │   └── error_handler.go
│   │   │   └── dto.go              # HTTP リクエスト・レスポンス DTO
│   │   ├── queue/
│   │   │   ├── queue_consumer.go   # QueuePort Consumer（メディアイベント消費）
│   │   │   └── job_handler.go      # HLS_TRANSCODE・HEIC_CONVERT・THUMBNAIL_GEN・LIVE_PHOTO_PAIRING・HIGHLIGHT_CONCAT 実行
│   │   ├── processor/
│   │   │   ├── ffmpeg_hls.go       # FFmpeg HLS 変換（360p/720p/1080p、6秒セグメント）
│   │   │   ├── libheif_converter.go # HEIC→JPEG/WebP 変換・Live Photo 識別子抽出
│   │   │   └── thumbnail_generator.go  # サムネイル生成実装
│   │   └── batch/
│   │       └── cleanup_worker.go   # 夜間バッチ（有効期限切れチャンク削除）
│   └── infrastructure/
│       ├── MySQL/
│       │   ├── media_repository.go          # MediaRepository 実装
│       │   ├── media_chunk_repository.go    # MediaChunkRepository 実装
│       │   ├── processing_job_repository.go # ProcessingJobRepository 実装
│       │   ├── migrations/
│       │   │   ├── 001_create_media_files.sql
│       │   │   ├── 002_create_media_chunks.sql
│       │   │   └── 003_create_processing_jobs.sql
│       │   └── db.go                        # コネクションプール管理
│       ├── objectstorage/
│       │   ├── garage_adapter.go            # Beta: Garage StoragePort 実装（S3 互換）
│       │   ├── oci_adapter.go               # 本番: OCI Object Storage StoragePort 実装（S3 互換）
│       │   └── config.go                    # エンドポイント・署名設定
│       ├── redis/
│       │   ├── cache_adapter.go             # CachePort 実装（Presigned URLキャッシュ）
│       │   └── config.go                    # Redis接続設定
│       ├── asynq/
│       │   ├── processing_queue.go          # ProcessingQueuePort 実装
│       │   ├── job_types.go                 # ジョブ種別定義
│       │   └── handler.go                   # ジョブハンドラ実行
│       ├── grpc/
│       │   ├── permission_adapter.go        # PermissionPort 実装（gRPC）
│       │   └── config.go                    # Permission Service gRPC設定
│       ├── queue/
│       │   ├── redis_bullmq_adapter.go      # Beta: Redis + BullMQ QueuePort 実装
│       │   ├── asynq_adapter.go             # Beta (Go): asynq QueuePort 実装
│       │   ├── oci_queue_adapter.go         # 本番: OCI Queue Service QueuePort 実装
│       │   └── event_publisher.go           # QueuePort 経由 EventPublisherPort 実装
│       ├── logger/
│       │   └── logger.go                    # uber-go/zap 設定
│       └── metrics/
│           └── metrics.go                   # Prometheus メトリクス定義
├── config/
│   ├── config.yaml                 # アプリケーション設定
│   └── dev.env                     # 開発環境変数
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── secret.yaml
├── test/
│   ├── integration/
│   │   ├── upload_media_single_test.go
│   │   ├── deliver_media_test.go
│   │   ├── delete_media_test.go
│   │   └── chunked_upload_test.go
│   ├── e2e/
│   │   └── end_to_end_test.go      # 完全なアップロード→配信フロー
│   └── testdata/
│       ├── test_image.heic
│       └── test_video.mp4
├── go.mod
├── go.sum
└── README.md
```

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー                    | テスト種別       | テストパターン                                                                                                                                                                                                                        | モック戦略                                                                                                            |
| --------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Domain (entity/valueobject) | Unit test        | MimeType.Validate()・FileSize.Validate()・MediaFile.TransitionTo()・MediaFile.CanBeAccessedBy()・MediaFile.CanBeDeletedBy()・StorageKey 生成・AccessPolicy チェック                                                                   | 外部依存なし                                                                                                          |
| UseCase                     | Unit test        | UploadMediaSingleUseCase・DeliverMediaUseCase・DeleteMediaUseCase・MergeChunkedUploadUseCase                                                                                                                                          | mockeryで全ポート（MediaRepository・StoragePort・PermissionPort・CachePort・EventPublisherPort）をモック              |
| Adapter (HTTP)              | Integration test | POST /api/media/{org_id}/single・GET /api/media/{org_id}/{media_id}・DELETE /api/media/{org_id}/{media_id}・POST /api/media/{org_id}/upload・PUT /api/media/{org_id}/upload/{upload_id}/{chunk_index}・POST /api/media/{org_id}/merge | httptest.Server で上流サービス（Permission Service）をモック。S3・MySQL・Redisは testcontainers-go で実コンテナを起動 |
| Infrastructure (MySQL)      | Integration test | MediaRepository.Save()・GetByID()・ListByOrg()・MediaChunkRepository.DeleteExpired()・ProcessingJobRepository.ListPending()                                                                                                           | testcontainers-go で MySQL 14 コンテナを起動                                                                          |
| Infrastructure (ObjectStorage) | Integration test | `GarageStorageAdapter` / `OCIObjectStorageAdapter` の UploadObject()・GeneratePresignedURL()・MergeChunks()・DeleteObject()                                                                                                          | testcontainers-go で Garage コンテナを起動（S3 互換 API）。OCI は sandbox テナントまたは S3 互換モックサーバー        |
| Infrastructure (Redis)      | Integration test | RedisCacheAdapter.Get()・Set()・Delete()・キャッシュヒット/ミス                                                                                                                                                                       | testcontainers-go で Redis 7 コンテナを起動                                                                           |
| Infrastructure (asynq)      | Integration test | ProcessingJob 投入・ステータス確認・ジョブ完了                                                                                                                                                                                        | testcontainers-go で Redis + asynq inspector                                                                          |
| Processing (HEIC→PNG)       | Unit test        | HEIC ファイルのPNG変換・形式チェック                                                                                                                                                                                                  | テスト画像 (testdata/test_image.heic)                                                                                 |
| Processing (Thumbnail)      | Unit test        | 画像リサイズ・長辺1280px制約・アスペクト比保持                                                                                                                                                                                        | テスト画像各種                                                                                                        |
| E2E                         | E2E test         | 単一ファイルアップロード→PROCESSING→READY→配信・チャンク型アップロード→マージ→配信・削除                                                                                                                                              | 実サービス起動（Docker Compose）                                                                                      |

### テストコード例

```go
// Entity Test
func TestMediaFile_NewMediaFile_Success(t *testing.T) {
    mimeType := MimeTypeJPEG
    media, err := NewMediaFile("org-1", "user-1", "photo.jpg", mimeType, 1000000)
    
    require.NoError(t, err)
    assert.Equal(t, "org-1", media.OrgID)
    assert.Equal(t, "user-1", media.UploaderID)
    assert.Equal(t, "photo.jpg", media.OriginalFilename)
    assert.Equal(t, "UPLOADING", media.Status)
    assert.Equal(t, "PRIVATE", media.AccessPolicy)
}

func TestMediaFile_NewMediaFile_InvalidMimeType(t *testing.T) {
    _, err := NewMediaFile("org-1", "user-1", "file.exe", MimeType("application/octet-stream"), 1000000)
    assert.ErrorIs(t, err, ErrInvalidMimeType)
}

func TestMediaFile_NewMediaFile_FileTooLarge(t *testing.T) {
    // 100MBを超える画像
    _, err := NewMediaFile("org-1", "user-1", "huge.jpg", MimeTypeJPEG, 101*1024*1024)
    assert.ErrorIs(t, err, ErrFileTooLarge)
}

func TestMediaFile_TransitionTo_ValidTransition(t *testing.T) {
    media := &MediaFile{Status: "UPLOADING"}
    err := media.TransitionTo("PROCESSING")
    
    require.NoError(t, err)
    assert.Equal(t, "PROCESSING", media.Status)
}

func TestMediaFile_TransitionTo_InvalidTransition(t *testing.T) {
    media := &MediaFile{Status: "READY"}
    err := media.TransitionTo("UPLOADING")
    
    assert.ErrorIs(t, err, ErrInvalidStatusTransition)
}

func TestMediaFile_CanBeAccessedBy_PRIVATE(t *testing.T) {
    media := &MediaFile{UploaderID: "user-1", Status: "READY", AccessPolicy: "PRIVATE"}
    
    assert.True(t, media.CanBeAccessedBy("user-1", []string{}, []string{}))
    assert.False(t, media.CanBeAccessedBy("user-2", []string{}, []string{}))
}

func TestMediaFile_CanBeAccessedBy_ORG_MEMBERS(t *testing.T) {
    media := &MediaFile{Status: "READY", AccessPolicy: "ORG_MEMBERS"}
    
    assert.True(t, media.CanBeAccessedBy("user-1", []string{"user-1", "user-2"}, []string{}))
    assert.False(t, media.CanBeAccessedBy("user-3", []string{"user-1", "user-2"}, []string{}))
}

func TestMediaFile_CanBeAccessedBy_FAILED_Status(t *testing.T) {
    media := &MediaFile{Status: "FAILED", AccessPolicy: "PRIVATE", UploaderID: "user-1"}
    
    assert.False(t, media.CanBeAccessedBy("user-1", []string{}, []string{}))
}

func TestMediaFile_CanBeDeletedBy_UploaderOnly(t *testing.T) {
    media := &MediaFile{UploaderID: "user-1"}
    
    assert.True(t, media.CanBeDeletedBy("user-1"))
    assert.False(t, media.CanBeDeletedBy("user-2"))
}

func TestMediaChunk_IsExpired(t *testing.T) {
    chunk := &MediaChunk{ExpiresAt: time.Now().Add(-1 * time.Hour)}
    assert.True(t, chunk.IsExpired())
    
    chunk2 := &MediaChunk{ExpiresAt: time.Now().Add(1 * time.Hour)}
    assert.False(t, chunk2.IsExpired())
}

// UseCase Test
func TestUploadMediaSingleUseCase_ValidFile_Success(t *testing.T) {
    mockMediaRepo := new(MockMediaRepository)
    mockStoragePort := new(MockStoragePort)
    mockPermissionPort := new(MockPermissionPort)
    mockQueue := new(MockProcessingQueuePort)
    mockPublisher := new(MockEventPublisherPort)
    
    // Setup expectations
    mockPermissionPort.On("CheckOrgMembership", mock.Anything, "user-1", "org-1").Return(true, nil)
    mockStoragePort.On("UploadObject", mock.Anything, mock.MatchedBy(func(key string) bool {
        return strings.Contains(key, "/original")
    }), mock.Anything, "image/jpeg").Return(nil)
    mockMediaRepo.On("Save", mock.Anything, mock.AnythingOfType("*domain.MediaFile")).Return(nil)
    mockQueue.On("EnqueueJob", mock.Anything, mock.AnythingOfType("*domain.ProcessingJob")).Return(nil)
    mockPublisher.On("Publish", mock.Anything, mock.AnythingOfType("domain.DomainEvent")).Return(nil)
    
    uc := NewUploadMediaSingleUseCase(mockMediaRepo, mockStoragePort, mockPermissionPort, mockQueue, mockPublisher)
    input := UploadMediaSingleInput{
        OrgID:      "org-1",
        UploaderID: "user-1",
        Filename:   "photo.jpg",
        MimeType:   "image/jpeg",
        FileBytes:  []byte("fake jpeg content"),
        AccessPolicy: "PRIVATE",
    }
    
    output, err := uc.Execute(context.Background(), input)
    
    require.NoError(t, err)
    assert.NotEmpty(t, output.MediaID)
    assert.Equal(t, "PROCESSING", output.Status)
    mockMediaRepo.AssertExpectations(t)
    mockStoragePort.AssertExpectations(t)
    mockPublisher.AssertExpectations(t)
}

func TestUploadMediaSingleUseCase_PermissionDenied(t *testing.T) {
    mockMediaRepo := new(MockMediaRepository)
    mockPermissionPort := new(MockPermissionPort)
    
    mockPermissionPort.On("CheckOrgMembership", mock.Anything, "user-1", "org-1").Return(false, nil)
    
    uc := NewUploadMediaSingleUseCase(mockMediaRepo, nil, mockPermissionPort, nil, nil)
    input := UploadMediaSingleInput{
        OrgID:      "org-1",
        UploaderID: "user-1",
        Filename:   "photo.jpg",
        MimeType:   "image/jpeg",
        FileBytes:  []byte("content"),
    }
    
    _, err := uc.Execute(context.Background(), input)
    assert.ErrorIs(t, err, ErrPermissionDenied)
}

func TestDeliverMediaUseCase_CacheHit(t *testing.T) {
    mockMediaRepo := new(MockMediaRepository)
    mockCache := new(MockCachePort)
    mockPermissionPort := new(MockPermissionPort)
    
    media := &MediaFile{
        ID:           "media-1",
        UploaderID:   "user-1",
        Status:       "READY",
        AccessPolicy: "PRIVATE",
    }
    
    mockMediaRepo.On("GetByID", mock.Anything, "org-1", "media-1").Return(media, nil)
    mockPermissionPort.On("CheckOrgMembership", mock.Anything, "user-1", "org-1").Return(true, nil)
    mockCache.On("Get", mock.Anything, "presigned:org-1:media-1:original").Return("https://s3.amazonaws.com/presigned-url", nil)
    
    uc := NewDeliverMediaUseCase(mockMediaRepo, mockCache, mockPermissionPort, nil)
    input := DeliverMediaInput{
        OrgID:            "org-1",
        MediaID:          "media-1",
        DeliveryType:     "original",
        RequestingUserID: "user-1",
    }
    
    output, err := uc.Execute(context.Background(), input)
    
    require.NoError(t, err)
    assert.Equal(t, "https://s3.amazonaws.com/presigned-url", output.PresignedURL)
}

func TestDeliverMediaUseCase_StatusFailed(t *testing.T) {
    mockMediaRepo := new(MockMediaRepository)
    
    media := &MediaFile{
        ID:     "media-1",
        Status: "FAILED",
    }
    
    mockMediaRepo.On("GetByID", mock.Anything, "org-1", "media-1").Return(media, nil)
    
    uc := NewDeliverMediaUseCase(mockMediaRepo, nil, nil, nil)
    input := DeliverMediaInput{
        OrgID:        "org-1",
        MediaID:      "media-1",
        DeliveryType: "original",
    }
    
    _, err := uc.Execute(context.Background(), input)
    assert.ErrorIs(t, err, ErrMediaNotFound)
}

// Integration Test
func TestHTTPMediaHandler_UploadMediaSingle_End2End(t *testing.T) {
    // testcontainers で MySQL 8.0/MariaDB 10.11・Garage（S3 互換 OSS）・Redis を起動
    db := setupTestMySQL(t)
    s3 := setupTestS3(t)
    redis := setupTestRedis(t)
    
    // リポジトリ・ポートを実装で初期化
    mediaRepo := MySQL.NewMediaRepository(db)
    storagePort := s3.NewStorageAdapter(s3.Client())
    cachePort := redis.NewCacheAdapter(redis.Client())
    
    // HTTPハンドラを起動
    handler := NewHTTPMediaHandler(mediaRepo, storagePort, cachePort)
    router := mux.NewRouter()
    router.HandleFunc("/api/media/{org_id}/single", handler.UploadSingle).Methods("POST")
    
    // テストリクエスト作成
    buf := new(bytes.Buffer)
    writer := multipart.NewWriter(buf)
    part, _ := writer.CreateFormFile("file", "test.jpg")
    part.Write([]byte("fake jpeg data"))
    writer.WriteField("access_policy", "PRIVATE")
    writer.Close()
    
    req := httptest.NewRequest("POST", "/api/media/org-1/single", buf)
    req.Header.Set("Content-Type", writer.FormDataContentType())
    req.Header.Set("X-User-Id", "user-1")
    
    // リクエスト実行
    w := httptest.NewRecorder()
    router.ServeHTTP(w, req)
    
    // アサーション
    assert.Equal(t, http.StatusOK, w.Code)
    var response map[string]interface{}
    json.Unmarshal(w.Body.Bytes(), &response)
    assert.NotEmpty(t, response["media_id"])
    assert.Equal(t, "PROCESSING", response["status"])
}

// E2E Test
func TestUploadDeliverDeleteFlow_E2E(t *testing.T) {
    // Docker Compose で完全なマイクロサービス環境を起動
    env := setupDockerCompose(t)
    defer env.Down()
    
    client := &http.Client{}
    
    // 1. アップロード
    uploadReq := setupUploadRequest("org-1", "user-1", testImagePath)
    uploadResp, _ := client.Do(uploadReq)
    assert.Equal(t, http.StatusOK, uploadResp.StatusCode)
    var uploadBody map[string]interface{}
    json.NewDecoder(uploadResp.Body).Decode(&uploadBody)
    mediaID := uploadBody["media_id"].(string)
    
    // 2. ポーリング: PROCESSING → READY
    time.Sleep(2 * time.Second) // 処理時間待機
    metadataReq := httptest.NewRequest("GET", "/api/media/org-1/"+mediaID+"/metadata", nil)
    metadataReq.Header.Set("X-User-Id", "user-1")
    metadataResp, _ := client.Do(metadataReq)
    var metadataBody map[string]interface{}
    json.NewDecoder(metadataResp.Body).Decode(&metadataBody)
    assert.Equal(t, "READY", metadataBody["status"])
    
    // 3. 配信（Presigned URL取得）
    deliveryReq := httptest.NewRequest("GET", "/api/media/org-1/"+mediaID+"?type=thumb", nil)
    deliveryReq.Header.Set("X-User-Id", "user-1")
    deliveryResp, _ := client.Do(deliveryReq)
    assert.Equal(t, http.StatusOK, deliveryResp.StatusCode)
    var deliveryBody map[string]interface{}
    json.NewDecoder(deliveryResp.Body).Decode(&deliveryBody)
    presignedURL := deliveryBody["presigned_url"].(string)
    assert.NotEmpty(t, presignedURL)
    
    // 4. Presigned URL経由でS3から実ファイル取得可能か確認
    fileResp, _ := client.Get(presignedURL)
    assert.Equal(t, http.StatusOK, fileResp.StatusCode)
    
    // 5. 削除
    deleteReq := httptest.NewRequest("DELETE", "/api/media/org-1/"+mediaID, nil)
    deleteReq.Header.Set("X-User-Id", "user-1")
    deleteResp, _ := client.Do(deleteReq)
    assert.Equal(t, http.StatusOK, deleteResp.StatusCode)
    
    // 6. 削除後はアクセス不可
    metadataReq2 := httptest.NewRequest("GET", "/api/media/org-1/"+mediaID+"/metadata", nil)
    metadataReq2.Header.Set("X-User-Id", "user-1")
    metadataResp2, _ := client.Do(metadataReq2)
    assert.Equal(t, http.StatusNotFound, metadataResp2.StatusCode)
}
```

## 8. エラーハンドリング

### ドメインエラー

- ErrEmptyFile: ファイルサイズが 0 バイト
- ErrInvalidMimeType: MimeType が許可リスト外（application/exe, text/plain など）
- ErrFileTooLarge: ファイルサイズが制限を超過（image/*: 100MB超, video/mp4: 500MB超）
- ErrInvalidFilename: ファイル名に無効文字を含む（特にS3パスで危険な文字）
- ErrMissingOrgID: org_id が空文字列
- ErrMissingUploaderID: uploader_id が空文字列
- ErrInvalidStatusTransition: MediaFile の status 遷移が定義に違反（READY → UPLOADING など）
- ErrInvalidStorageKey: StorageKey の形式が不正（パストラバーサル試行等）
- ErrMediaNotFound: 指定の media_id が存在しない、またはstatus=FAILED
- ErrPermissionDenied: ユーザーに当該メディアへのアクセス権がない
- ErrCannotDelete: 削除権限なし（アップロード者・Org Admin以外）
- ErrChunkedUploadExpired: チャンク型アップロードの有効期限切れ（24時間経過）
- ErrChunkMissingOrCorrupted: チャンクが見つからない、またはハッシュ不一致
- ErrUploadInProgress: 同一 media_id への同時アップロード試行
- ErrObjectStorageUploadFailed: オブジェクトストレージ（Garage / OCI）へのアップロード失敗
- ErrObjectStoragePresignedURLFailed: Presigned URL 生成失敗
- ErrProcessingJobFailed: 非同期処理ジョブ（HLS 変換・HEIC 変換・サムネイル生成・Live Photo ペアリング・ハイライト連結）が失敗
- ErrRedisError: Redisキャッシュ操作失敗
- ErrDatabaseError: MySQL / MariaDB 操作失敗
- ErrPermissionServiceUnavailable: Permission Service との通信失敗
- ErrQueuePublishFailed: イベント発行（QueuePort）失敗

### エラー → HTTPステータスマッピング

| ドメインエラー                  | HTTPステータス            | ユーザーメッセージ                                                    | 説明                                        |
| ------------------------------- | ------------------------- | --------------------------------------------------------------------- | ------------------------------------------- |
| ErrEmptyFile                    | 400 Bad Request           | File is empty                                                         | ファイルサイズ 0 バイト                     |
| ErrInvalidMimeType              | 400 Bad Request           | File type is not supported. Supported types: JPEG, PNG, HEIC, MP4     | サポートされていないファイル形式            |
| ErrFileTooLarge                 | 413 Content Too Large     | File size exceeds the limit. Max 100 MB for images, 500 MB for videos | ファイルサイズが制限超過                    |
| ErrInvalidFilename              | 400 Bad Request           | Filename is invalid                                                   | ファイル名に無効文字                        |
| ErrMissingOrgID                 | 400 Bad Request           | Organization ID is required                                           | org_id が空                                 |
| ErrMissingUploaderID            | 401 Unauthorized          | User ID is required                                                   | uploader_id が空（認証なし）                |
| ErrMediaNotFound                | 404 Not Found             | Media not found                                                       | メディアが見つからない、またはstatus=FAILED |
| ErrPermissionDenied             | 403 Forbidden             | You do not have permission to access this media                       | アクセス権なし                              |
| ErrCannotDelete                 | 403 Forbidden             | You do not have permission to delete this media                       | 削除権限なし                                |
| ErrChunkedUploadExpired         | 410 Gone                  | Upload session has expired. Please start a new upload                 | チャンク有効期限切れ                        |
| ErrChunkMissingOrCorrupted      | 400 Bad Request           | Chunk is missing or corrupted. Please re-upload                       | チャンク不正                                |
| ErrUploadInProgress             | 409 Conflict              | Upload is already in progress for this media                          | 同時アップロード試行                        |
| ErrObjectStorageUploadFailed        | 503 Service Unavailable   | Upload service is temporarily unavailable. Please try again later     | オブジェクトストレージ（Garage/OCI）エラー |
| ErrObjectStoragePresignedURLFailed  | 503 Service Unavailable   | Cannot generate download link. Please try again later                 | Presigned URL 生成失敗                     |
| ErrProcessingJobFailed              | 500 Internal Server Error | Media processing failed. Please delete and re-upload                  | 処理失敗                                    |
| ErrRedisError                       | 503 Service Unavailable   | Service is temporarily unavailable. Please try again later            | Redisエラー                                 |
| ErrDatabaseError                    | 503 Service Unavailable   | Service is temporarily unavailable. Please try again later            | DB（MySQL/MariaDB）エラー                   |
| ErrPermissionServiceUnavailable     | 503 Service Unavailable   | Service is temporarily unavailable. Please try again later            | Permission Service 不通                     |
| ErrQueuePublishFailed               | 500 Internal Server Error | Event publishing failed                                               | QueuePort 発行失敗                          |

## 9. 未決事項

### 質問・決定事項

| #   | 質問                                                                                                                                                           | ステータス | 決定                                                                                                      |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------- |
| 1   | 画像最適化（JPEG圧縮率・WebP 圧縮レベル）の決定                                                                                                                 | Resolved   | JPEG quality 85、WebP quality 80（libheif の既定 + govips 再圧縮）。Retina 配信は WebP を優先し、Safari 古バージョン fallback は JPEG                |
| 2   | HEIC/HEIF ファイルの変換先は何か                                                                                                                                | Resolved   | 既定は JPEG（互換性最優先）、配信最適化用に WebP も同時生成。PNG は生成しない（サイズが膨らむため）                                                 |
| 3   | サムネイル長辺 1280px は固定か                                                                                                                                  | Resolved   | 1280px 単一解像度で開始。動画は最初の I-frame をサンプル。将来の複数解像度化は DeliveryType の拡張で対応                                            |
| 4   | チャンク型アップロードのチャンクサイズ                                                                                                                          | Resolved   | 5MB 固定（Garage / OCI Object Storage 双方で Multipart Upload の最小値に合致）                                                                      |
| 5   | Presigned URL のキャッシュ TTL 50分は安全か                                                                                                                     | Resolved   | access_policy 変更・DeleteMedia 時は CachePort.Delete(`presigned:{org_id}:{media_id}:*`) を同期実行。キャッシュ TTL 50分を維持                       |
| 6   | 削除したメディアのオブジェクト物理削除タイミング                                                                                                                | Resolved   | MediaDeleted イベント発火と同時に物理削除（immediate）。GDPR 右に従い、Garage / OCI Object Storage の両方で `{org_id}/{media_id}/*` を一括削除       |
| 7   | 非同期処理ジョブの失敗時リトライ戦略                                                                                                                            | Resolved   | 最大 3 回リトライ、初期遅延 5秒から最大 60秒までの指数バックオフ。`QueuePort` の DLQ（Redis list / OCI Queue DLQ）に移送し Loki + Grafana でアラート |
| 8   | Permission Service ダウン時の Fail-Open / Fail-Closed                                                                                                           | Resolved   | **Fail-Closed** 固定。セキュリティ優先の方針（[基本的方針](../core/policy.md) に従う）                                                               |
| 9   | HLS 変換ビットレート・セグメント時間                                                                                                                            | Resolved   | 360p @ 800kbps / 720p @ 2.5Mbps / 1080p @ 5Mbps、H.264 (High profile) + AAC、6 秒セグメント、keyint=60（GOP 2 秒）。オリジナル解像度を超える profile は省略 |
| 10  | ストレージコスト削減のためのライフサイクル                                                                                                                      | Resolved   | Beta: Garage 側で LRU に基づく古いチャンク自動削除。本番: OCI Object Storage の Archive Tier へ 365日経過後に自動遷移（Lifecycle Rule）             |
| 11  | ハイライト動画の自動生成はするか                                                                                                                                | Resolved   | **しない**。ユーザーが明示的に選択した 2 件以上の動画を FFmpeg concat で連結する方式のみ。ML による自動選定は [基本的方針](../core/policy.md) 違反      |
| 12  | Live Photo ペアリングの方法                                                                                                                                     | Resolved   | HEIC 画像の `com.apple.quicktime.content.identifier` と QuickTime .mov の同値キーをマッチ。片方欠落時は single image/video として扱う                |

---

最終更新: 2026-04-19 ポリシー適用

