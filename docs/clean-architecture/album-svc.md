# クリーンアーキテクチャ設計書

| 項目                      | 値                                    |
| ------------------------- | ------------------------------------- |
| **モジュール/サービス名** | AlbumApp Service (recuerdo-album-svc) |
| **作成者**                | Akira                                 |
| **作成日**                | 2026-04-13                            |
| **ステータス**            | ドラフト                              |
| **バージョン**            | 1.0                                   |

---

## 1. 概要
### 1.1 目的
AlbumApp Service は、Recerdo プラットフォーム内で、イベントに紐付いたアルバム（写真・ビデオ集約）、メディアアソシエーション（Storage Service への参照）、ハイライトビデオ自動生成を管理します。ユーザ間でイベント時の思い出を共有、保存、キュレーションするための中核機能を提供し、メディアアップロード後の自動化処理（ハイライト生成）をサポートします。

### 1.2 ビジネスコンテキスト
- **主要ユースケース**: アルバム作成・閲覧、メディア追加・削除、コメント、ハイライトビデオ自動生成
- **API 基本パス**: `/api/orgs/{org_id}/albums`, `/api/orgs/{org_id}/events/{event_id}/album`
- **イベント依存**: Event Service からイベント情報取得、削除時カスケード処理
- **メディア依存**: Storage Service（メディア メタデータ、URL 生成）
- **権限依存**: Permission Service（org/event/album アクセス制御）
- **非同期処理**: asynq で ≥10 メディア時ハイライト生成
- **イベント発行**: SQS → Timeline Service, Notification Service
- **キャッシング**: Redis（5分 TTL、アルバムメディアリスト）

### 1.3 アーキテクチャ原則
1. **ドメイン駆動設計**: アルバムライフサイクル（作成、メディア追加、アーカイブ）をエンティティで表現
2. **イベント駆動**: ドメインイベント（AlbumCreated, MediaAdded）発行 → 外部サービス非同期処理
3. **依存性逆転**: リポジトリ、外部サービス参照はポート (インターフェース) 経由
4. **責任の分離**: エンティティ = ドメインルール、ユースケース = ビジネスロジック
5. **キャッシュ戦略**: 読み取り頻出データ（メディアリスト）は Redis キャッシュ
6. **レーティング戦略**: 頻出回数だけでなく、お気に入りや重要写真（集合写真・ランドマーク写真など）を考慮するようにする。また、ユーザー自身にレーティングさせて、重要度が高い写真はキャッシュ・非アーカイブ対象にする。
---

## 2. レイヤーアーキテクチャ
### 2.1 アーキテクチャ図

```
┌─────────────────────────────────────────────────────────────┐
│      External Systems (Storage, Events, SQS, Redis)         │
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Framework & Drivers Layer (Infrastructure)               │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ HTTP Server | MySQL | Redis | SQS | asynq Worker  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Interface Adapters Layer (Controllers, Presenters)       │
│  ┌─────────────┐ ┌──────────────┐ ┌──────────────┐         │
│  │ HTTP        │ │ asynq        │ │ Repository   │         │
│  │ Handlers    │ │ Job Handler  │ │ Adaptors     │         │
│  └─────────────┘ └──────────────┘ └──────────────┘         │
│  ┌─────────────┐ ┌──────────────────────────────┐           │
│  │ Presenters  │ │ External Service Adaptors    │           │
│  └─────────────┘ └──────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Application Layer (Use Cases)                            │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ GetEventAlbum | CreateAlbum | AddMediaToAlbum         │ │
│  │ RemoveMediaFromAlbum | AddComment | GenerateHighlight  │ │
│  │ ArchiveAlbum                                           │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Ports: AlbumRepository, StorageService, EventService   │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Entity Layer (Domain)                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Album | AlbumMedia | AlbumComment | HighlightVideo  │  │
│  │ Value Objects: AlbumStatus, MediaPosition, etc.     │  │
│  │ Domain Rules: 1 album per event, cascade delete     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール
- **内向き依存のみ**: 外層は内層に依存、逆は不可
- **ポート経由**: Album Repository、Storage Service、Event Service はインターフェース参照
- **DTO 翻訳**: HTTP リクエスト/レスポンスは適配層で Entity に変換
- **エラーハンドリング**: Domain エラー → HTTP エラーレスポンス

---

## 3. エンティティ層（ドメイン）
### 3.1 ドメインモデル

| モデル             | 説明                                     | 主要属性                                                                                                           |
| ------------------ | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| **Album**          | イベント内のアルバム集約ルート           | id (ULID), event_id?, org_id, title, cover_media_id?, created_by, status (ACTIVE/ARCHIVED), created_at, updated_at |
| **AlbumMedia**     | アルバム内のメディア参照                 | id (UUID), album_id, media_id (Storage ref), uploader_id, caption?, position (int), added_at                       |
| **AlbumComment**   | メディア/アルバム上のコメント            | id (UUID), album_id, media_id? (optional), user_id, body (max 1000 chars), created_at                              |
| **HighlightVideo** | アルバムにてユーザーから指定されたビデオ | id (UUID), album_id, video_media_id (Storage ref), duration_secs, status (DRAFT/ACTIVE/PRIVATE), generated_at?     |

### 3.2 値オブジェクト

| 値オブジェクト           | 許可値                             | バリデーション          |
| ------------------------ | ---------------------------------- | ----------------------- |
| **AlbumStatus**          | ACTIVE, ARCHIVED                   | 定義済み定数のみ        |
| **MediaPosition**        | 0 以上の整数                       | position >= 0           |
| **CommentBody**          | テキスト文字列                     | 1-1000 chars, non-empty |
| **HighlightVideoStatus** | PENDING, GENERATING, READY, FAILED | 定義済み定数のみ        |
| **ULID**                 | 128-bit ID                         | ランダム一意識別子      |

### 3.3 ドメインルール / 不変条件
- **1 イベント 1 アルバム**: event_id が設定される場合、same event_id でアルバムは 1 個のみ
- **アップロード権限**: contributor/owner のみメディア追加可能、viewer は閲覧のみ
- **メディア最適化処理**: メディアについて各デバイスに最適なファイルを配信できるようにファイルを処理、自動トリガー（asynq ジョブ）
- **コメント権限**: 同一 org 内ユーザのみコメント可能
- **アーカイブ処理**: owner のみアーカイブ可能、アーカイブ後メディア追加不可
- **カスケード削除**: event 削除時、紐付きアルバムは ARCHIVED へ自動遷移
- **メディアポジション**: 削除時、残りメディアのポジション自動リシャッフル

### 3.4 ドメインイベント

| イベント名        | トリガ                        | ペイロード                                          |
| ----------------- | ----------------------------- | --------------------------------------------------- |
| **AlbumCreated**  | CreateAlbum 実行完了          | album_id, event_id, org_id, created_by, created_at  |
| **MediaAdded**    | AddMediaToAlbum 実行完了      | album_id, media_id, uploader_id, position, added_at |
| **MediaRemoved**  | RemoveMediaFromAlbum 実行完了 | album_id, media_id, removed_at, remaining_count     |
| **CommentAdded**  | AddComment 実行完了           | album_id, comment_id, user_id, created_at           |
| **AlbumArchived** | ArchiveAlbum 実行完了         | album_id, archived_at                               |

### 3.5 エンティティ定義

```go
// ドメイン層: エンティティ定義

// Album: イベント内のアルバム集約ルート
type Album struct {
    ID            ulid.ULID            // ULID: Universally Unique Lexicographically Sortable Identifier
    EventID       *string              // optional: イベント ID (nil = org-level album)
    OrgID         string               // 組織 ID
    Title         string               // アルバムタイトル
    CoverMediaID  *string              // カバー画像 media ID (Storage ref)
    CreatedBy     string               // 作成ユーザ ID
    Status        AlbumStatus          // ACTIVE, ARCHIVED
    MediaCount    int                  // メディア数
    CreatedAt     time.Time
    UpdatedAt     time.Time
}

// IsEditable: アルバム編集可能判定
func (a *Album) IsEditable() bool {
    return a.Status == AlbumStatusActive
}

// CanAddMedia: メディア追加可能判定（ハイライト生成トリガー判定）
func (a *Album) CanAddMedia() bool {
    return a.IsEditable() && a.MediaCount < 10000 // 上限設定
}

// ShouldGenerateHighlight: ハイライト生成判定
func (a *Album) ShouldGenerateHighlight() bool {
    return a.MediaCount >= 10
}

// Archive: アルバムをアーカイブ
func (a *Album) Archive() error {
    if a.Status == AlbumStatusArchived {
        return ErrAlreadyArchived
    }
    a.Status = AlbumStatusArchived
    a.UpdatedAt = time.Now()
    return nil
}

// AlbumMedia: アルバム内メディア参照
type AlbumMedia struct {
    ID         uuid.UUID   // Media レコード ID
    AlbumID    ulid.ULID   // 親アルバム ID
    MediaID    string      // Storage Service 内 media ID（参照のみ）
    UploaderID string      // アップロードユーザ ID
    Caption    *string     // メディアキャプション（optional）
    Position   int         // ソート位置（0-indexed）
    AddedAt    time.Time
}

// UpdatePosition: ポジション更新（リシャッフル用）
func (am *AlbumMedia) UpdatePosition(newPos int) error {
    if newPos < 0 {
        return ErrInvalidPosition
    }
    am.Position = newPos
    return nil
}

// AlbumComment: メディア/アルバム上のコメント
type AlbumComment struct {
    ID       uuid.UUID
    AlbumID  ulid.ULID
    MediaID  *uuid.UUID  // optional: 特定メディアへのコメント
    UserID   string
    Body     CommentBody // 値オブジェクト（max 1000 chars）
    CreatedAt time.Time
}

// Validate: コメント内容バリデーション
func (ac *AlbumComment) Validate() error {
    if len(ac.Body) == 0 {
        return ErrEmptyComment
    }
    if len(ac.Body) > 1000 {
        return ErrCommentTooLong
    }
    return nil
}

// HighlightVideo: ハイライトビデオ
type HighlightVideo struct {
    ID           uuid.UUID
    AlbumID      ulid.ULID
    VideoMediaID string                // Storage Service 内 video media ID
    DurationSecs int
    Status       HighlightVideoStatus  // DRAFT, ACTIVE, PRIVATE
    SettedAt    time.Time
}


// Value Objects

type AlbumStatus string

const (
    AlbumStatusActive   AlbumStatus = "ACTIVE"
    AlbumStatusArchived AlbumStatus = "ARCHIVED"
)

type MediaPosition int

const (
    MinMediaPosition MediaPosition = 0
    MaxMediaPosition MediaPosition = 10000
)

type CommentBody string

func NewCommentBody(body string) (CommentBody, error) {
    if len(body) == 0 || len(body) > 1000 {
        return "", ErrInvalidCommentBody
    }
    return CommentBody(body), nil
}

```

---

## 4. ユースケース層（アプリケーション）
### 4.1 ユースケース一覧

| ユースケース             | アクタ             | 説明                                       | 主要入力                                  |
| ------------------------ | ------------------ | ------------------------------------------ | ----------------------------------------- |
| **GetEventAlbum**        | User (Viewer)      | イベントに紐付くアルバムと全メディアを取得 | org_id, event_id                          |
| **CreateAlbum**          | User (Owner)       | 新規アルバムを作成（event_id optional）    | org_id, title, created_by, event_id?      |
| **AddMediaToAlbum**      | User (Contributor) | メディアをアルバムに追加                   | album_id, media_id, uploader_id, caption? |
| **RemoveMediaFromAlbum** | User (Owner)       | アルバムからメディアを削除                 | album_id, media_id                        |
| **AddComment**           | User (OrgMember)   | アルバム/メディアにコメント追加            | album_id, media_id?, user_id, body        |
| **ArchiveAlbum**         | User (Owner)       | アルバムをアーカイブ（読取専用化）         | album_id                                  |

### 4.2 ユースケース詳細

#### GetEventAlbum (メインユースケース)
**アクタ**: User (Viewer)

**前提条件**:
- ユーザが org にメンバーとして登録
- event_id が存在（Event Service で確認）
- ユーザが event に対してアクセス権あり

**フロー**:
1. Permission Service で org + event アクセス権チェック
2. キャッシュ確認（Redis key: `album:event:{event_id}:media`）
3. キャッシュ miss → Repository.FindByEventID() で DB クエリ
4. AlbumMedia リスト取得 → Storage Service で media metadata 拡張（URL, type 等）
5. Presenter で DTO に変換 → HTTP 200 JSON 返却
6. キャッシュに登録（TTL 5 分）

**事後条件**:
- Album + AlbumMedia リスト HTTP レスポンス返却
- Redis キャッシュ更新（5 分 TTL）

**エラーケース**:
- Permission denied → HTTP 403
- Event not found → HTTP 404
- Album not found → HTTP 404（event_id は valid だが album 作成されていない）
- Storage Service 呼び出し失敗 → リトライ or キャッシュ返却

### 4.3 入出力DTO

```go
// ユースケース層: 入出力DTO

// GetEventAlbumInput
type GetEventAlbumInput struct {
    OrgID   string `validate:"required,uuid"`
    EventID string `validate:"required,uuid"`
}

// AlbumMediaDTO
type AlbumMediaDTO struct {
    ID         string `json:"id"`
    MediaID    string `json:"media_id"`
    Caption    string `json:"caption,omitempty"`
    Position   int    `json:"position"`
    UploaderID string `json:"uploader_id"`
    MediaURL   string `json:"media_url"`      // Storage から取得
    MediaType  string `json:"media_type"`     // image, video
    AddedAt    string `json:"added_at"`
}

// HighlightVideoDTO
type HighlightVideoDTO struct {
    ID           string `json:"id"`
    VideoMediaID string `json:"video_media_id"`
    Status       string `json:"status"`
    SettedAt  string `json:"setted_at,omitempty"`
    VideoURL     string `json:"video_url"`      // Storage から取得
}

// GetEventAlbumOutput
type GetEventAlbumOutput struct {
    Album          *AlbumDTO            `json:"album"`
    Medias         []*AlbumMediaDTO     `json:"medias"`
    HighlightVideo *HighlightVideoDTO   `json:"highlight_video,omitempty"`
    CommentsCount  int                  `json:"comments_count"`
}

// CreateAlbumInput
type CreateAlbumInput struct {
    OrgID     string `json:"org_id" validate:"required,uuid"`
    Title     string `json:"title" validate:"required,max=255"`
    CreatedBy string `json:"created_by" validate:"required,uuid"`
    EventID   string `json:"event_id,omitempty" validate:"omitempty,uuid"`
}

// CreateAlbumOutput
type CreateAlbumOutput struct {
    AlbumID   string `json:"album_id"`
    OrgID     string `json:"org_id"`
    EventID   string `json:"event_id,omitempty"`
    Title     string `json:"title"`
    CreatedAt string `json:"created_at"`
}

// AddMediaToAlbumInput
type AddMediaToAlbumInput struct {
    AlbumID    string `json:"album_id" validate:"required,ulid"`
    MediaID    string `json:"media_id" validate:"required"`
    UploaderID string `json:"uploader_id" validate:"required,uuid"`
    Caption    string `json:"caption,omitempty" validate:"max=500"`
}

// AddMediaToAlbumOutput
type AddMediaToAlbumOutput struct {
    AlbumMediaID string `json:"album_media_id"`
    Position     int    `json:"position"`
    AddedAt      string `json:"added_at"`
}

// AddCommentInput
type AddCommentInput struct {
    AlbumID  string `json:"album_id" validate:"required,ulid"`
    MediaID  string `json:"media_id,omitempty" validate:"omitempty,uuid"`
    UserID   string `json:"user_id" validate:"required,uuid"`
    Body     string `json:"body" validate:"required,max=1000"`
}

// AddCommentOutput
type AddCommentOutput struct {
    CommentID string `json:"comment_id"`
    CreatedAt string `json:"created_at"`
}

// ArchiveAlbumInput
type ArchiveAlbumInput struct {
    AlbumID string `validate:"required,ulid"`
}

// ArchiveAlbumOutput
type ArchiveAlbumOutput struct {
    AlbumID   string `json:"album_id"`
    Status    string `json:"status"`
    ArchivedAt string `json:"archived_at"`
}
```

### 4.4 リポジトリインターフェース（ポート）

```go
// ユースケース層: ポートインターフェース

// AlbumRepository: アルバム永続化ポート
type AlbumRepository interface {
    // Create: 新規アルバムを作成
    Create(ctx context.Context, album *domain.Album) error
    
    // FindByID: ID でアルバムを取得
    FindByID(ctx context.Context, id ulid.ULID) (*domain.Album, error)
    
    // FindByEventID: event_id でアルバムを取得（1:1 関係）
    FindByEventID(ctx context.Context, eventID string) (*domain.Album, error)
    
    // Update: アルバムを更新
    Update(ctx context.Context, album *domain.Album) error
    
    // FindMediaByAlbumID: アルバム内の全メディアを取得（ソート済み）
    FindMediaByAlbumID(ctx context.Context, albumID ulid.ULID) ([]*domain.AlbumMedia, error)
    
    // AddMedia: メディア参照を追加
    AddMedia(ctx context.Context, media *domain.AlbumMedia) error
    
    // RemoveMedia: メディア参照を削除
    RemoveMedia(ctx context.Context, albumID ulid.ULID, mediaID uuid.UUID) error
    
    // UpdateMediaPosition: ポジションを更新（リシャッフル用）
    UpdateMediaPosition(ctx context.Context, albumID ulid.ULID, mediaID uuid.UUID, newPos int) error
    
    // FindCommentsByAlbumID: アルバム内コメントを取得
    FindCommentsByAlbumID(ctx context.Context, albumID ulid.ULID) ([]*domain.AlbumComment, error)
    
    // AddComment: コメントを追加
    AddComment(ctx context.Context, comment *domain.AlbumComment) error
}
```

### 4.5 外部サービスインターフェース（ポート）

```go
// StorageService: メディア Storage ポート
type StorageService interface {
    // GetMediaMetadata: media_id からメディア情報を取得
    GetMediaMetadata(ctx context.Context, mediaID string) (*domain.MediaMetadata, error)
    
    // GetMediaURL: media_id から取得 URL を生成
    GetMediaURL(ctx context.Context, mediaID string, expiryMinutes int) (string, error)
    
    // CreateHighlightVideo: ハイライトビデオを作成（S3 署名付き URL 返却）
    CreateHighlightVideo(ctx context.Context, highlightID uuid.UUID, mediaIDs []string) (string, error)
}

// EventService: イベント情報ポート
type EventService interface {
    // GetEvent: event_id からイベント情報を取得
    GetEvent(ctx context.Context, eventID string) (*domain.EventInfo, error)
    
    // IsEventActive: イベントが active か判定
    IsEventActive(ctx context.Context, eventID string) (bool, error)
}

// PermissionService: アクセス権チェックポート
type PermissionService interface {
    // CheckOrgAccess: ユーザが org にアクセス可能か
    CheckOrgAccess(ctx context.Context, userID, orgID string) (bool, error)
    
    // CheckEventAccess: ユーザが event にアクセス可能か
    CheckEventAccess(ctx context.Context, userID, eventID string) (bool, error)
    
    // CheckAlbumOwner: ユーザがアルバム所有者か
    CheckAlbumOwner(ctx context.Context, userID string, albumID ulid.ULID) (bool, error)
    
    // CheckContributor: ユーザが contributor 権限か
    CheckContributor(ctx context.Context, userID, orgID string) (bool, error)
}

// CacheService: キャッシュポート
type CacheService interface {
    // GetAlbumMediaList: キャッシュからメディアリスト取得
    GetAlbumMediaList(ctx context.Context, albumID ulid.ULID) ([]*domain.AlbumMedia, error)
    
    // SetAlbumMediaList: メディアリストをキャッシュ
    SetAlbumMediaList(ctx context.Context, albumID ulid.ULID, medias []*domain.AlbumMedia, ttl time.Duration) error
    
    // InvalidateAlbumCache: アルバムキャッシュを無効化
    InvalidateAlbumCache(ctx context.Context, albumID ulid.ULID) error
}

// JobQueue: asynq ジョブキューポート
type JobQueue interface {
    // EnqueueHighlightGenerationJob: メディアコンバートジョブをエンキュー
    EnqueueOptimizationFileGenerationJob(ctx context.Context, albumID ulid.ULID) (jobID string, err error)
}

// EventPublisher: イベント発行ポート
type EventPublisher interface {
    // PublishAlbumCreated: AlbumCreated イベント発行 → SQS
    PublishAlbumCreated(ctx context.Context, event *domain.AlbumCreatedEvent) error
    
    // PublishMediaAdded: MediaAdded イベント発行
    PublishMediaAdded(ctx context.Context, event *domain.MediaAddedEvent) error
    
    // PublishOptimizationFileReady: メディアコンバート完了イベント発行
    PublishOptimizationFileReady(ctx context.Context, event *domain.MediaConvertReadyEvent) error
}
```

---

## 5. インターフェースアダプタ層
### 5.1 コントローラ / ハンドラ

| ハンドラ                   | HTTP メソッド | パス                                                  | 説明                   |
| -------------------------- | ------------- | ----------------------------------------------------- | ---------------------- |
| **GetEventAlbumHandler**   | GET           | /api/orgs/{org_id}/events/{event_id}/album            | イベントアルバムを取得 |
| **CreateAlbumHandler**     | POST          | /api/orgs/{org_id}/albums                             | 新規アルバム作成       |
| **AddMediaHandler**        | POST          | /api/orgs/{org_id}/albums/{album_id}/media            | メディア追加           |
| **RemoveMediaHandler**     | DELETE        | /api/orgs/{org_id}/albums/{album_id}/media/{media_id} | メディア削除           |
| **AddCommentHandler**      | POST          | /api/orgs/{org_id}/albums/{album_id}/comments         | コメント追加           |
| **MediaConvertJobHandler** | -             | (asynq)                                               | 最適化ファイル生成     |
| **ArchiveAlbumHandler**    | POST          | /api/orgs/{org_id}/albums/{album_id}/archive          | アルバムアーカイブ     |

### 5.2 プレゼンター / レスポンスマッパー

```go
// インターフェース適配層: プレゼンター

type AlbumPresenter struct{}

// PresentGetEventAlbum: GetEventAlbumOutput → HTTP 200 JSON
func (p *AlbumPresenter) PresentGetEventAlbum(output *application.GetEventAlbumOutput) *http.Response {
    return &http.Response{
        StatusCode: 200,
        Body:       json.Marshal(output),
    }
}

// PresentCreateAlbum: CreateAlbumOutput → HTTP 201 JSON
func (p *AlbumPresenter) PresentCreateAlbum(output *application.CreateAlbumOutput) *http.Response {
    return &http.Response{
        StatusCode: 201,
        Body:       json.Marshal(output),
    }
}

// PresentError: Error → HTTP エラーレスポンス
func (p *AlbumPresenter) PresentError(err error) *http.Response {
    statusCode, message := p.mapErrorToHTTP(err)
    return &http.Response{
        StatusCode: statusCode,
        Body:       json.Marshal(map[string]string{"error": message}),
    }
}

func (p *AlbumPresenter) mapErrorToHTTP(err error) (int, string) {
    switch err.(type) {
    case *domain.ValidationError:
        return 400, "Invalid input"
    case *domain.NotFoundError:
        return 404, "Resource not found"
    case *domain.UnauthorizedError:
        return 403, "Access denied"
    case *domain.AlreadyArchivedError:
        return 409, "Album already archived"
    default:
        return 500, "Internal server error"
    }
}
```

### 5.3 リポジトリ実装（アダプタ）

| アダプタ                      | 技術        | 説明                                                         |
| ----------------------------- | ----------- | ------------------------------------------------------------ |
| **MySQLAlbumRepository**      | pgx/v5      | Album, AlbumMedia, AlbumComment, HighlightVideo テーブル操作 |
| **RedisAlbumCacheRepository** | go-redis/v9 | メディアリストのキャッシング                                 |

### 5.4 外部サービスアダプタ

| アダプタ                         | 実装          | 説明                              |
| -------------------------------- | ------------- | --------------------------------- |
| **StorageServiceHTTPAdapter**    | http.Client   | Storage Service REST API 呼び出し |
| **EventServiceGRPCAdapter**      | grpc-go       | Event Service gRPC 呼び出し       |
| **PermissionServiceGRPCAdapter** | grpc-go       | Permission Service gRPC 呼び出し  |
| **AsynqJobQueueAdapter**         | asynqmux      | asynq ジョブキュー管理            |
| **SQSEventPublisherAdapter**     | aws-sdk-go-v2 | SQS へのドメインイベント発行      |

### 5.5 マッパー

```go
// マッパー: DTO ↔ Entity 相互変換

type AlbumMapper struct{}

// MapInputToEntity: CreateAlbumInput → Album
func (m *AlbumMapper) MapInputToEntity(input *application.CreateAlbumInput) (*domain.Album, error) {
    return &domain.Album{
        ID:        ulid.Make(),
        EventID:   &input.EventID,
        OrgID:     input.OrgID,
        Title:     input.Title,
        CreatedBy: input.CreatedBy,
        Status:    domain.AlbumStatusActive,
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }, nil
}

// MapEntityToDTO: Album → AlbumDTO
func (m *AlbumMapper) MapEntityToDTO(album *domain.Album) *application.AlbumDTO {
    eventID := ""
    if album.EventID != nil {
        eventID = *album.EventID
    }
    return &application.AlbumDTO{
        ID:        album.ID.String(),
        EventID:   eventID,
        OrgID:     album.OrgID,
        Title:     album.Title,
        Status:    string(album.Status),
        CreatedBy: album.CreatedBy,
        CreatedAt: album.CreatedAt.Format(time.RFC3339),
    }
}

// MapMediaToDTO: AlbumMedia + Storage metadata → AlbumMediaDTO
func (m *AlbumMapper) MapMediaToDTO(media *domain.AlbumMedia, storageMetadata *domain.MediaMetadata) *application.AlbumMediaDTO {
    return &application.AlbumMediaDTO{
        ID:         media.ID.String(),
        MediaID:    media.MediaID,
        Caption:    *media.Caption,
        Position:   media.Position,
        UploaderID: media.UploaderID,
        MediaURL:   storageMetadata.URL,
        MediaType:  storageMetadata.Type,
        AddedAt:    media.AddedAt.Format(time.RFC3339),
    }
}
```

---

## 6. フレームワーク＆ドライバ層（インフラストラクチャ）
### 6.1 Webフレームワーク
- **Go 1.22+** + **Echo v4** (HTTP サーバ、RESTful API)
- **gRPC** (Event/Permission Service との内部通信)

### 6.2 データベース

```sql
-- MySQL 14+ スキーマ

-- アルバムテーブル
CREATE TABLE IF NOT EXISTS albums (
    id ULID PRIMARY KEY NOT NULL,
    event_id UUID UNIQUE,
    org_id UUID NOT NULL,
    title VARCHAR(255) NOT NULL,
    cover_media_id VARCHAR(255),
    created_by UUID NOT NULL,
    status VARCHAR(50) NOT NULL CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    media_count INTEGER DEFAULT 0 NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_album_event_id ON albums (event_id);
CREATE INDEX idx_album_org_id ON albums (org_id, created_at DESC);
CREATE INDEX idx_album_status ON albums (status);

-- アルバムメディアテーブル
CREATE TABLE IF NOT EXISTS album_media (
    id UUID PRIMARY KEY NOT NULL,
    album_id ULID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    media_id VARCHAR(255) NOT NULL,
    uploader_id UUID NOT NULL,
    caption TEXT,
    position INTEGER NOT NULL DEFAULT 0,
    added_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(album_id, media_id)
);

CREATE INDEX idx_album_media_album_id ON album_media (album_id, position ASC);
CREATE INDEX idx_album_media_uploader ON album_media (uploader_id);

-- アルバムコメントテーブル
CREATE TABLE IF NOT EXISTS album_comments (
    id UUID PRIMARY KEY NOT NULL,
    album_id ULID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    media_id UUID,
    user_id UUID NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_album_comments_album_id ON album_comments (album_id, created_at DESC);
CREATE INDEX idx_album_comments_media_id ON album_comments (media_id) WHERE media_id IS NOT NULL;
CREATE INDEX idx_album_comments_user_id ON album_comments (user_id);

```

### 6.3 メッセージブローカー
- **SQS**: ドメインイベント非同期処理
  - キュー名: `recuerdo-album-events-queue`
  - イベント種: `AlbumCreated`, `MediaAdded`, `HighlightVideoReady`
  - メッセージ保有: 1 日
  - 可視性タイムアウト: 5 分

### 6.4 外部ライブラリ＆SDK

| ライブラリ      | 用途                | バージョン |
| --------------- | ------------------- | ---------- |
| **pgx/v5**      | MySQL ドライバ      | v5.5+      |
| **go-redis/v9** | Redis キャッシュ    | v9.3+      |
| **echo/v4**     | HTTP フレームワーク | v4.10+     |
| **asynqmux**    | ジョブキュー        | v0.5+      |
| **oklog/ulid**  | ULID 生成           | v1.3+      |
| **google/uuid** | UUID 生成           | v1.5+      |
| **grpc-go**     | gRPC クライアント   | v1.60+     |
| **uber-go/fx**  | DI コンテナ         | v1.20+     |

### 6.5 依存性注入

```go
// インフラストラクチャ層: DI 設定 (uber-go/fx)

package infrastructure

import (
    "go.uber.org/fx"
    "github.com/jackc/pgx/v5/pgxpool"
    "github.com/redis/go-redis/v9"
    "github.com/hibiken/asynq"
)

// FX モジュール: 依存関係の登録
var AlbumModule = fx.Module("album",
    fx.Provide(
        // インフラストラクチャ提供者
        provideMySQLDB,
        provideRedis,
        provideAsynqClient,
        provideSQSClient,
        
        // リポジトリ実装
        repository.NewMySQLAlbumRepository,
        repository.NewRedisAlbumCacheRepository,
        
        // ユースケース
        usecase.NewGetEventAlbumUsecase,
        usecase.NewCreateAlbumUsecase,
        usecase.NewAddMediaToAlbumUsecase,
        usecase.NewRemoveMediaFromAlbumUsecase,
        usecase.NewAddCommentUsecase,
        usecase.NewGenerateHighlightVideoUsecase,
        usecase.NewArchiveAlbumUsecase,
        
        // ハンドラ
        handler.NewGetEventAlbumHandler,
        handler.NewCreateAlbumHandler,
        handler.NewAddMediaHandler,
        handler.NewRemoveMediaHandler,
        handler.NewAddCommentHandler,
        handler.NewGenerateHighlightJobHandler,
        handler.NewArchiveAlbumHandler,
        
        // プレゼンター、マッパー
        handler.NewAlbumPresenter,
        handler.NewAlbumMapper,
    ),
)

// provideMySQLDB: MySQL コネクションプール
func provideMySQLDB(cfg *config.Config) (*pgxpool.Pool, error) {
    pool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
    if err != nil {
        return nil, err
    }
    return pool, nil
}

// provideRedis: Redis クライアント
func provideRedis(cfg *config.Config) *redis.Client {
    return redis.NewClient(&redis.Options{
        Addr: cfg.RedisAddr,
    })
}

// provideAsynqClient: asynq クライアント（ジョブキュー）
func provideAsynqClient(cfg *config.Config) *asynq.Client {
    return asynq.NewClient(asynq.RedisClientOpt{
        Addr: cfg.RedisAddr,
    })
}

// main.go での使用
func main() {
    app := fx.New(
        AlbumModule,
        fx.Provide(config.LoadConfig),
        fx.Invoke(startServer),
    )
    app.Run()
}

func startServer(
    getAlbumHandler *handler.GetEventAlbumHandler,
    createAlbumHandler *handler.CreateAlbumHandler,
    highlightJobHandler *handler.GenerateHighlightJobHandler,
) {
    e := echo.New()
    
    // RESTful ルート
    e.GET("/api/orgs/:org_id/events/:event_id/album", getAlbumHandler.Handle)
    e.POST("/api/orgs/:org_id/albums", createAlbumHandler.Handle)
    
    // asynq ジョブハンドラ起動
    go highlightJobHandler.StartWorker()
    
    e.Start(":8080")
}
```

---

## 7. ディレクトリ構成

```
recuerdo-album-svc/
├── cmd/
│   ├── main.go                 # エントリポイント
│   └── migrations/
│       └── 001_create_album_tables.sql
│
├── domain/
│   ├── album.go                # Album エンティティ
│   ├── album_media.go          # AlbumMedia エンティティ
│   ├── album_comment.go        # AlbumComment エンティティ
│   ├── highlight_video.go      # HighlightVideo エンティティ
│   ├── value_objects.go        # 値オブジェクト
│   ├── errors.go               # ドメインエラー
│   └── events.go               # ドメインイベント定義
│
├── application/
│   ├── usecase/
│   │   ├── get_event_album.go
│   │   ├── create_album.go
│   │   ├── add_media_to_album.go
│   │   ├── remove_media_from_album.go
│   │   ├── add_comment.go
│   │   ├── generate_highlight_video.go
│   │   └── archive_album.go
│   ├── port/
│   │   ├── album_repository.go
│   │   ├── storage_service.go
│   │   ├── event_service.go
│   │   ├── permission_service.go
│   │   ├── cache_service.go
│   │   ├── job_queue.go
│   │   └── event_publisher.go
│   ├── dto/
│   │   ├── get_event_album_dto.go
│   │   ├── create_album_dto.go
│   │   ├── add_media_dto.go
│   │   └── add_comment_dto.go
│   └── mapper/
│       └── album_mapper.go
│
├── adapter/
│   ├── handler/
│   │   ├── get_event_album_handler.go
│   │   ├── create_album_handler.go
│   │   ├── add_media_handler.go
│   │   ├── remove_media_handler.go
│   │   ├── add_comment_handler.go
│   │   ├── generate_highlight_job_handler.go
│   │   ├── archive_album_handler.go
│   │   └── presenter.go
│   ├── repository/
│   │   ├── MySQL_album_repository.go
│   │   └── redis_cache_repository.go
│   └── external/
│       ├── storage_service_adapter.go
│       ├── event_service_adapter.go
│       ├── permission_service_adapter.go
│       ├── asynq_job_queue_adapter.go
│       └── sqs_event_publisher_adapter.go
│
├── infrastructure/
│   ├── config/
│   │   └── config.go
│   ├── database/
│   │   ├── connection.go
│   │   └── migrations.go
│   ├── cache/
│   │   └── redis.go
│   └── di/
│       └── module.go            # DI 初期化 (fx)
│
├── test/
│   ├── domain/
│   │   └── album_test.go
│   ├── application/
│   │   ├── get_event_album_usecase_test.go
│   │   └── create_album_usecase_test.go
│   ├── adapter/
│   │   └── MySQL_album_repository_test.go
│   ├── integration/
│   │   └── end_to_end_test.go
│   └── fixtures/
│       └── sample_albums.json
│
├── go.mod
├── go.sum
├── Dockerfile
├── docker-compose.test.yml
├── README.md
└── .env.example
```

---

## 8. 依存性ルールと境界
### 8.1 許可される依存関係

| From Layer  | To Layer    | 許可 | 説明                               |
| ----------- | ----------- | ---- | ---------------------------------- |
| Framework   | Adapter     | ✓    | ハンドラ実装、リポジトリ実装など   |
| Adapter     | Application | ✓    | ユースケース呼び出し、DTO 変換     |
| Application | Domain      | ✓    | エンティティ、値オブジェクト使用   |
| Domain      | (外部)      | ✗    | フレームワーク、ライブラリ非参照   |
| Application | Framework   | ✗    | DI コンテナのみ許可（初期化時）    |
| Adapter     | Adapter     | ✗    | 各アダプタは独立、ポート経由で通信 |

### 8.2 境界の横断
1. **入口 (Handler → UseCase)**:
   - HTTP ハンドラが HTTP リクエスト → DTO に変換
   - ユースケースインスタンス呼び出し
   
2. **出口 (UseCase → Repository)**:
   - ユースケースが Abstract Repository ポート参照
   - 実装は DI コンテナで注入
   
3. **エラー処理**:
   - ドメインエラー → Application エラー → HTTP に変換

### 8.3 ルールの強制
- **コンパイル時**: Go 内部パッケージ (`internal/domain`, `internal/application`) でアクセス制限
- **実行時**: ポート (インターフェース) 経由で外部参照、実装クラスは非公開
- **テスト**: Mock インターフェース実装で境界検証

---

## 9. テスト戦略
### 9.1 テストピラミッド

| レベル       | カウント | 説明                                    | ツール                             |
| ------------ | -------- | --------------------------------------- | ---------------------------------- |
| **ユニット** | 45%      | ドメインモデル（Album.IsEditable, etc） | `testing`, `testify/assert`        |
| **統合**     | 40%      | ユースケース + Mock Repository/Service  | `testing`, `testify/mock`          |
| **E2E**      | 15%      | HTTP → DB → Cache → asynq 全フロー      | `testcontainers`, `docker-compose` |

### 9.2 テスト例

```go
// domain/album_test.go: ドメインテスト
package domain_test

import (
    "testing"
    "time"
    "github.com/stretchr/testify/assert"
    "github.com/oklog/ulid"
    "recuerdo/album/domain"
)

func TestAlbumIsEditable(t *testing.T) {
    album := &domain.Album{
        ID:     ulid.Make(),
        Status: domain.AlbumStatusActive,
    }
    assert.True(t, album.IsEditable())
    
    album.Status = domain.AlbumStatusArchived
    assert.False(t, album.IsEditable())
}

func TestAlbumShouldGenerateHighlight(t *testing.T) {
    tests := []struct {
        name         string
        mediaCount   int
        shouldGenerate bool
    }{
        {"9 media items", 9, false},
        {"10 media items", 10, true},
        {"100 media items", 100, true},
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            album := &domain.Album{
                ID:         ulid.Make(),
                MediaCount: tt.mediaCount,
                Status:     domain.AlbumStatusActive,
            }
            assert.Equal(t, tt.shouldGenerate, album.ShouldGenerateHighlight())
        })
    }
}

// application/get_event_album_usecase_test.go: ユースケーステスト
package application_test

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "github.com/oklog/ulid"
    "recuerdo/album/application"
    "recuerdo/album/domain"
)

type MockAlbumRepository struct {
    mock.Mock
}

func (m *MockAlbumRepository) FindByEventID(ctx context.Context, eventID string) (*domain.Album, error) {
    args := m.Called(ctx, eventID)
    if args.Get(0) == nil {
        return nil, args.Error(1)
    }
    return args.Get(0).(*domain.Album), args.Error(1)
}

type MockStorageService struct {
    mock.Mock
}

func (m *MockStorageService) GetMediaURL(ctx context.Context, mediaID string, expiryMinutes int) (string, error) {
    args := m.Called(ctx, mediaID, expiryMinutes)
    return args.String(0), args.Error(1)
}

func TestGetEventAlbumUsecase(t *testing.T) {
    mockRepo := new(MockAlbumRepository)
    mockStorage := new(MockStorageService)
    
    album := &domain.Album{
        ID:        ulid.Make(),
        OrgID:     "org-123",
        Title:     "Summer Reunion",
        Status:    domain.AlbumStatusActive,
        CreatedAt: time.Now(),
    }
    
    mockRepo.On("FindByEventID", mock.Anything, "event-456").Return(album, nil)
    mockStorage.On("GetMediaURL", mock.Anything, mock.Anything, 60).Return("https://storage.example.com/media/123", nil)
    
    usecase := application.NewGetEventAlbumUsecase(mockRepo, mockStorage)
    
    input := &application.GetEventAlbumInput{
        OrgID:   "org-123",
        EventID: "event-456",
    }
    
    output, err := usecase.Execute(context.Background(), input)
    
    assert.NoError(t, err)
    assert.NotNil(t, output)
    assert.Equal(t, "Summer Reunion", output.Album.Title)
    mockRepo.AssertExpectations(t)
}

// adapter/MySQL_album_repository_test.go: 統合テスト
package adapter_test

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "testcontainers"
    "recuerdo/album/adapter/repository"
    "recuerdo/album/domain"
)

func TestMySQLAlbumRepository_Create(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test")
    }
    
    MySQL := testcontainers.NewMySQLContainer(t)
    defer MySQL.Terminate(context.Background())
    
    pool := MySQL.Pool()
    repo := repository.NewMySQLAlbumRepository(pool)
    
    album := &domain.Album{
        ID:        ulid.Make(),
        OrgID:     "org-123",
        Title:     "New Album",
        CreatedBy: "user-456",
        Status:    domain.AlbumStatusActive,
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }
    
    err := repo.Create(context.Background(), album)
    assert.NoError(t, err)
    
    retrieved, err := repo.FindByID(context.Background(), album.ID)
    assert.NoError(t, err)
    assert.Equal(t, album.Title, retrieved.Title)
}
```

---

## 10. エラーハンドリング
### 10.1 ドメインエラー
```go
type ValidationError struct{ Message string }
type NotFoundError struct{ ResourceID string }
type AlreadyArchivedError struct{ AlbumID string }
type ImmutableViolationError struct{ Message string }
```

### 10.2 アプリケーションエラー
- **InvalidInputError**: DTO バリデーション失敗
- **PermissionDeniedError**: ユーザに操作権限なし
- **RepositoryError**: DB 永続化失敗
- **ExternalServiceError**: Storage/Event/Permission Service 呼び出し失敗

### 10.3 エラー変換 (HTTP マッピング)

| ドメイン / アプリケーションエラー | HTTP ステータス | メッセージ                 |
| --------------------------------- | --------------- | -------------------------- |
| ValidationError                   | 400             | "Invalid input: {details}" |
| NotFoundError                     | 404             | "Album not found"          |
| PermissionDeniedError             | 403             | "Access denied"            |
| AlreadyArchivedError              | 409             | "Album is archived"        |
| RepositoryError                   | 500             | "Database error"           |
| ExternalServiceError              | 503             | "Service unavailable"      |

---

## 11. 横断的関心事
### 11.1 ロギング
- **構造化ロギング**: JSON フォーマット（Zap, Logrus）
- **レベル**: INFO (API 呼び出し), ERROR (例外), DEBUG (DB クエリ)
- **トレース ID**: リクエスト ID を全ログに包含

### 11.2 認証・認可
- **認証**: JWT ベアラトークン（Authorization ヘッダ）
- **認可**: org メンバーシップチェック（Permission Service）
- **所有権**: アルバム owner のみ削除・アーカイブ可能
- **ミドルウェア**: Echo Middleware で認証検証

### 11.3 バリデーション
- **入力DTO**: `go-playground/validator` 使用（required, uuid, max等）
- **ドメイン**: Entity.Validate() メソッド
- **ルール**: 必須フィールド、enum 値確認

### 11.4 キャッシング
- **キャッシュ対象**: GetEventAlbum メディアリスト（5 分 TTL）
- **無効化**: メディア追加・削除時に pattern invalidate
- **実装**: Redis `SET`, `GET`, `DEL` コマンド

---

## 12. マイグレーション計画
### 12.1 現状
- 既存システム: in-memory アルバム（再起動で消失）
- スケーラビリティ: 単一プロセス
- ハイライト: 手動生成のみ

### 12.2 目標状態
- MySQL 永続化
- マイクロサービス化（Storage, Event との連携）
- ハイライトビデオ自動生成（asynq）
- 複数組織対応

### 12.3 マイグレーション手順

| フェーズ       | 期間  | 作業                                     | リスク             |
| -------------- | ----- | ---------------------------------------- | ------------------ |
| **フェーズ 1** | W1-2  | MySQL テーブル作成、FK 設定              | スキーマ設計誤り   |
| **フェーズ 2** | W3-4  | CreateAlbum, GetEventAlbum 実装・テスト  | イベント参照失敗   |
| **フェーズ 3** | W5-6  | AddMedia, RemoveMedia 実装、キャッシング | キャッシュ一貫性   |
| **フェーズ 4** | W7-8  | asynq ハイライト生成実装                 | ジョブ失敗処理     |
| **フェーズ 5** | W9-10 | ロードテスト、本番デプロイ               | パフォーマンス低下 |

---

## 13. 未決事項と決定事項

| 項目                       | ステータス | 決定                         | 理由                            |
| -------------------------- | ---------- | ---------------------------- | ------------------------------- |
| **ハイライト生成エンジン** | PENDING    | ffmpeg vs AWS MediaConvert   | コスト vs パフォーマンス比較中  |
| **キャッシュ戦略**         | DECIDED    | Redis (5min TTL)             | GetEventAlbum 頻出、低遅延必須  |
| **asynq 並列度**           | DECIDED    | 5 workers                    | メディア ≥10 個でハイライト生成 |
| **イベント削除時処理**     | DECIDED    | album を ARCHIVED へ自動遷移 | データ保護 + 監査証跡保持       |
| **ULID vs UUID**           | DECIDED    | ULID (album ID)              | ソート可能、時系列性            |
| **Storage Service 統合**   | DECIDED    | REST API + gRPC              | 汎用性と効率性の両立            |

---

## 14. 参考資料
- **Clean Architecture** (Uncle Bob): https://blog.cleancoder.com/
- **Domain-Driven Design** (Eric Evans): https://www.domainlanguage.com/
- **MySQL Foreign Keys**: https://www.MySQL.org/docs/current/ddl-constraints.html
- **Redis Caching Strategies**: https://redis.io/patterns/caching/
- **asynq Task Queue**: https://github.com/hibiken/asynq
- **Echo HTTP Framework**: https://echo.labstack.com/
- **gRPC**: https://grpc.io/
- **ULID**: https://github.com/oklog/ulid
