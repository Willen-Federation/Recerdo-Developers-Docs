# クリーンアーキテクチャ設計書

| 項目                      | 値                                     |
| ------------------------- | -------------------------------------- |
| **モジュール/サービス名** | Storage Service (recuerdo-storage-svc) |
| **作成者**                | Akira                                  |
| **作成日**                | 2026-04-13                             |
| **ステータス**            | ドラフト                               |
| **バージョン**            | 1.0                                    |

---

## 1. 概要

### 1.1 目的
Storage Service はRecuerdo プラットフォームにおいて、すべてのメディア（写真・動画）の受け入れ、変換、配信を一元管理するマイクロサービスである。ユーザーアップロード、形式変換（HEIC→JPEG/WebP、MP4→HLS）、サムネイル生成、Live Photo ペアリング、アクセス制御付き配信を責務とする。

**インフラ方針（ポリシー適用）**:

- **Beta**: Object Storage = Garage（S3互換OSS）、Queue = Redis + BullMQ/asynq、DB = MySQL 8 (MariaDB互換)
- **Prod**: Object Storage = OCI Object Storage、Queue = OCI Queue、DB = OCI MySQL HeatWave (MariaDB互換SQLに限定)
- **Media Transcoder**: FFmpeg（HLS: 360p/720p/1080p, 6s セグメント）、libheif（HEIC→JPEG/WebP）
- **ハイライトビデオはユーザー指定の素材のみ**を結合し、ML/自動生成は行わない
- **AWS は Cognito のみ**（S3/SQS/SNS/SES/DynamoDB/CloudFront は利用しない）

### 1.2 ビジネスコンテキスト
- Recuerdo はメモリ共有がコアのプラットフォーム：写真・動画は中核資産
- 形式多様性対応：HEIC（Apple）、JPEG、PNG、MP4 など
- アクセス管理：プライベート（自分のみ）、組織メンバー共有、イベント参加者共有
- パフォーマンス：大量アップロード対応、チャンク式アップロード、キャッシュ・CDN 活用

### 1.3 アーキテクチャ原則
- **非同期処理パイプライン**：Upload → QueuePort (Beta: Redis+BullMQ/asynq, Prod: OCI Queue) → Processing Workers → 最適化ファイル出力
- **アクセス制御**：アップロード時に access_policy 設定、配信時に権限チェック
- **ドメイン駆動**：MediaFile、MediaChunk、ProcessingJob エンティティでビジネスロジック表現
- **ストレージ最適化**：オブジェクトストレージ の raw/optimized/thumb フォルダ分離、presigned URL での帯域節約

---

## 2. レイヤーアーキテクチャ

### 2.1 アーキテクチャ図 (ASCII concentric circles)

```
┌─────────────────────────────────────────────────────┐
│  フレームワーク＆ドライバ層                          │
│  (Web: Gin, Storage: Garage/OCI OSS, Queue:       │
│   Redis BullMQ/asynq or OCI Queue,                │
│   Transcode: FFmpeg + libheif)                    │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  インターフェースアダプタ層                        │
│  (HTTP Handler, Repository Impl,                  │
│   GarageStorageAdapter/OCIObjectStorageAdapter,   │
│   RedisBullMQAdapter/OCIQueueAdapter,             │
│   FFmpegHLSAdapter, LibheifImageAdapter)          │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  ユースケース層 (アプリケーション)                │
│  (UploadMediaSingle, InitChunkedUpload,           │
│   TranscodeVideoToHLS, ConvertHEICToOptimized,    │
│   HandleLivePhotoPair, ProcessMedia, DeliverMedia)│
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  エンティティ層 (ドメイン)                        │
│  (MediaFile, MediaChunk, ProcessingJob,           │
│   MediaStatus, MimeType, AccessPolicy)            │
└─────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール
- **内側への依存のみ**：Adapter → UseCase → Domain
- **外部ストレージはホスト扱い**：オブジェクトストレージはインフラ層（外側）、ドメインは依存しない
- **ポート経由アクセス**：オブジェクトストレージ 操作、Job Queue 制御はポート（インターフェース）経由

---

## 3. エンティティ層（ドメイン）

### 3.1 ドメインモデル

| エンティティ      | 説明                                                                                    |
| ----------------- | --------------------------------------------------------------------------------------- |
| **MediaFile**     | アップロードされたメディアファイルの中核：メタデータ、ストレージ位置、処理ステータス    |
| **MediaChunk**    | チャンク式アップロード時の分割データ：チャンクインデックス、オブジェクトストレージ 位置 |
| **ProcessingJob** | 非同期処理ジョブの追跡：メディア 変換、サムネイル生成                                   |

### 3.2 値オブジェクト

| 値オブジェクト   | 許可される値                                 | 制約             |
| ---------------- | -------------------------------------------- | ---------------- |
| **MediaStatus**  | UPLOADING, PROCESSING, READY, FAILED         | 遷移ルール有り   |
| **MimeType**     | image/jpeg, image/png, image/heic, video/mp4 | 許可リスト検証   |
| **StorageKey**   | Media path: `{org_id}/{media_id}/{type}`     | フォーマット検証 |
| **AccessPolicy** | PRIVATE, ORG_MEMBERS, EVENT_MEMBERS          | イミュータブル   |
| **DeliveryType** | original, optimized, thumb                   | 形式別配信       |

### 3.3 ドメインルール / 不変条件

- **Access Control Immutability**：access_policy は作成時に確定、変更不可
- **File Size Limits**：画像 max 100MB、動画 max 500MB（ドメイン層で検証）
- **HEIC Auto-Conversion**：HEIC→JPEG/WebP は libheif による自動変換、必須（ユーザー選択不可）
- **Video Auto-Conversion**：MP4→HLS（360p/720p/1080p, 6秒セグメント）は FFmpeg による自動変換、必須
- **Live Photo Pairing**：iOS Live Photo は HEIC + MOV を `asset_identifier` で同一ペアとして保存
- **Thumbnail Generation**：すべてのメディアが ≤1280px サムネイル生成
- **Chunk Expiry**：チャンク式アップロードは24時間で自動失効
- **FAILED Status Block**：FAILED ステータスはアクセス拒否、再アップロード必須
- **Only Uploader or Admin Can Delete**：削除権限は厳格（uploader か org admin のみ）

### 3.4 ドメインイベント

| イベント                  | トリガー                   | ペイロード                               | 購読者                          |
| ------------------------- | -------------------------- | ---------------------------------------- | ------------------------------- |
| **MediaUploaded**         | UploadMediaSingle 成功     | media_id, org_id, uploader_id, mime_type | Album Service (参照可能化)      |
| **MediaReady**            | ProcessMedia（最適化）完了 | media_id, storage_key, delivery_type     | Album Service, Timeline Service |
| **MediaProcessingFailed** | Queue job 失敗             | media_id, error_msg                      | Notification Service (通知)     |

### 3.5 エンティティ定義 (Go pseudocode)

```go
package domain

import (
    "time"
)

// MediaStatus メディアのライフサイクルステータス
type MediaStatus string

const (
    MediaStatusUploading   MediaStatus = "UPLOADING"   // アップロード中
    MediaStatusProcessing  MediaStatus = "PROCESSING"  // 処理中（HEIC→JPEG/WebP、HLSトランスコード、サムネイル生成）
    MediaStatusReady       MediaStatus = "READY"       // 配信可能
    MediaStatusFailed      MediaStatus = "FAILED"      // 処理失敗、アクセス不可
)

// MimeType メディアの MIME タイプ（ホワイトリスト）
type MimeType string

const (
    MimeTypeJPEG  MimeType = "image/jpeg"
    MimeTypePNG   MimeType = "image/png"
    MimeTypeHEIC  MimeType = "image/heic"
    MimeTypeMP4   MimeType = "video/mp4"
)

// IsImageType 画像タイプか判定
func (mt MimeType) IsImageType() bool {
    switch mt {
    case MimeTypeJPEG, MimeTypePNG, MimeTypeHEIC:
        return true
    default:
        return false
    }
}

// IsVideoType 動画タイプか判定
func (mt MimeType) IsVideoType() bool {
    return mt == MimeTypeMP4
}

// AccessPolicy ファイルのアクセス権レベル
type AccessPolicy string

const (
    AccessPolicyPrivate      AccessPolicy = "PRIVATE"       // 所有者のみ
    AccessPolicyOrgMembers   AccessPolicy = "ORG_MEMBERS"   // 組織メンバー
    AccessPolicyEventMembers AccessPolicy = "EVENT_MEMBERS" // イベント参加者
)

// StorageKey オブジェクトストレージ (Garage / OCI Object Storage) 格納位置を管理する値オブジェクト
type StorageKey struct {
    value string // org_id/media_id/type
}

func NewStorageKey(orgID, mediaID, storageType string) StorageKey {
    return StorageKey{
        value: fmt.Sprintf("%s/%s/%s", orgID, mediaID, storageType),
    }
}

func (sk StorageKey) String() string {
    return sk.value
}

// DeliveryType 配信時のファイルタイプ
type DeliveryType string

const (
    DeliveryTypeOriginal   DeliveryType = "original"   // 元のファイル
    DeliveryTypeOptimized  DeliveryType = "optimized"  // Web 最適化版（PNG 圧縮など）
    DeliveryTypeThumbnail  DeliveryType = "thumb"      // サムネイル
)

// MediaFile ドメインエンティティ
type MediaFile struct {
    ID               string
    OrgID            string
    UploaderID       string
    OriginalFilename string
    MimeType         MimeType
    FileSizeBytes    int64
    StorageKey       StorageKey           // raw/ フォルダ
    Status           MediaStatus
    AccessPolicy     AccessPolicy
    CreatedAt        time.Time
    UpdatedAt        time.Time
    domainEvents     []interface{}
}

// NewMediaFile ファクトリメソッド
func NewMediaFile(
    orgID, uploaderID, filename string,
    mimeType MimeType,
    fileSize int64,
    policy AccessPolicy,
) (*MediaFile, error) {
    // ファイルサイズ検証
    if !isValidFileSize(mimeType, fileSize) {
        return nil, fmt.Errorf("file size exceeds limit: %d bytes", fileSize)
    }
    
    // MIME タイプ検証
    if !isAllowedMimeType(mimeType) {
        return nil, fmt.Errorf("unsupported mime type: %s", mimeType)
    }
    
    mediaID := generateULID()
    
    mf := &MediaFile{
        ID:               mediaID,
        OrgID:            orgID,
        UploaderID:       uploaderID,
        OriginalFilename: filename,
        MimeType:         mimeType,
        FileSizeBytes:    fileSize,
        StorageKey:       NewStorageKey(orgID, mediaID, "raw"),
        Status:           MediaStatusUploading,
        AccessPolicy:     policy,
        CreatedAt:        time.Now(),
        UpdatedAt:        time.Now(),
    }
    
    mf.recordEvent(&MediaUploadedEvent{
        MediaID:    mediaID,
        OrgID:      orgID,
        UploaderID: uploaderID,
        MimeType:   string(mimeType),
        FileSize:   fileSize,
    })
    
    return mf, nil
}

// StartProcessing ステータス遷移：UPLOADING → PROCESSING
func (mf *MediaFile) StartProcessing() error {
    if mf.Status != MediaStatusUploading {
        return fmt.Errorf("only UPLOADING files can start processing")
    }
    mf.Status = MediaStatusProcessing
    mf.UpdatedAt = time.Now()
    return nil
}

// MarkReady 処理完了：PROCESSING → READY
func (mf *MediaFile) MarkReady(optimizedKey, thumbnailKey string) error {
    if mf.Status != MediaStatusProcessing {
        return fmt.Errorf("only PROCESSING files can be marked ready")
    }
    mf.Status = MediaStatusReady
    mf.UpdatedAt = time.Now()
    
    mf.recordEvent(&MediaReadyEvent{
        MediaID:       mf.ID,
        OrgID:         mf.OrgID,
        OptimizedKey:  optimizedKey,
        ThumbnailKey:  thumbnailKey,
    })
    return nil
}

// MarkFailed 処理失敗：→ FAILED
func (mf *MediaFile) MarkFailed(errorMsg string) error {
    mf.Status = MediaStatusFailed
    mf.UpdatedAt = time.Now()
    
    mf.recordEvent(&MediaProcessingFailedEvent{
        MediaID:   mf.ID,
        ErrorMsg:  errorMsg,
    })
    return nil
}

// IsReadyForDelivery 配信可能か
func (mf *MediaFile) IsReadyForDelivery() bool {
    return mf.Status == MediaStatusReady
}

// CanBeAccessedBy アクセス権チェック
func (mf *MediaFile) CanBeAccessedBy(userID string, isMember bool, isEventMember bool) bool {
    switch mf.AccessPolicy {
    case AccessPolicyPrivate:
        return mf.UploaderID == userID
    case AccessPolicyOrgMembers:
        return isMember
    case AccessPolicyEventMembers:
        return isEventMember
    default:
        return false
    }
}

// MediaChunk チャンク式アップロード用
type MediaChunk struct {
    ID          string
    MediaID     string
    ChunkIndex  int    // 0-based
    StorageKey  string // オブジェクトストレージ (Garage / OCI OSS) のキー
    SizeBytes   int64
    UploadedAt  time.Time
}

// NewMediaChunk チャンク作成
func NewMediaChunk(mediaID string, chunkIndex int, storageKey string, size int64) *MediaChunk {
    return &MediaChunk{
        ID:         generateULID(),
        MediaID:    mediaID,
        ChunkIndex: chunkIndex,
        StorageKey: storageKey,
        SizeBytes:  size,
        UploadedAt: time.Now(),
    }
}

// ProcessingJob 非同期処理ジョブ
type ProcessingJobType string

const (
    ProcessingJobTypeHEICConvert  ProcessingJobType = "HEIC_CONVERT"   // libheif で HEIC→JPEG/WebP
    ProcessingJobTypeHLSTranscode ProcessingJobType = "HLS_TRANSCODE"  // FFmpeg で 360p/720p/1080p, 6秒セグメント
    ProcessingJobTypeLivePhotoPair ProcessingJobType = "LIVE_PHOTO_PAIR" // HEIC+MOV を asset_identifier でペアリング
    ProcessingJobTypeThumbnailGen ProcessingJobType = "THUMBNAIL_GEN"
)

type ProcessingJobStatus string

const (
    ProcessingJobStatusPending ProcessingJobStatus = "PENDING"
    ProcessingJobStatusRunning ProcessingJobStatus = "RUNNING"
    ProcessingJobStatusDone    ProcessingJobStatus = "DONE"
    ProcessingJobStatusFailed  ProcessingJobStatus = "FAILED"
)

type ProcessingJob struct {
    ID        string
    MediaID   string
    JobType   ProcessingJobType
    Status    ProcessingJobStatus
    ErrorMsg  *string
    CreatedAt time.Time
    UpdatedAt time.Time
}

// NewProcessingJob ジョブ作成
func NewProcessingJob(mediaID string, jobType ProcessingJobType) *ProcessingJob {
    return &ProcessingJob{
        ID:        generateULID(),
        MediaID:   mediaID,
        JobType:   jobType,
        Status:    ProcessingJobStatusPending,
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }
}

// MarkDone ジョブ完了
func (pj *ProcessingJob) MarkDone() {
    pj.Status = ProcessingJobStatusDone
    pj.UpdatedAt = time.Now()
}

// MarkFailed ジョブ失敗
func (pj *ProcessingJob) MarkFailed(errMsg string) {
    pj.Status = ProcessingJobStatusFailed
    pj.ErrorMsg = &errMsg
    pj.UpdatedAt = time.Now()
}

// ドメインイベント
type MediaUploadedEvent struct {
    MediaID    string
    OrgID      string
    UploaderID string
    MimeType   string
    FileSize   int64
}

type MediaReadyEvent struct {
    MediaID      string
    OrgID        string
    OptimizedKey string
    ThumbnailKey string
}

type MediaProcessingFailedEvent struct {
    MediaID  string
    ErrorMsg string
}

// DomainEvents インターフェース
func (mf *MediaFile) DomainEvents() []interface{} {
    events := mf.domainEvents
    mf.domainEvents = []interface{}{}
    return events
}

func (mf *MediaFile) recordEvent(event interface{}) {
    mf.domainEvents = append(mf.domainEvents, event)
}
```

---

## 4. ユースケース層（アプリケーション）

### 4.1 ユースケース一覧

| ユースケース          | 説明                          | アクター              | 主成功シナリオ                                                               |
| --------------------- | ----------------------------- | --------------------- | ---------------------------------------------------------------------------- |
| **UploadMediaSingle** | 単一ファイルアップロード      | Org Member            | ファイル検証、オブジェクトストレージ保存、MediaFile 作成、処理ジョブ登録     |
| **InitChunkedUpload** | チャンク式アップロード初期化  | Org Member            | MediaFile 作成（UPLOADING）、チャンク情報返却                                |
| **UploadChunk**       | チャンク 1 個アップロード     | Org Member            | オブジェクトストレージ へのアップロード、MediaChunk 記録                     |
| **MergeChunks**       | チャンク統合＆処理開始        | Org Member            | 全チャンク確認、統合、processing job 登録                                    |
| **DeliverMedia**      | メディア配信（presigned URL） | Org Member            | アクセス権チェック、presigned URL 生成                                       |
| **DeleteMedia**       | メディア削除                  | Uploader or Org Admin | 権限チェック、オブジェクトストレージ 削除、DB レコード削除                   |
| **ProcessMedia**      | 非同期処理（Queue worker）    | Job Queue             | HEIC→JPEG/WebP 変換、HLS トランスコード、サムネイル生成、オブジェクトストレージ 保存 |
| **TranscodeVideoToHLS** | 動画を HLS マルチビットレートに変換 | Job Queue | FFmpeg で 360p/720p/1080p、6秒セグメント、マスタープレイリスト生成 |
| **ConvertHEICToOptimized** | HEIC を JPEG/WebP に変換 | Job Queue | libheif で HEIC デコード → JPEG/WebP エンコード |
| **HandleLivePhotoPair** | Live Photo の HEIC+MOV をペアリング | Job Queue | `asset_identifier` により同一 Live Photo として保存 |

### 4.2 ユースケース詳細 (UploadMediaSingle - main use case)

**Actor**: 組織メンバー

**Pre-conditions**:
- ユーザーが org に属する
- ファイルサイズ、MIME タイプ有効

**Main Flow**:
1. UploadMediaSingleRequest を受け取る（file body, mime_type, access_policy）
2. ファイルサイズ検証（100MB 以下の画像、500MB 以下の動画）
3. MIME タイプホワイトリスト検証
4. MediaFile.NewMediaFile() でドメインエンティティ構築
5. オブジェクトストレージ (Garage / OCI OSS) の `raw/` プレフィックスへ保存
6. MediaRepository.Save() で DB 保存
7. MIME に応じて ProcessingJob を作成:
   - 画像 (HEIC): `HEIC_CONVERT`, `THUMBNAIL_GEN`
   - 動画 (MP4): `HLS_TRANSCODE`, `THUMBNAIL_GEN`
   - Live Photo: `LIVE_PHOTO_PAIR`
8. QueuePort 経由でジョブ投入（Beta: Redis+BullMQ/asynq、Prod: OCI Queue）
9. MediaUploaded イベント発行 → Album Service
10. UploadMediaSingleResponse（media_id, status=UPLOADING）を返却

**Post-conditions**:
- MediaFile が DB に UPLOADING 状態で保存
- ファイルが オブジェクトストレージ raw/ フォルダに保存
- Processing Jobs が QueuePort 経由でキューに登録
- MediaUploaded イベント が QueuePort 経由で発行（Beta: Redis Pub/Sub or BullMQ、Prod: OCI Queue）

**Errors**:
- ファイルサイズ超過：`ErrFileTooLarge`
- MIME タイプ不支持：`ErrUnsupportedMimeType`
- オブジェクトストレージ 保存失敗：`ErrStorageFailed`（リトライ対象）
- 権限不足：`ErrUnauthorized`

### 4.3 入出力DTO (Go struct pseudocode)

```go
package application

// UploadMediaSingleRequest
type UploadMediaSingleRequest struct {
    FileBody     []byte // multipart form body
    OriginalName string
    MimeType     string
    FileSize     int64
    OrgID        string
    UploaderID   string
    AccessPolicy string // PRIVATE, ORG_MEMBERS, EVENT_MEMBERS
}

// UploadMediaSingleResponse
type UploadMediaSingleResponse struct {
    MediaID string    `json:"media_id"`
    Status  string    `json:"status"`
    OrgID   string    `json:"org_id"`
    SavedAt time.Time `json:"saved_at"`
}

// InitChunkedUploadRequest
type InitChunkedUploadRequest struct {
    OriginalName string `json:"original_name"`
    MimeType     string `json:"mime_type"`
    FileSizeBytes int64 `json:"file_size_bytes"`
    ChunkSizeBytes int64 `json:"chunk_size_bytes"` // 推奨 5MB
    OrgID        string `json:"org_id"`
    UploaderID   string `json:"uploader_id"`
    AccessPolicy string `json:"access_policy"`
}

// InitChunkedUploadResponse
type InitChunkedUploadResponse struct {
    MediaID         string `json:"media_id"`
    ChunkCount      int    `json:"chunk_count"`
    ChunkSizeBytes  int64  `json:"chunk_size_bytes"`
    ExpiresAt       time.Time `json:"expires_at"`
}

// UploadChunkRequest
type UploadChunkRequest struct {
    MediaID    string `json:"media_id"`
    ChunkIndex int    `json:"chunk_index"`
    ChunkBody  []byte // multipart form body
    ChunkSize  int64  `json:"chunk_size"`
}

// UploadChunkResponse
type UploadChunkResponse struct {
    MediaID    string `json:"media_id"`
    ChunkIndex int    `json:"chunk_index"`
    UploadedAt time.Time `json:"uploaded_at"`
}

// MergeChunksRequest
type MergeChunksRequest struct {
    MediaID string `json:"media_id"`
    OrgID   string `json:"org_id"`
}

// MergeChunksResponse
type MergeChunksResponse struct {
    MediaID string    `json:"media_id"`
    Status  string    `json:"status"` // PROCESSING
    JobID   string    `json:"job_id"`
}

// DeliverMediaRequest
type DeliverMediaRequest struct {
    MediaID      string `json:"media_id"`
    DeliveryType string `json:"delivery_type"` // original, optimized, thumb
    ViewerID     string `json:"viewer_id"`
}

// DeliverMediaResponse
type DeliverMediaResponse struct {
    PresignedURL string    `json:"presigned_url"`
    ExpiresAt    time.Time `json:"expires_at"`
}

// DeleteMediaRequest
type DeleteMediaRequest struct {
    MediaID  string `json:"media_id"`
    OrgID    string `json:"org_id"`
    RequestBy string `json:"request_by"` // user_id
}

// DeleteMediaResponse
type DeleteMediaResponse struct {
    MediaID   string    `json:"media_id"`
    DeletedAt time.Time `json:"deleted_at"`
}
```

### 4.4 リポジトリインターフェース（ポート）

```go
package application

import "context"

// MediaFileRepository MediaFile 永続化のポート
type MediaFileRepository interface {
    // Save メディアファイル保存
    Save(ctx context.Context, media *domain.MediaFile) error
    
    // FindByID ID で検索
    FindByID(ctx context.Context, mediaID string) (*domain.MediaFile, error)
    
    // ListByOrg 組織内メディア一覧
    ListByOrg(ctx context.Context, orgID string, limit, offset int) ([]*domain.MediaFile, int64, error)
    
    // Delete メディア削除
    Delete(ctx context.Context, mediaID string) error
    
    // Update メディア更新（ステータス変更など）
    Update(ctx context.Context, media *domain.MediaFile) error
}

// MediaChunkRepository チャンク永続化のポート
type MediaChunkRepository interface {
    // Save チャンク記録
    Save(ctx context.Context, chunk *domain.MediaChunk) error
    
    // ListByMedia メディアの全チャンク
    ListByMedia(ctx context.Context, mediaID string) ([]*domain.MediaChunk, error)
    
    // DeleteExpired 24時間以上経過したチャンク削除
    DeleteExpired(ctx context.Context) error
}

// ProcessingJobRepository ジョブ管理のポート
type ProcessingJobRepository interface {
    // Save ジョブ保存
    Save(ctx context.Context, job *domain.ProcessingJob) error
    
    // FindByID ジョブ検索
    FindByID(ctx context.Context, jobID string) (*domain.ProcessingJob, error)
    
    // ListPending ペンディングジョブ取得
    ListPending(ctx context.Context, limit int) ([]*domain.ProcessingJob, error)
    
    // Update ジョブ更新
    Update(ctx context.Context, job *domain.ProcessingJob) error
}
```

### 4.5 外部サービスインターフェース（ポート）

```go
package application

// StoragePort オブジェクトストレージ操作のポート（Beta: Garage / Prod: OCI Object Storage）
type StoragePort interface {
    // Upload ファイルをオブジェクトストレージに保存
    Upload(ctx context.Context, key string, data []byte) error
    
    // UploadStream ストリーム形式でアップロード（大容量対応）
    UploadStream(ctx context.Context, key string, reader io.Reader, size int64) error
    
    // Download オブジェクトストレージ からダウンロード
    Download(ctx context.Context, key string) ([]byte, error)
    
    // GeneratePresignedURL 署名付き URL 生成（配信用）
    GeneratePresignedURL(ctx context.Context, key string, expirySeconds int64) (string, error)
    
    // Delete オブジェクトストレージ からファイル削除
    Delete(ctx context.Context, key string) error
    
    // ListObjects キー プレフィックス配下のオブジェクト列挙
    ListObjects(ctx context.Context, prefix string) ([]string, error)
}

// MediaTranscoderPort メディア変換（画像・動画・Live Photo）のポート
// 実装:
//   - LibheifImageAdapter: HEIC → JPEG/WebP（libheif）
//   - FFmpegHLSAdapter: MP4 → HLS 360p/720p/1080p（FFmpeg, 6秒セグメント）
type MediaTranscoderPort interface {
    // ConvertHEICToOptimized HEIC を JPEG/WebP に変換（libheif）
    ConvertHEICToOptimized(ctx context.Context, heicBytes []byte, target ImageFormat) ([]byte, error)

    // GenerateThumbnail サムネイル生成（≤1280px）
    GenerateThumbnail(ctx context.Context, imageBytes []byte, maxWidth int) ([]byte, error)

    // OptimizeImage Web 用に最適化（圧縮、リサイズ）
    OptimizeImage(ctx context.Context, imageBytes []byte) ([]byte, error)

    // TranscodeVideoToHLS MP4 を HLS マルチビットレートに変換（360p/720p/1080p, 6s seg）
    TranscodeVideoToHLS(ctx context.Context, in TranscodeInput) (TranscodeOutput, error)

    // PairLivePhoto HEIC + MOV を asset_identifier でペアリング
    PairLivePhoto(ctx context.Context, heicKey, movKey, assetIdentifier string) error
}

// QueuePort 非同期ジョブキューのポート
// 実装:
//   - Beta: RedisBullMQAdapter / AsynqAdapter
//   - Prod: OCIQueueAdapter
type QueuePort interface {
    // Enqueue ジョブをキューに入れる
    Enqueue(ctx context.Context, queue string, payload []byte, opts ...EnqueueOption) error
}

// EventPublisher ドメインイベント発行のポート（QueuePort 上に実装）
type EventPublisher interface {
    // Publish ドメインイベント発行
    Publish(ctx context.Context, event interface{}) error
}
```

---

## 5. インターフェースアダプタ層

### 5.1 コントローラ / ハンドラ

| ハンドラ                     | HTTP Method | Path                           | 入力                     | 出力                      | 責務                               |
| ---------------------------- | ----------- | ------------------------------ | ------------------------ | ------------------------- | ---------------------------------- |
| **UploadMediaSingleHandler** | POST        | /api/media                     | multipart form           | UploadMediaSingleResponse | ファイル検証、ユースケース呼び出し |
| **InitChunkedUploadHandler** | POST        | /api/media/chunked/init        | InitChunkedUploadRequest | InitChunkedUploadResponse | チャンク数計算、MediaFile 初期化   |
| **UploadChunkHandler**       | PUT         | /api/media/chunks/{id}/{index} | multipart form           | UploadChunkResponse       | チャンク検証、オブジェクトストレージ アップロード |
| **MergeChunksHandler**       | POST        | /api/media/chunks/{id}/merge   | MergeChunksRequest       | MergeChunksResponse       | 全チャンク確認、統合ジョブ投入     |
| **DeliverMediaHandler**      | GET         | /api/media/{id}/download       | Query params             | Redirect or PresignedURL  | 権限チェック、URL 生成             |
| **DeleteMediaHandler**       | DELETE      | /api/media/{id}                | -                        | StatusResponse            | 権限チェック、オブジェクトストレージ + DB 削除 |

### 5.2 プレゼンター / レスポンスマッパー

```go
package adapter

// MediaPresenter ドメインモデル → HTTP レスポンス
type MediaPresenter struct{}

// PresentUploadResponse アップロード レスポンス
func (p *MediaPresenter) PresentUploadResponse(media *domain.MediaFile) *UploadMediaSingleResponse {
    return &UploadMediaSingleResponse{
        MediaID: media.ID,
        Status:  string(media.Status),
        OrgID:   media.OrgID,
        SavedAt: media.CreatedAt,
    }
}

// PresentDeliverResponse 配信レスポンス
func (p *MediaPresenter) PresentDeliverResponse(presignedURL string, expiryTime time.Time) *DeliverMediaResponse {
    return &DeliverMediaResponse{
        PresignedURL: presignedURL,
        ExpiresAt:    expiryTime,
    }
}

// PresentErrorResponse エラー応答
func PresentErrorResponse(err error) (statusCode int, body map[string]string) {
    if errors.Is(err, ErrFileTooLarge) {
        return http.StatusRequestEntityTooLarge, map[string]string{"error": "file_too_large"}
    }
    if errors.Is(err, ErrUnsupportedMimeType) {
        return http.StatusBadRequest, map[string]string{"error": "unsupported_mime_type"}
    }
    if errors.Is(err, ErrUnauthorized) {
        return http.StatusForbidden, map[string]string{"error": "unauthorized"}
    }
    return http.StatusInternalServerError, map[string]string{"error": "internal_error"}
}
```

### 5.3 リポジトリ実装（アダプタ）

| リポジトリ実装                   | 対象          | 技術                  | キャッシング                  |
| -------------------------------- | ------------- | --------------------- | ----------------------------- |
| **MySQLMediaFileRepository**     | MediaFile     | `database/sql` + sqlc | メタデータ → Redis (TTL 5min) |
| **MySQLMediaChunkRepository**    | MediaChunk    | `database/sql` + sqlc | なし（一時的）                |
| **MySQLProcessingJobRepository** | ProcessingJob | `database/sql` + sqlc | ペンディング → Redis set      |

### 5.4 外部サービスアダプタ

| アダプタ                      | ポート                | 環境 | 実装 / ライブラリ                          | エラーハンドリング              |
| ----------------------------- | --------------------- | ---- | ------------------------------------------ | ------------------------------- |
| **GarageStorageAdapter**      | `StoragePort`         | Beta | Garage（S3互換OSS）+ AWS SDK for Go (S3API) | 5xx 時 3回リトライ             |
| **OCIObjectStorageAdapter**   | `StoragePort`         | Prod | OCI Go SDK `objectstorage`                  | 5xx 時 3回リトライ             |
| **LibheifImageAdapter**       | `MediaTranscoderPort` | 両方 | libheif (C lib) via cgo                     | 処理失敗 → job FAILED           |
| **FFmpegHLSAdapter**          | `MediaTranscoderPort` | 両方 | FFmpeg CLI（360p/720p/1080p, 6s seg）      | 処理失敗 → job FAILED           |
| **RedisBullMQAdapter**        | `QueuePort`           | Beta | `github.com/hibiken/asynq` または BullMQ    | リトライ 3回、max backoff 1hour |
| **OCIQueueAdapter**           | `QueuePort`           | Prod | OCI Queue Service SDK                       | リトライ 3回、DLQ 送信          |

> **削除済み**: `S3Adapter`、`MinioAdapter`、`SQSAdapter`、`SNSAdapter`、`ImageMagickProcessor` はポリシーにより使用しない。

### 5.5 マッパー

```go
package adapter

// MediaFileMapper DB ↔ ドメイン
type MediaFileMapper struct{}

// ToEntity SQL 結果 → ドメイン MediaFile
func (m *MediaFileMapper) ToEntity(row *MediaFileRow) (*domain.MediaFile, error) {
    storageKey := domain.NewStorageKey(row.OrgID, row.ID, "raw")
    
    return &domain.MediaFile{
        ID:               row.ID,
        OrgID:            row.OrgID,
        UploaderID:       row.UploaderID,
        OriginalFilename: row.OriginalFilename,
        MimeType:         domain.MimeType(row.MimeType),
        FileSizeBytes:    row.FileSizeBytes,
        StorageKey:       storageKey,
        Status:           domain.MediaStatus(row.Status),
        AccessPolicy:     domain.AccessPolicy(row.AccessPolicy),
        CreatedAt:        row.CreatedAt,
        UpdatedAt:        row.UpdatedAt,
    }, nil
}

// ToPersistence ドメイン MediaFile → DB 挿入
func (m *MediaFileMapper) ToPersistence(media *domain.MediaFile) *MediaFileRow {
    return &MediaFileRow{
        ID:               media.ID,
        OrgID:            media.OrgID,
        UploaderID:       media.UploaderID,
        OriginalFilename: media.OriginalFilename,
        MimeType:         string(media.MimeType),
        FileSizeBytes:    media.FileSizeBytes,
        StorageKey:       media.StorageKey.String(),
        Status:           string(media.Status),
        AccessPolicy:     string(media.AccessPolicy),
        CreatedAt:        media.CreatedAt,
        UpdatedAt:        media.UpdatedAt,
    }
}
```

---

## 6. フレームワーク＆ドライバ層（インフラストラクチャ）

### 6.1 Webフレームワーク
- **フレームワーク**: Gin v1.10
- **ポート**: 8004
- **ベースパス**: `/api/media`
- **ミドルウェア**: CORS, Auth Token 検証, Request ID, Multipart Size Limit (510MB), Logging

### 6.2 データベース (MySQL 8.x / MariaDB 互換)

> **互換性方針**: Beta は MySQL 8.x（MariaDB 10.6+ と互換）、Prod は OCI MySQL HeatWave。以下の SQL は
> PostgreSQL 固有記法（`TIMESTAMP WITH TIME ZONE`、`JSONB`、`INET`、`gen_random_uuid()`、`PARTITION OF`）を
> 用いず、MySQL/MariaDB 共通の `DATETIME`、`JSON`、`VARCHAR(45)`（IPv4/IPv6 最大長）、`UUID()` または
> アプリ層生成 ULID を採用する。`CHECK` 制約は MariaDB 10.2+ / MySQL 8 で有効。


```sql
-- media_files テーブル
CREATE TABLE IF NOT EXISTS media_files (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL,
    uploader_id TEXT NOT NULL,
    original_filename TEXT NOT NULL,
    mime_type VARCHAR(50) NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/heic', 'video/mp4')),
    file_size_bytes BIGINT NOT NULL CHECK (file_size_bytes > 0),
    storage_key TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'UPLOADING' CHECK (status IN ('UPLOADING', 'PROCESSING', 'READY', 'FAILED')),
    access_policy VARCHAR(20) NOT NULL CHECK (access_policy IN ('PRIVATE', 'ORG_MEMBERS', 'EVENT_MEMBERS')),
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE,
    FOREIGN KEY (uploader_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX idx_media_files_org_id ON media_files(org_id, created_at DESC);
CREATE INDEX idx_media_files_uploader_id ON media_files(uploader_id, created_at DESC);
CREATE INDEX idx_media_files_status ON media_files(status);

-- media_chunks テーブル（チャンク式アップロード用）
CREATE TABLE IF NOT EXISTS media_chunks (
    id TEXT PRIMARY KEY,
    media_id TEXT NOT NULL,
    chunk_index INT NOT NULL,
    storage_key TEXT NOT NULL,
    size_bytes BIGINT NOT NULL,
    uploaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT media_chunks_media_index_unique UNIQUE (media_id, chunk_index),
    FOREIGN KEY (media_id) REFERENCES media_files(id) ON DELETE CASCADE
);

CREATE INDEX idx_media_chunks_media_id ON media_chunks(media_id);
CREATE INDEX idx_media_chunks_uploaded_at ON media_chunks(uploaded_at);

-- processing_jobs テーブル
CREATE TABLE IF NOT EXISTS processing_jobs (
    id TEXT PRIMARY KEY,
    media_id TEXT NOT NULL,
    job_type VARCHAR(30) NOT NULL CHECK (job_type IN ('HEIC_CONVERT', 'HLS_TRANSCODE', 'LIVE_PHOTO_PAIR', 'THUMBNAIL_GEN')),
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'RUNNING', 'DONE', 'FAILED')),
    error_msg TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (media_id) REFERENCES media_files(id) ON DELETE CASCADE
);

CREATE INDEX idx_processing_jobs_media_id ON processing_jobs(media_id);
CREATE INDEX idx_processing_jobs_status ON processing_jobs(status);
CREATE INDEX idx_processing_jobs_created_at ON processing_jobs(created_at);
```

### 6.3 メッセージブローカー

Beta / Prod ともに `QueuePort` 経由。環境別に以下のアダプタを差し替える:

| 環境 | アダプタ                 | 実装                                   |
| ---- | ------------------------ | -------------------------------------- |
| Beta | `RedisBullMQAdapter`     | Redis + BullMQ / asynq（self-hosted）  |
| Prod | `OCIQueueAdapter`        | OCI Queue Service                      |

- **Job Queue 設定**:
  - Queue: `default` (high priority: HEIC_CONVERT / HLS_TRANSCODE), `thumbnail` (lower priority)
  - Retry: 3回、Max backoff 1 hour、DLQ 送信
  - TTL: 24時間
- **Event Publishing** (QueuePort 上のトピック/チャネル):
  - Message: `MediaUploaded`, `MediaReady`, `MediaProcessingFailed`
  - Consumers: Album Service, Timeline Service, Notification Service
- **AWS SQS / SNS は使用しない**（ポリシー）。

### 6.4 外部ライブラリ＆SDK

| ライブラリ                      | 用途                          | バージョン |
| ------------------------------- | ----------------------------- | ---------- |
| `github.com/gin-gonic/gin`                   | Web フレームワーク                       | v1.10  |
| `github.com/go-sql-driver/mysql`             | MySQL / MariaDB ドライバ                 | v1.8   |
| `github.com/redis/go-redis/v9`               | Redis クライアント                       | v9.3   |
| `github.com/hibiken/asynq`                   | Job Queue (Beta, Redis-backed)           | v10.5  |
| `github.com/oracle/oci-go-sdk/v65`           | OCI Queue / Object Storage SDK (Prod)    | v65    |
| `github.com/aws/aws-sdk-go-v2/service/s3`    | S3 API クライアント (Garage 用)          | v1.x   |
| `github.com/strukturag/libheif` (cgo bind)   | HEIC → JPEG/WebP 変換 (libheif)          | v1.17+ |
| FFmpeg CLI（システムバイナリ）               | HLS トランスコード (360p/720p/1080p, 6s) | v6+    |
| `github.com/oklog/ulid/v2`                   | ULID 生成                                | v2.1   |

### 6.5 依存性注入 (uber-go/fx code example)

```go
package infra

import (
    "go.uber.org/fx"
    "github.com/gin-gonic/gin"
    "github.com/lib/pq"
    "database/sql"
)

// Module Storage Service fx Module
func Module() fx.Option {
    return fx.Module("storage-service",
        // インフラプロバイダ
        fx.Provide(
            provideMySQLDB,
            provideRedisClient,
            provideObjectStorageClient,   // Beta: Garage (S3-compatible) / Prod: OCI OSS
            provideQueueClient,           // Beta: Redis / Prod: OCI Queue
            provideGinEngine,
        ),
        // 外部サービスプロバイダ（ポート → アダプタ）
        fx.Provide(
            // StoragePort
            func(cfg *config.StorageConfig, s3c ObjectStorageClient) application.StoragePort {
                switch cfg.Provider {
                case "garage":
                    return adapter.NewGarageStorageAdapter(s3c, cfg.Bucket)
                case "oci-oss":
                    return adapter.NewOCIObjectStorageAdapter(s3c, cfg.Bucket)
                default:
                    panic("unsupported storage.provider: " + cfg.Provider)
                }
            },
            // MediaTranscoderPort
            func() application.MediaTranscoderPort {
                return adapter.NewCompositeTranscoder(
                    adapter.NewLibheifImageAdapter(),
                    adapter.NewFFmpegHLSAdapter(),
                )
            },
            // QueuePort
            func(cfg *config.QueueConfig, redis *redis.Client, ociQ OCIQueueClient) application.QueuePort {
                switch cfg.Provider {
                case "redis-bullmq":
                    return adapter.NewRedisBullMQAdapter(redis)
                case "oci-queue":
                    return adapter.NewOCIQueueAdapter(ociQ)
                default:
                    panic("unsupported queue.provider: " + cfg.Provider)
                }
            },
        ),
        // リポジトリプロバイダ
        fx.Provide(
            func(db *sql.DB) adapter.MediaFileRepository {
                return adapter.NewMySQLMediaFileRepository(db)
            },
            func(db *sql.DB) adapter.MediaChunkRepository {
                return adapter.NewMySQLMediaChunkRepository(db)
            },
            func(db *sql.DB) adapter.ProcessingJobRepository {
                return adapter.NewMySQLProcessingJobRepository(db)
            },
        ),
        // ユースケース
        fx.Provide(
            func(
                mediaRepo adapter.MediaFileRepository,
                storage application.StoragePort,
                jobQueue application.QueuePort,
                emitter application.EventPublisher,
            ) application.UploadMediaSingleUseCase {
                return application.NewUploadMediaSingleUseCase(mediaRepo, storage, jobQueue, emitter)
            },
            func(
                mediaRepo adapter.MediaFileRepository,
                chunkRepo adapter.MediaChunkRepository,
                jobRepo adapter.ProcessingJobRepository,
                storage application.StoragePort,
                transcoder application.MediaTranscoderPort,
                jobQueue application.QueuePort,
            ) application.ProcessMediaUseCase {
                return application.NewProcessMediaUseCase(mediaRepo, chunkRepo, jobRepo, storage, transcoder, jobQueue)
            },
            // その他のユースケース...
        ),
        // ハンドラ登録
        fx.Invoke(registerHandlers),
    )
}

func provideMySQLDB(cfg *config.DatabaseConfig) (*sql.DB, error) {
    // MySQL 8.x / MariaDB 互換 DSN
    dsn := fmt.Sprintf(
        "%s:%s@tcp(%s:%d)/%s?parseTime=true&tls=%s",
        cfg.User, cfg.Password, cfg.Host, cfg.Port, cfg.Database, cfg.TLSMode,
    )
    return sql.Open("mysql", dsn)
}

func provideRedisClient(cfg *config.RedisConfig) *redis.Client {
    return redis.NewClient(&redis.Options{
        Addr: cfg.Address,
    })
}

// provideObjectStorageClient は Beta (Garage) では AWS S3 互換クライアント、
// Prod (OCI Object Storage) では OCI Go SDK クライアントを返す
func provideObjectStorageClient(cfg *config.StorageConfig) ObjectStorageClient {
    switch cfg.Provider {
    case "garage":
        // Garage は S3 互換 API、AWS SDK for Go v2 を流用
        return adapter.NewS3CompatibleClient(cfg.Endpoint, cfg.AccessKey, cfg.SecretKey, cfg.Region)
    case "oci-oss":
        return adapter.NewOCIObjectStorageClient(cfg.OCITenancy, cfg.OCINamespace, cfg.OCIRegion)
    default:
        panic("unsupported storage.provider: " + cfg.Provider)
    }
}

// provideQueueClient は Beta で Redis、Prod で OCI Queue クライアントを返す
func provideQueueClient(cfg *config.QueueConfig, redis *redis.Client) QueueClient {
    switch cfg.Provider {
    case "redis-bullmq":
        return adapter.NewRedisQueueClient(redis)
    case "oci-queue":
        return adapter.NewOCIQueueClient(cfg.OCIQueueOCID, cfg.OCIRegion)
    default:
        panic("unsupported queue.provider: " + cfg.Provider)
    }
}

func provideGinEngine() *gin.Engine {
    engine := gin.New()
    engine.Use(gin.Recovery())
    // Multipart size limit: 510MB (image 100MB + video 500MB + overhead)
    engine.MaxMultipartMemory = 510 << 20
    return engine
}

func registerHandlers(
    engine *gin.Engine,
    uploadSingleUC application.UploadMediaSingleUseCase,
    deliverUC application.DeliverMediaUseCase,
    deleteUC application.DeleteMediaUseCase,
) {
    api := engine.Group("/api/media")
    {
        api.POST("", func(c *gin.Context) {
            handler := adapter.NewUploadMediaSingleHandler(uploadSingleUC)
            handler.Handle(c)
        })
        api.GET("/:id/download", func(c *gin.Context) {
            handler := adapter.NewDeliverMediaHandler(deliverUC)
            handler.Handle(c)
        })
        api.DELETE("/:id", func(c *gin.Context) {
            handler := adapter.NewDeleteMediaHandler(deleteUC)
            handler.Handle(c)
        })
    }
}
```

---

## 7. ディレクトリ構成

```
recuerdo-storage-svc/
├── cmd/
│   ├── main.go                 # HTTP サーバー起動
│   └── worker/
│       └── main.go             # Queue 処理ワーカー (Beta: asynq/BullMQ, Prod: OCI Queue)
├── internal/
│   ├── domain/
│   │   ├── media_file.go       # MediaFile エンティティ
│   │   ├── media_chunk.go      # MediaChunk エンティティ
│   │   ├── processing_job.go   # ProcessingJob エンティティ
│   │   ├── value_objects.go    # MediaStatus, MimeType, AccessPolicy など
│   │   └── events.go           # ドメインイベント
│   ├── application/
│   │   ├── dto.go
│   │   ├── ports.go
│   │   ├── upload_media_single.go
│   │   ├── init_chunked_upload.go
│   │   ├── upload_chunk.go
│   │   ├── merge_chunks.go
│   │   ├── deliver_media.go
│   │   ├── delete_media.go
│   │   └── process_media.go    # 非同期処理ユースケース
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── upload_handler.go
│   │   │   ├── chunked_init_handler.go
│   │   │   ├── upload_chunk_handler.go
│   │   │   ├── merge_chunks_handler.go
│   │   │   ├── deliver_handler.go
│   │   │   └── delete_handler.go
│   │   ├── persistence/
│   │   │   ├── MySQL_media_file_repo.go
│   │   │   ├── MySQL_media_chunk_repo.go
│   │   │   └── MySQL_processing_job_repo.go
│   │   ├── external/
│   │   │   ├── s3_storage.go
│   │   │   ├── imagemagick_processor.go
│   │   │   ├── redis_bullmq_adapter.go    # Beta
│   │   │   └── oci_queue_adapter.go       # Prod
│   │   ├── worker/
│   │   │   └── processing_task_handler.go  # Queue worker task handler
│   │   ├── presenter.go
│   │   └── mapper.go
│   └── infra/
│       ├── config.go
│       ├── database.go
│       ├── redis.go
│       ├── s3.go
│       ├── fx_module.go
│       └── migrations/
│           └── 001_create_media_tables.sql
├── test/
│   ├── integration/
│   │   ├── upload_single_test.go
│   │   └── chunked_upload_test.go
│   └── unit/
│       ├── domain/
│       │   ├── media_file_test.go
│       │   └── media_chunk_test.go
│       └── application/
│           └── upload_media_usecase_test.go
├── go.mod
├── go.sum
├── Dockerfile
└── README.md
```

---

## 8. 依存性ルールと境界

### 8.1 許可される依存関係

| レイヤー                       | 依存可能な対象   | 例                                          |
| ------------------------------ | ---------------- | ------------------------------------------- |
| **フレームワーク＆ドライバ層** | すべて下位       | HTTP Handler → UseCase → Domain             |
| **インターフェースアダプタ層** | ユースケース以下 | Storage Adapter → UseCase → Domain          |
| **ユースケース層**             | ドメイン層のみ   | UploadMediaSingleUseCase → domain.MediaFile |
| **ドメイン層**                 | なし             | 自己完結                                    |

### 8.2 境界の横断
- **ポート経由**：UseCase → StorageService, ImageProcessingService
- **DTO 経由**：HTTP Request → DTO → UseCase → Domain
- **イベント駆動**：ドメインイベント → EventPublisher → QueuePort（Beta: Redis, Prod: OCI Queue）

### 8.3 ルールの強制
- **コンパイル時**：Go 型チェック
- **実行時**：linter (golangci-lint)
- **レビュー時**：コードレビュー

---

## 9. テスト戦略

### 9.1 テストピラミッド

| テストタイプ         | 割合 | 対象                               | ツール                       |
| -------------------- | ---- | ---------------------------------- | ---------------------------- |
| **ユニットテスト**   | 70%  | ドメイン、ユースケース（Mock）     | `testing` + `testify`        |
| **統合テスト**       | 20%  | Handler + UseCase + Repo + Storage Mock | `testcontainers-go`, Garage コンテナ |
| **エンドツーエンド** | 10%  | 全フロー（Garage / Redis Queue 含む）   | docker-compose, API テスト   |

### 9.2 テスト例 (Go test code)

```go
package domain_test

import (
    "testing"
    "github.com/stretchr/testify/assert"
    "storage-svc/internal/domain"
)

func TestNewMediaFile_Success(t *testing.T) {
    // Arrange
    mimeType := domain.MimeTypeJPEG
    
    // Act
    media, err := domain.NewMediaFile(
        "org-123",
        "user-456",
        "photo.jpg",
        mimeType,
        50_000_000, // 50MB
        domain.AccessPolicyPrivate,
    )
    
    // Assert
    assert.NoError(t, err)
    assert.Equal(t, domain.MediaStatusUploading, media.Status)
    assert.Equal(t, domain.AccessPolicyPrivate, media.AccessPolicy)
    assert.Len(t, media.DomainEvents(), 1)
}

func TestNewMediaFile_FileTooLarge(t *testing.T) {
    // 画像が 100MB を超える場合
    _, err := domain.NewMediaFile(
        "org-123",
        "user-456",
        "huge.jpg",
        domain.MimeTypeJPEG,
        200_000_000, // 200MB
        domain.AccessPolicyPrivate,
    )
    
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "file size exceeds limit")
}

func TestMediaFile_CanBeAccessedBy(t *testing.T) {
    media, _ := domain.NewMediaFile(
        "org-123",
        "user-456",
        "photo.jpg",
        domain.MimeTypeJPEG,
        10_000_000,
        domain.AccessPolicyOrgMembers,
    )
    
    tests := []struct {
        name          string
        userID        string
        isMember      bool
        isEventMember bool
        expected      bool
    }{
        {
            name:     "Uploader can access PRIVATE",
            userID:   "user-456",
            isMember: false,
            expected: true,
        },
        {
            name:     "Other member can access ORG_MEMBERS",
            userID:   "user-789",
            isMember: true,
            expected: true,
        },
        {
            name:     "Non-member cannot access ORG_MEMBERS",
            userID:   "user-999",
            isMember: false,
            expected: false,
        },
    }
    
    // Policy を ORG_MEMBERS に更新して再テスト
    media.AccessPolicy = domain.AccessPolicyOrgMembers
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result := media.CanBeAccessedBy(tt.userID, tt.isMember, tt.isEventMember)
            assert.Equal(t, tt.expected, result)
        })
    }
}

// 統合テスト
package application_test

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "storage-svc/internal/application"
    "storage-svc/internal/adapter"
)

func TestUploadMediaSingleUseCase_Integration(t *testing.T) {
    ctx := context.Background()
    
    // Setup: MySQL (MariaDB 互換), Garage (ローカル), Redis Queue
    db, cleanup := setupTestDB(t)
    defer cleanup()
    
    s3Mock := &mockStorageService{}
    jobQueueMock := &mockJobQueue{}
    mediaRepo := adapter.NewMySQLMediaFileRepository(db)
    emitterMock := &mockEventEmitter{}
    
    uc := application.NewUploadMediaSingleUseCase(mediaRepo, s3Mock, jobQueueMock, emitterMock)
    
    // Act
    resp, err := uc.Execute(ctx, &application.UploadMediaSingleRequest{
        FileBody:     []byte("fake jpeg data"),
        OriginalName: "photo.jpg",
        MimeType:     "image/jpeg",
        FileSize:     1_000_000,
        OrgID:        "org-123",
        UploaderID:   "user-456",
        AccessPolicy: "PRIVATE",
    })
    
    // Assert
    assert.NoError(t, err)
    assert.NotEmpty(t, resp.MediaID)
    assert.Equal(t, "UPLOADING", resp.Status)
    
    // オブジェクトストレージにアップロードされたか確認
    assert.Equal(t, 1, s3Mock.uploadCount)
    
    // Queue にジョブが投入されたか確認
    assert.Equal(t, 2, jobQueueMock.enqueueCount) // HEIC_CONVERT + THUMBNAIL_GEN (不要な場合は 1)
    
    // イベントが発行されたか確認
    assert.Equal(t, 1, emitterMock.publishCount)
}

// Mock 実装
type mockStorageService struct {
    uploadCount int
}

func (m *mockStorageService) Upload(ctx context.Context, key string, data []byte) error {
    m.uploadCount++
    return nil
}

func (m *mockStorageService) UploadStream(ctx context.Context, key string, reader io.Reader, size int64) error {
    return nil
}

func (m *mockStorageService) Download(ctx context.Context, key string) ([]byte, error) {
    return []byte{}, nil
}

func (m *mockStorageService) GeneratePresignedURL(ctx context.Context, key string, expirySeconds int64) (string, error) {
    return "https://fake-presigned.url", nil
}

func (m *mockStorageService) Delete(ctx context.Context, key string) error {
    return nil
}

func (m *mockStorageService) ListObjects(ctx context.Context, prefix string) ([]string, error) {
    return []string{}, nil
}

type mockJobQueue struct {
    enqueueCount int
}

func (m *mockQueue) Enqueue(ctx context.Context, queue string, payload []byte, opts ...application.EnqueueOption) error {
    m.enqueueCount++
    return nil
}
```

---

## 10. エラーハンドリング

### 10.1 ドメインエラー

```go
package domain

var (
    ErrFileTooLarge          = errors.New("file size exceeds limit")
    ErrUnsupportedMimeType   = errors.New("unsupported mime type")
    ErrInvalidAccessPolicy   = errors.New("invalid access policy")
    ErrInvalidStatus         = errors.New("invalid status transition")
    ErrAlreadyProcessing     = errors.New("already processing")
)
```

### 10.2 アプリケーションエラー

```go
package application

var (
    ErrMediaNotFound         = errors.New("media not found")
    ErrUnauthorizedUpload    = errors.New("not authorized to upload")
    ErrUnauthorizedDelete    = errors.New("not authorized to delete")
    ErrStorageFailed         = errors.New("storage operation failed")
    ErrProcessingFailed      = errors.New("processing failed")
    ErrInvalidChunk          = errors.New("invalid chunk")
    ErrChunkMissing          = errors.New("chunk missing")
)
```

### 10.3 エラー変換 (HTTP mapping table)

| エラー                   | HTTP ステータス           | レスポンス                           |
| ------------------------ | ------------------------- | ------------------------------------ |
| `ErrFileTooLarge`        | 413 Payload Too Large     | `{"error": "file_too_large"}`        |
| `ErrUnsupportedMimeType` | 400 Bad Request           | `{"error": "unsupported_mime_type"}` |
| `ErrUnauthorizedUpload`  | 403 Forbidden             | `{"error": "unauthorized"}`          |
| `ErrMediaNotFound`       | 404 Not Found             | `{"error": "not_found"}`             |
| `ErrStorageFailed`       | 500 Internal Server Error | `{"error": "storage_failed"}`        |

---

## 11. 横断的関心事

### 11.1 ロギング
- **ライブラリ**: `go.uber.org/zap`
- **レベル**: DEBUG, INFO, WARN, ERROR
- **ログ対象**: ファイルアップロード、処理開始/完了、オブジェクトストレージ 操作、権限チェック、エラー
- **フォーマット**: JSON

### 11.2 認証・認可
- **認証**: JWT トークン（Authorization ヘッダ）
- **認可**: Permission Service 呼び出しで権限チェック（削除時）
- **ポリシー**: アップロード時は org 内のみ、削除は uploader か org admin のみ

### 11.3 バリデーション
- **入力**: Handler でファイルサイズ、MIME タイプ検証
- **ドメイン**: MediaFile.NewMediaFile() で詳細バリデーション
- **ビジネス**: ユースケース層で DB 照合（重複チェック）

### 11.4 キャッシング
- **層**: Redis
- **キー**: `media:{mediaID}:metadata`, `media:{orgID}:list`
- **TTL**: メタデータ 5分、リスト 2分
- **無効化**: ファイル更新・削除時に明示削除

---

## 12. マイグレーション計画

### 12.1 現状
- モノリシック内のメディア管理（オブジェクトストレージ 保存のみ）
- 形式変換、サムネイル生成なし（クライアント側実装）
- アクセス制御が不十分

### 12.2 目標状態
- 独立した Storage Service
- 完全な処理パイプライン（HEIC→JPEG/WebP 変換、HLS トランスコード、Live Photo ペアリング、サムネイル生成）
- 細粒度なアクセス制御（PRIVATE/ORG_MEMBERS/EVENT_MEMBERS）
- チャンク式アップロード対応、高スケーラビリティ

### 12.3 マイグレーション手順

| フェーズ                                | 実施内容                                         | 期間  | 依存関係  |
| --------------------------------------- | ------------------------------------------------ | ----- | --------- |
| **1. インフラ準備**                     | MySQL(MariaDB互換) テーブル作成、Garage/OCI OSS バケット構成、Queue setup | 1週間 | なし      |
| **2. コア実装**                         | ドメイン層、ユースケース、リポジトリ             | 2週間 | フェーズ1 |
| **3. HTTP インターフェース**            | Handler、Presenter、マッピング                   | 1週間 | フェーズ2 |
| **4. 処理パイプライン**                 | HEIC→JPEG/WebP、HLS トランスコード、サムネイル生成、Queue worker | 1週間 | フェーズ3 |
| **5. テスト**                           | 統合・E2E テスト、パフォーマンステスト           | 1週間 | フェーズ4 |
| **6. デプロイ・データマイグレーション** | 本番へのロールアウト、既存メディア移行           | 1週間 | フェーズ5 |

---

## 13. 未決事項と決定事項

| 項目                         | 現在の決定               | 状態     | 備考                                                   |
| ---------------------------- | ------------------------ | -------- | ------------------------------------------------------ |
| **HEIC 自動変換**            | 必須（ユーザー選択不可） | 決定済み | Web 互換性のため libheif で JPEG/WebP に変換           |
| **Live Photo**               | asset_identifier でペアリング | 決定済み | iOS の HEIC+MOV を同一 Live Photo として保存     |
| **HLS トランスコード**       | 360p/720p/1080p, 6秒セグ | 決定済み | FFmpeg でマスタープレイリスト生成                      |
| **ハイライトビデオ**         | ユーザー指定のみ         | 決定済み | ML による自動生成や推薦は行わない                      |
| **サムネイルサイズ**         | max 1280px               | 決定済み | モバイル・デスクトップ両対応                           |
| **チャンク有効期限**         | 24時間                   | 決定済み | 十分な時間を提供しつつ DB クリーンアップ               |
| **Presigned URL 有効期限**   | 1時間                    | 決定済み | セキュリティと UX のバランス                           |
| **ファイル削除戦略**         | 物理削除                 | 決定済み | 監査証跡は別途ログで担保                               |
| **CDN キャッシング**         | Beta: self-hosted CDN / Prod: OCI CDN | 決定済み | CloudFront は利用しない。presigned URL で cache key 分離 |
| **動画トランスコーディング** | 実装                     | 決定済み | HLSやMPEG-DASHとしてプログレッシブ再生できるようにする |

---

## 14. 参考資料

- **Clean Architecture**: Robert C. Martin, "Clean Architecture"
- **Garage (OSS S3互換 Object Storage)**: `https://garagehq.deuxfleurs.fr/`
- **OCI Object Storage**: `https://docs.oracle.com/iaas/Content/Object/home.htm`
- **FFmpeg HLS Segmentation**: `https://ffmpeg.org/ffmpeg-formats.html#hls-2`
- **libheif (HEIC デコード)**: `https://github.com/strukturag/libheif`
- **MariaDB / MySQL Docs**: `https://mariadb.com/kb/en/documentation/` / `https://dev.mysql.com/doc/`
- **OCI Queue Service**: `https://docs.oracle.com/iaas/Content/queue/home.htm`
- **asynq Job Queue (Beta)**: `https://github.com/hibiken/asynq`
- **BullMQ (Beta)**: `https://docs.bullmq.io/`
- **Go Multipart Upload**: `https://golang.org/pkg/mime/multipart/`
- **Gin Framework**: `https://github.com/gin-gonic/gin`

---

**最終更新: 2026-04-19 ポリシー適用**
