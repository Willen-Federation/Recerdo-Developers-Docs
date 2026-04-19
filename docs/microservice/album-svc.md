# AlbumApp Service (recuerdo-album-svc)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

AlbumApp Service (recuerdo-album-svc) は Recuerdo（古い友人やグループとの思い出を再びつなぐ社会的メモリプラットフォーム）のコアマイクロサービスです。このサービスは以下の責務を持ちます：

- **アルバム管理**: イベントに関連したアルバムの作成、更新、削除
- **メディア管理**: アルバムへの写真・ビデオの追加・削除・キャプション付与
- **アクセス制御**: ビューアー / コントリビューター / オーナーの役割ベースアクセス管理（Permission Serviceと連携）
- **ハイライトビデオ連結（ユーザー選択）**: ユーザーが明示的に選択した 2 本以上の動画を FFmpeg concat で連結してハイライト動画を生成する。ML による自動選定・自動ハイライトは行わない（[基本的方針](../core/policy.md) 参照）
- **コメント機能**: アルバム或いはメディア単位でのコメント投稿・表示
- **イベント連携**: Events Serviceと連携したアルバムの生成・更新

### ビジネスコンテキスト

Recuerdo は同窓会や旧友との再会イベント（例: 10年ぶりの同窓会）を中心としたコミュニティプラットフォームです。AlbumApp Service は各イベントの思い出を形にする中核的な機能を提供します。

**主要なユーザーストーリー**:

1. **イベント参加者**: イベント中に撮った写真・ビデオをアルバムに追加し、仲間と共有したい
2. **イベント主催者**: アルバムを管理し、メディアの追加権限を制御したい
3. **閲覧者**: アルバムの写真やビデオを見たい、コメントしたい
4. **ハイライトビデオ作成者**: イベントの動画から自分で 2 本以上を選び、連結したハイライトビデオを作成してグループ内で共有したい（ML による自動選定は行わない）

---

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ           | 説明                                                                                      | 主要属性                                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **Album**              | イベントまたはスタンドアロンのアルバム。メディア、コメント、ハイライトビデオの集約ルート  | id (ULID), event_id, org_id, title, description, cover_media_id, created_by (user_id), created_at, updated_at, status                |
| **AlbumMedia**         | アルバムに追加されたメディア（写真・ビデオ）への参照。実ファイルは Storage Service で管理 | id (ULID), album_id, media_id, uploaded_by (user_id), caption, position, added_at, deleted_at (soft delete)                          |
| **AlbumComment**       | アルバム全体またはアルバム内の特定メディアへのコメント                                    | id (ULID), album_id, media_id (nullable), user_id, body, created_at, updated_at                                                      |
| **HighlightVideo**     | **ユーザーが明示的に選択** した 2 件以上の動画を FFmpeg concat で連結したハイライトビデオ。ML による自動選定・自動生成は行わない。非同期ジョブ（QueuePort 経由、Beta: Redis+BullMQ/asynq、本番: OCI Queue）で処理 | id (ULID), album_id, selected_media_ids ([]ULID, 2件以上), video_media_id (Storage Service 参照), duration_secs, status (PENDING/READY/FAILED), requested_by (user_id), generated_at, metadata_json |
| **AlbumAccessControl** | アルバムに対する各ユーザーのロール（Permission Service との連携）                         | id (ULID), album_id, user_id, role (viewer/contributor/owner), granted_at                                                            |

### 値オブジェクト

| 値オブジェクト           | 説明                             | バリデーションルール                       |
| ------------------------ | -------------------------------- | ------------------------------------------ |
| **AlbumTitle**           | アルバムのタイトル               | 長さ 1-200 文字、必須、特殊文字は許可      |
| **Caption**              | メディアのキャプション           | 長さ 0-1000 文字、オプショナル             |
| **CommentBody**          | コメント本文                     | 長さ 1-5000 文字、必須、改行許可           |
| **MediaPosition**        | アルバム内でのメディアの表示順序 | 0 以上の整数、重複不可（同じアルバム内で） |
| **HighlightVideoStatus** | ハイライトビデオの状態           | PENDING / READY / FAILED のいずれか        |
| **Role**                 | アクセス制御ロール               | viewer / contributor / owner               |
| **AlbumStatus**          | アルバムの状態                   | ACTIVE / ARCHIVED / DELETED（論理削除）    |

### ドメインルール / 不変条件

- **Album Creation**: アルバムは Event Service から event_id と org_id を受け取り、必ず正当な Event に紐付けられる必要がある（またはスタンドアロン）
- **Media Addition Constraint**: contributor ロール以上のみがメディアを追加できる。viewer は閲覧のみ可能
- **Highlight Video Trigger**: ハイライトビデオは **ユーザーが明示的に選択した 2 件以上の動画** を元に、ユーザーからの明示リクエストで生成する。アルバムのメディア件数や視聴履歴などに基づく自動トリガー・ML 自動選定は行わない
- **Position Uniqueness**: 同じアルバム内で AlbumMedia の position は一意である必要がある（reordering 時に自動調整）
- **Soft Delete**: AlbumMedia と Album は論理削除（deleted_at フラグ）により管理される。物理削除はない
- **Owner Responsibility**: アルバムの owner は常に1名以上存在しなければならない
- **Cover Media Validation**: cover_media_id は album_id に紐付く AlbumMedia の media_id である必要がある
- **Immutable Created Fields**: created_by, created_at は作成後変更不可
- **Event Consistency**: event_id が設定されているアルバムは対応する Event が削除されてもアルバムは残る（Event の削除は Album に影響しない）

### ドメインイベント

| イベント                    | トリガー                            | 主要ペイロード                                                       |
| --------------------------- | ----------------------------------- | -------------------------------------------------------------------- |
| **AlbumCreated**            | Album が新規作成される              | album_id, org_id, event_id (nullable), created_by, created_at, title |
| **MediaAdded**              | AlbumMedia がアルバムに追加される   | album_id, media_id, uploaded_by, position, added_at, caption         |
| **MediaRemoved**            | AlbumMedia が削除される（論理削除） | album_id, media_id, removed_by, removed_at                           |
| **AlbumCommentCreated**     | AlbumComment が追加される           | album_id, comment_id, user_id, body, created_at                      |
| **HighlightVideoGenerated** | ハイライトビデオ生成が完了する      | album_id, highlight_video_id, video_media_id, duration_secs          |
| **AlbumAccessUpdated**      | アルバムのアクセス制御が変更される  | album_id, user_id, old_role, new_role, updated_at                    |
| **AlbumArchived**           | アルバムがアーカイブされる          | album_id, archived_at                                                |

### エンティティ定義（コードスケッチ）

```go
// Domain Entity: Album (Aggregate Root)
type Album struct {
    ID              string    // ULID
    EventID         *string   // nullable - null if standalone album
    OrgID           string
    Title           AlbumTitle
    Description     string
    CoverMediaID    *string   // nullable - must be a media_id in this album
    CreatedBy       string    // user_id
    CreatedAt       time.Time
    UpdatedAt       time.Time
    DeletedAt       *time.Time // soft delete
    Status          AlbumStatus
}

// Domain Value Object: AlbumTitle
type AlbumTitle struct {
    Value string
}

func NewAlbumTitle(value string) (AlbumTitle, error) {
    if len(value) < 1 || len(value) > 200 {
        return AlbumTitle{}, fmt.Errorf("album title must be 1-200 characters")
    }
    return AlbumTitle{Value: value}, nil
}

// Domain Entity: AlbumMedia
type AlbumMedia struct {
    ID        string     // ULID
    AlbumID   string
    MediaID   string     // reference to Storage Service
    UploadedBy string    // user_id
    Caption   string     // 0-1000 chars, optional
    Position  int        // ordering within album
    AddedAt   time.Time
    DeletedAt *time.Time // soft delete
}

// Domain Entity: AlbumComment
type AlbumComment struct {
    ID        string
    AlbumID   string
    MediaID   *string    // nullable - null if comment on album, set if comment on media
    UserID    string
    Body      string     // 1-5000 chars, required
    CreatedAt time.Time
    UpdatedAt time.Time
    DeletedAt *time.Time // soft delete
}

// Domain Entity: HighlightVideo
type HighlightVideo struct {
    ID           string
    AlbumID      string
    VideoMediaID string            // reference to Storage Service
    DurationSecs int
    Status       HighlightVideoStatus
    GeneratedAt  time.Time
    MetadataJSON string            // JSON: {selected_media_count, track_title, etc.}
}

// Domain Value Object: HighlightVideoStatus
type HighlightVideoStatus string

const (
    HighlightVideoPending HighlightVideoStatus = "PENDING"
    HighlightVideoReady   HighlightVideoStatus = "READY"
    HighlightVideoFailed  HighlightVideoStatus = "FAILED"
)

// Domain Value Object: AlbumAccessControl
type AlbumAccessControl struct {
    ID        string
    AlbumID   string
    UserID    string
    Role      Role
    GrantedAt time.Time
}

type Role string

const (
    RoleViewer      Role = "viewer"
    RoleContributor Role = "contributor"
    RoleOwner       Role = "owner"
)

// Domain Event
type AlbumCreatedEvent struct {
    AlbumID   string
    OrgID     string
    EventID   *string
    CreatedBy string
    CreatedAt time.Time
    Title     string
}

type MediaAddedEvent struct {
    AlbumID    string
    MediaID    string
    UploadedBy string
    Position   int
    AddedAt    time.Time
    Caption    string
}
```

---

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース            | 入力DTO                                                                | 出力DTO                | 説明                                                                               |
| ----------------------- | ---------------------------------------------------------------------- | ---------------------- | ---------------------------------------------------------------------------------- |
| **CreateAlbum**         | CreateAlbumInput                                                       | AlbumOutput            | 新規アルバムを作成。Event に紐付けるか、スタンドアロンで作成可能                   |
| **GetAlbum**            | GetAlbumInput (album_id)                                               | AlbumOutput            | アルバム詳細を取得。アクセス権限チェック実施                                       |
| **GetEventAlbum**       | GetEventAlbumInput (org_id, event_id)                                  | AlbumOutput            | イベントに紐付くアルバムを取得。アクセス権限チェック実施                           |
| **ListOrgAlbums**       | ListOrgAlbumsInput (org_id, page, limit)                               | AlbumListOutput        | 組織内の全アルバムをリスト。アクセス権限に基づくフィルタリング                     |
| **UpdateAlbumMetadata** | UpdateAlbumInput (album_id, title, description, cover_media_id)        | AlbumOutput            | アルバムのメタデータを更新。owner / contributor のみ可能                           |
| **AddMedia**            | AddMediaInput (album_id, media_id, caption, position)                  | AlbumMediaOutput       | メディアをアルバムに追加。自動的に position を調整。HighlightVideoJob トリガー判定 |
| **RemoveMedia**         | RemoveMediaInput (album_id, media_id)                                  | void                   | メディアを削除（論理削除）。position を自動再調整。イベント発行                    |
| **ReorderMedia**        | ReorderMediaInput (album_id, reorder_list: [{media_id, new_position}]) | AlbumMediaListOutput   | アルバム内のメディア順序を一括変更                                                 |
| **GetAlbumMedia**       | GetAlbumMediaInput (album_id, page, limit)                             | AlbumMediaListOutput   | アルバムのメディア一覧を取得（キャッシュ使用: Redis）                              |
| **UpdateMediaCaption**  | UpdateMediaCaptionInput (album_id, media_id, caption)                  | AlbumMediaOutput       | メディアのキャプションを更新                                                       |
| **CreateComment**       | CreateCommentInput (album_id, media_id?, body)                         | AlbumCommentOutput     | アルバムまたはメディアにコメントを追加                                             |
| **GetAlbumComments**    | GetAlbumCommentsInput (album_id, page, limit)                          | AlbumCommentListOutput | アルバムのコメント一覧を取得                                                       |
| **DeleteComment**       | DeleteCommentInput (album_id, comment_id)                              | void                   | コメントを削除。作成者またはアルバムオーナーのみ可能                               |
| **GetHighlightVideo**   | GetHighlightVideoInput (album_id)                                      | HighlightVideoOutput   | アルバムのハイライトビデオ情報を取得。存在しない場合は null                        |
| **ArchiveAlbum**        | ArchiveAlbumInput (album_id)                                           | AlbumOutput            | アルバムをアーカイブ。owner のみ可能                                               |
| **GetAlbumAccessList**  | GetAlbumAccessListInput (album_id)                                     | AlbumAccessListOutput  | アルバムのアクセス制御情報を取得。owner のみ可能                                   |

### ユースケース詳細（主要ユースケース: GetEventAlbum）

**ユースケース名**: GetEventAlbum  
**責務**: 指定されたイベントに紐付くアルバムを取得する。アクセス権限チェックを実施し、権限がない場合は AccessDenied エラーを返す。

**入力**:
```go
type GetEventAlbumInput struct {
    OrgID   string
    EventID string
    UserID  string  // 要求ユーザーID
}
```

**処理フロー**:

1. **Fetch Album**: AlbumRepository.GetByEventID(org_id, event_id) でアルバムを取得
2. **Access Check**: PermissionService.CheckAccess(user_id, album_id, ["viewer", "contributor", "owner"]) で権限確認
   - 権限なし → AccessDenied エラー返却
   - 権限あり → 次へ
3. **Fetch Media List**: AlbumMediaRepository.ListByAlbumID(album_id) でメディア一覧を取得
   - Redis キャッシュを優先利用（TTL: 5分）
   - キャッシュミス時は DB から取得して Redis に保存
4. **Fetch Highlight Video**: HighlightVideoRepository.GetByAlbumID(album_id) でハイライトビデオ情報を取得
5. **Enrich Album Output**: AlbumDTO に以下を含める
   - album metadata
   - media list (position 順)
   - highlight_video (ある場合)
   - current_user_role (Permission Service から取得)
6. **Return**: AlbumOutput を返却

**出力**:
```go
type AlbumOutput struct {
    ID               string
    EventID          *string
    OrgID            string
    Title            string
    Description      string
    CoverMediaID     *string
    CreatedBy        string
    CreatedAt        time.Time
    UpdatedAt        time.Time
    Status           string
    MediaCount       int
    Media            []AlbumMediaOutput  // position順
    HighlightVideo   *HighlightVideoOutput
    CurrentUserRole  string              // "viewer" / "contributor" / "owner"
}

type AlbumMediaOutput struct {
    ID        string
    MediaID   string
    Caption   string
    Position  int
    UploadedBy string
    AddedAt   time.Time
}

type HighlightVideoOutput struct {
    ID           string
    VideoMediaID string
    DurationSecs int
    Status       string
    GeneratedAt  time.Time
}
```

**エラーハンドリング**:
- AlbumNotFound: 404 NotFound
- AccessDenied: 403 Forbidden
- EventNotFound: 404 NotFound
- PermissionServiceError: 500 InternalServerError

### リポジトリ・サービスポート（インターフェース）

```go
// === Repository Ports ===

type AlbumRepository interface {
    Save(ctx context.Context, album *Album) error
    GetByID(ctx context.Context, albumID string) (*Album, error)
    GetByEventID(ctx context.Context, orgID, eventID string) (*Album, error)
    ListByOrgID(ctx context.Context, orgID string, page, limit int) ([]*Album, error)
    Delete(ctx context.Context, albumID string) error // soft delete
    Update(ctx context.Context, album *Album) error
}

type AlbumMediaRepository interface {
    Save(ctx context.Context, media *AlbumMedia) error
    GetByID(ctx context.Context, mediaID string) (*AlbumMedia, error)
    ListByAlbumID(ctx context.Context, albumID string) ([]*AlbumMedia, error)
    Delete(ctx context.Context, mediaID string) error // soft delete
    Update(ctx context.Context, media *AlbumMedia) error
    ReorderByAlbumID(ctx context.Context, albumID string, reorder map[string]int) error
}

type AlbumCommentRepository interface {
    Save(ctx context.Context, comment *AlbumComment) error
    GetByID(ctx context.Context, commentID string) (*AlbumComment, error)
    ListByAlbumID(ctx context.Context, albumID string, page, limit int) ([]*AlbumComment, error)
    ListByMediaID(ctx context.Context, mediaID string, page, limit int) ([]*AlbumComment, error)
    Delete(ctx context.Context, commentID string) error // soft delete
}

type HighlightVideoRepository interface {
    Save(ctx context.Context, hv *HighlightVideo) error
    GetByAlbumID(ctx context.Context, albumID string) (*HighlightVideo, error)
    Delete(ctx context.Context, highlightVideoID string) error
    Update(ctx context.Context, hv *HighlightVideo) error
}

// === Service Ports ===

type PermissionService interface {
    CheckAccess(ctx context.Context, userID, albumID string, requiredRoles []Role) (Role, error)
    GetUserRole(ctx context.Context, userID, albumID string) (Role, error)
    GrantAccess(ctx context.Context, albumID, userID string, role Role) error
    RevokeAccess(ctx context.Context, albumID, userID string) error
    ListAccessByAlbumID(ctx context.Context, albumID string) ([]*AlbumAccessControl, error)
}

type EventService interface {
    GetEvent(ctx context.Context, orgID, eventID string) (*EventData, error)
    VerifyEventExists(ctx context.Context, orgID, eventID string) error
}

type StorageService interface {
    GetMediaMetadata(ctx context.Context, mediaID string) (*MediaMetadata, error)
    VerifyMediaExists(ctx context.Context, mediaID string) error
    GetMediaURL(ctx context.Context, mediaID string) (string, error)
}

type EventPublisher interface {
    PublishAlbumCreated(ctx context.Context, event *AlbumCreatedEvent) error
    PublishMediaAdded(ctx context.Context, event *MediaAddedEvent) error
    PublishMediaRemoved(ctx context.Context, event *MediaRemovedEvent) error
    PublishCommentCreated(ctx context.Context, event *AlbumCommentCreatedEvent) error
    PublishAlbumAccessUpdated(ctx context.Context, event *AlbumAccessUpdatedEvent) error
}

type CacheService interface {
    Get(ctx context.Context, key string) (string, error)
    Set(ctx context.Context, key string, value string, ttl time.Duration) error
    Delete(ctx context.Context, key string) error
    DeletePattern(ctx context.Context, pattern string) error // delete all keys matching pattern
}

type HighlightVideoJobQueue interface {
    EnqueueGenerateHighlightVideo(ctx context.Context, albumID string, mediaIDs []string) error
    GetJobStatus(ctx context.Context, jobID string) (string, error)
}
```

---

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ                                   | ルート/トリガー                                                   | ユースケース        |
| ---------------------------------------------- | ----------------------------------------------------------------- | ------------------- |
| **AlbumController.CreateAlbum**                | POST /api/orgs/{org_id}/albums                                    | CreateAlbum         |
| **AlbumController.GetAlbum**                   | GET /api/orgs/{org_id}/albums/{album_id}                          | GetAlbum            |
| **AlbumController.GetEventAlbum**              | GET /api/orgs/{org_id}/events/{event_id}/album                    | GetEventAlbum       |
| **AlbumController.ListOrgAlbums**              | GET /api/orgs/{org_id}/albums                                     | ListOrgAlbums       |
| **AlbumController.UpdateAlbum**                | PATCH /api/orgs/{org_id}/albums/{album_id}                        | UpdateAlbumMetadata |
| **MediaController.AddMedia**                   | POST /api/orgs/{org_id}/albums/{album_id}/media                   | AddMedia            |
| **MediaController.RemoveMedia**                | DELETE /api/orgs/{org_id}/albums/{album_id}/media/{media_id}      | RemoveMedia         |
| **MediaController.ReorderMedia**               | POST /api/orgs/{org_id}/albums/{album_id}/media/reorder           | ReorderMedia        |
| **MediaController.GetAlbumMedia**              | GET /api/orgs/{org_id}/albums/{album_id}/media                    | GetAlbumMedia       |
| **MediaController.UpdateCaption**              | PATCH /api/orgs/{org_id}/albums/{album_id}/media/{media_id}       | UpdateMediaCaption  |
| **CommentController.CreateComment**            | POST /api/orgs/{org_id}/albums/{album_id}/comments                | CreateComment       |
| **CommentController.GetAlbumComments**         | GET /api/orgs/{org_id}/albums/{album_id}/comments                 | GetAlbumComments    |
| **CommentController.DeleteComment**            | DELETE /api/orgs/{org_id}/albums/{album_id}/comments/{comment_id} | DeleteComment       |
| **HighlightVideoController.GetHighlightVideo** | GET /api/orgs/{org_id}/albums/{album_id}/highlight-video          | GetHighlightVideo   |
| **AlbumController.ArchiveAlbum**               | POST /api/orgs/{org_id}/albums/{album_id}/archive                 | ArchiveAlbum        |
| **AccessController.GetAccessList**             | GET /api/orgs/{org_id}/albums/{album_id}/access                   | GetAlbumAccessList  |

### リポジトリ実装

| ポートインターフェース       | 実装クラス                    | データストア                     |
| ---------------------------- | ----------------------------- | -------------------------------- |
| **AlbumRepository**          | MySQLAlbumRepository          | MySQL: albums テーブル           |
| **AlbumMediaRepository**     | MySQLAlbumMediaRepository     | MySQL: album_media テーブル      |
| **AlbumCommentRepository**   | MySQLAlbumCommentRepository   | MySQL: album_comments テーブル   |
| **HighlightVideoRepository** | MySQLHighlightVideoRepository | MySQL: highlight_videos テーブル |
| **CacheService**             | RedisCache                    | Redis (album_media キャッシュ)   |

**MySQL スキーマ**:

```sql
-- Albums テーブル
CREATE TABLE albums (
    id              VARCHAR(26) PRIMARY KEY,  -- ULID
    event_id        VARCHAR(26),              -- nullable, FK to events
    org_id          VARCHAR(26) NOT NULL,     -- FK to organizations
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    cover_media_id  VARCHAR(26),              -- nullable, FK to album_media
    created_by      VARCHAR(26) NOT NULL,     -- user_id
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL,
    deleted_at      TIMESTAMP,                -- soft delete
    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE / ARCHIVED / DELETED
    
    FOREIGN KEY (org_id) REFERENCES organizations(id),
    FOREIGN KEY (event_id) REFERENCES events(id),
    INDEX idx_event_id (event_id),
    INDEX idx_org_id (org_id),
    INDEX idx_created_at (created_at),
    INDEX idx_deleted_at (deleted_at)
);

-- Album Media テーブル
CREATE TABLE album_media (
    id              VARCHAR(26) PRIMARY KEY,  -- ULID
    album_id        VARCHAR(26) NOT NULL,     -- FK
    media_id        VARCHAR(26) NOT NULL,     -- reference to Storage Service
    uploaded_by     VARCHAR(26) NOT NULL,     -- user_id
    caption         VARCHAR(1000),
    position        INT NOT NULL,             -- ordering
    added_at        TIMESTAMP NOT NULL,
    deleted_at      TIMESTAMP,                -- soft delete
    
    FOREIGN KEY (album_id) REFERENCES albums(id),
    UNIQUE KEY unique_position (album_id, position, deleted_at),
    INDEX idx_album_id (album_id),
    INDEX idx_media_id (media_id),
    INDEX idx_deleted_at (deleted_at)
);

-- Album Comments テーブル
CREATE TABLE album_comments (
    id              VARCHAR(26) PRIMARY KEY,  -- ULID
    album_id        VARCHAR(26) NOT NULL,     -- FK
    media_id        VARCHAR(26),              -- nullable, FK to album_media
    user_id         VARCHAR(26) NOT NULL,     -- FK to users
    body            TEXT NOT NULL,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL,
    deleted_at      TIMESTAMP,                -- soft delete
    
    FOREIGN KEY (album_id) REFERENCES albums(id),
    FOREIGN KEY (media_id) REFERENCES album_media(id),
    INDEX idx_album_id (album_id),
    INDEX idx_media_id (media_id),
    INDEX idx_user_id (user_id),
    INDEX idx_deleted_at (deleted_at)
);

-- Highlight Videos テーブル
CREATE TABLE highlight_videos (
    id              VARCHAR(26) PRIMARY KEY,  -- ULID
    album_id        VARCHAR(26) NOT NULL,     -- FK (UNIQUE)
    video_media_id  VARCHAR(26),              -- reference to Storage Service (nullable until READY)
    duration_secs   INT,
    status          VARCHAR(20) NOT NULL DEFAULT 'PENDING',  -- PENDING / READY / FAILED
    generated_at    TIMESTAMP,
    metadata_json   JSON,
    
    FOREIGN KEY (album_id) REFERENCES albums(id),
    UNIQUE KEY unique_album_id (album_id),
    INDEX idx_status (status),
    INDEX idx_generated_at (generated_at)
);

-- Album Access Control テーブル
CREATE TABLE album_access_control (
    id              VARCHAR(26) PRIMARY KEY,  -- ULID
    album_id        VARCHAR(26) NOT NULL,     -- FK
    user_id         VARCHAR(26) NOT NULL,     -- FK to users
    role            VARCHAR(20) NOT NULL,     -- viewer / contributor / owner
    granted_at      TIMESTAMP NOT NULL,
    
    FOREIGN KEY (album_id) REFERENCES albums(id),
    UNIQUE KEY unique_album_user (album_id, user_id),
    INDEX idx_album_id (album_id),
    INDEX idx_user_id (user_id),
    INDEX idx_role (role)
);
```

### 外部サービスアダプタ

| ポートインターフェース     | アダプタクラス               | 外部システム                                    |
| -------------------------- | ---------------------------- | ----------------------------------------------- |
| **PermissionService**      | HTTPPermissionServiceAdapter | Permission Service (http://permission-svc:8004) |
| **EventService**           | HTTPEventServiceAdapter      | Events Service (http://events-svc:8005)         |
| **StorageService**         | HTTPStorageServiceAdapter    | Storage Service (http://storage-svc:8001)       |
| **EventPublisher**         | QueueEventPublisher          | QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）Topic: `recuerdo.album.*` |
| **HighlightVideoJobQueue** | **Beta:** AsynqJobQueue / **本番:** OCIQueueJobAdapter | Beta: Redis + asynq（XServer VPS）/ 本番: OCI Queue Service。ジョブは FFmpeg concat をユーザー選択に従って実行 |

**アダプタコード例（HTTPPermissionServiceAdapter）**:

```go
type HTTPPermissionServiceAdapter struct {
    httpClient *http.Client
    baseURL    string
    timeout    time.Duration
}

func (a *HTTPPermissionServiceAdapter) CheckAccess(
    ctx context.Context,
    userID, albumID string,
    requiredRoles []Role,
) (Role, error) {
    req, _ := http.NewRequestWithContext(ctx,
        "POST",
        fmt.Sprintf("%s/api/check-access", a.baseURL),
        bytes.NewReader([]byte(fmt.Sprintf(
            `{"user_id":"%s","resource_id":"%s","required_roles":["%s"]}`,
            userID, albumID, strings.Join(rolesAsStrings(requiredRoles), `","`),
        ))))
    req.Header.Set("Content-Type", "application/json")
    
    resp, err := a.httpClient.Do(req)
    if err != nil {
        return "", fmt.Errorf("permission check failed: %w", err)
    }
    defer resp.Body.Close()
    
    if resp.StatusCode == 403 {
        return "", ErrAccessDenied
    }
    if resp.StatusCode != 200 {
        return "", fmt.Errorf("permission service returned %d", resp.StatusCode)
    }
    
    var result struct {
        Role string `json:"role"`
    }
    json.NewDecoder(resp.Body).Decode(&result)
    return Role(result.Role), nil
}
```

---

## 5. インフラストラクチャ層

### Webフレームワーク

| 項目             | 選択                    | 説明                               |
| ---------------- | ----------------------- | ---------------------------------- |
| **Framework**    | Gin Gonic               | Go の高速 HTTP フレームワーク      |
| **HTTP Routing** | Gin Router              | RESTful API ルーティング           |
| **Middleware**   | Custom + Gin Middleware | 認証、ロギング、エラーハンドリング |
| **Content Type** | application/json        | JSON レスポンス                    |
| **Port**         | 8006 (内部)             | マイクロサービス間通信用           |
| **Server Setup** | net/http + Gin          | Go 標準ライブラリ                  |

### データベース

| 項目                | 選択                 | 説明                                     |
| ------------------- | -------------------- | ---------------------------------------- |
| **RDBMS**           | MySQL 8.0 / MariaDB 10.11（互換性 CI テスト必須） | Beta: XServer VPS / 本番: OCI MySQL HeatWave |
| **Driver**          | go-sql-driver/mysql  | MySQL 8.0 / MariaDB 10.11 両対応         |
| **Connection Pool** | database/sql std pool | 接続プーリング                          |
| **Migration**       | golang-migrate / goose | DB スキーマ管理                        |
| **Cache**           | Redis 7.x            | album_media リスト キャッシュ (TTL: 5分) |
| **Redis Driver**    | go-redis/v9          | Redis クライアント                       |
| **Queue**           | Beta: Redis + asynq / 本番: OCI Queue Service | QueuePort 抽象化の裏側                |

### 主要ライブラリ・SDK

| ライブラリ                 | 目的                     | レイヤー          |
| -------------------------- | ------------------------ | ----------------- |
| **gin-gonic/gin**          | HTTPルーティング         | Interface Adapter |
| **go-redis/redis**         | Redis キャッシュ + Asynq | Infrastructure    |
| **hibiken/asynq**          | 非同期ジョブキュー（Beta Go 側）| Infrastructure |
| **bullmq** (Node ワーカー側) | 非同期ジョブキュー（Beta Node 側）| Infrastructure |
| **oracle/oci-go-sdk**      | OCI Queue Service クライアント（本番）| Infrastructure |
| **go-sql-driver/mysql**    | MySQL 8.0 / MariaDB 10.11 ドライバ | Infrastructure |
| **google/uuid** / **ulid** | ID 生成                  | Domain            |
| **spf13/viper**            | 設定管理                 | Infrastructure    |
| **sirupsen/logrus**        | ログ                     | Infrastructure    |
| **testify/assert**         | テスティングアサーション | Testing           |
| **sqlc**                   | SQL -> Go コード生成     | Infrastructure    |

### 依存性注入

```go
// uber-go/fx を使用した DI パターン

package main

import (
    "go.uber.org/fx"
    "recuerdo/album-svc/internal/domain"
    "recuerdo/album-svc/internal/application"
    "recuerdo/album-svc/internal/adapter"
    "recuerdo/album-svc/internal/infra"
)

func main() {
    app := fx.New(
        // Infrastructure Providers
        fx.Provide(infra.NewMySQLDB),
        fx.Provide(infra.NewRedisClient),
        fx.Provide(infra.NewQueueClient),       // Beta: Redis+BullMQ / asynq、本番: OCI Queue
        fx.Provide(infra.NewQueuePublisher),
        
        // Repository Providers
        fx.Provide(adapter.NewMySQLAlbumRepository),
        fx.Provide(adapter.NewMySQLAlbumMediaRepository),
        fx.Provide(adapter.NewMySQLCommentRepository),
        fx.Provide(adapter.NewMySQLHighlightVideoRepository),
        fx.Provide(adapter.NewRedisCache),
        
        // External Service Adapters
        fx.Provide(adapter.NewHTTPPermissionServiceAdapter),
        fx.Provide(adapter.NewHTTPEventServiceAdapter),
        fx.Provide(adapter.NewHTTPStorageServiceAdapter),
        fx.Provide(adapter.NewQueueEventPublisher),   // QueuePort: recuerdo.album.*
        fx.Provide(adapter.NewQueueJobAdapter),       // Beta: Asynq、本番: OCI Queue
        
        // Use Case Services
        fx.Provide(application.NewCreateAlbumUseCase),
        fx.Provide(application.NewGetEventAlbumUseCase),
        fx.Provide(application.NewAddMediaUseCase),
        fx.Provide(application.NewGetAlbumCommentsUseCase),
        // ... other use cases
        
        // HTTP Handlers / Controllers
        fx.Provide(adapter.NewAlbumController),
        fx.Provide(adapter.NewMediaController),
        fx.Provide(adapter.NewCommentController),
        
        // HTTP Router
        fx.Provide(adapter.NewGinRouter),
        
        // Server
        fx.Provide(infra.NewServer),
        
        // Invoke: Start server
        fx.Invoke(startServer),
    )
    
    app.Run()
}

func startServer(server *http.Server) error {
    return server.ListenAndServe()
}
```

---

## 6. ディレクトリ構成

### ディレクトリツリー

```
recuerdo-album-svc/
├── cmd/
│   ├── main.go                          # エントリーポイント
│   └── migrate.go                       # DB マイグレーション実行
│
├── internal/
│   ├── domain/
│   │   ├── album.go                     # Album エンティティ
│   │   ├── album_media.go               # AlbumMedia エンティティ
│   │   ├── comment.go                   # AlbumComment エンティティ
│   │   ├── highlight_video.go           # HighlightVideo エンティティ
│   │   ├── access_control.go            # AlbumAccessControl エンティティ
│   │   ├── value_objects.go             # AlbumTitle, Role, etc.
│   │   ├── errors.go                    # Domain errors (NotFound, etc)
│   │   └── events.go                    # Domain events
│   │
│   ├── application/
│   │   ├── dto/
│   │   │   ├── album_dto.go
│   │   │   ├── media_dto.go
│   │   │   ├── comment_dto.go
│   │   │   └── highlight_video_dto.go
│   │   │
│   │   ├── usecase/
│   │   │   ├── create_album.go
│   │   │   ├── get_event_album.go
│   │   │   ├── add_media.go
│   │   │   ├── remove_media.go
│   │   │   ├── reorder_media.go
│   │   │   ├── create_comment.go
│   │   │   ├── get_album_comments.go
│   │   │   ├── delete_comment.go
│   │   │   ├── get_highlight_video.go
│   │   │   ├── archive_album.go
│   │   │   └── ... (other use cases)
│   │   │
│   │   └── port/
│   │       ├── repository.go             # Repository interfaces
│   │       ├── event_publisher.go        # Event publisher interface
│   │       ├── permission_service.go     # Permission service interface
│   │       ├── event_service.go
│   │       ├── storage_service.go
│   │       ├── cache_service.go
│   │       └── job_queue.go
│   │
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── router.go                # Gin ルーター設定
│   │   │   ├── album_controller.go
│   │   │   ├── media_controller.go
│   │   │   ├── comment_controller.go
│   │   │   ├── highlight_controller.go
│   │   │   └── middleware.go
│   │   │
│   │   ├── repository/
│   │   │   ├── MySQL_album.go
│   │   │   ├── MySQL_media.go
│   │   │   ├── MySQL_comment.go
│   │   │   ├── MySQL_highlight_video.go
│   │   │   └── cache_decorator.go       # キャッシュ装飾
│   │   │
│   │   ├── external/
│   │   │   ├── permission_service_adapter.go
│   │   │   ├── event_service_adapter.go
│   │   │   ├── storage_service_adapter.go
│   │   │   ├── queue_event_publisher.go     # QueuePort 経由のイベント発行
│   │   │   └── queue_job_adapter.go         # Beta: Asynq、本番: OCI Queue
│   │   │
│   │   └── cli/
│   │       └── migrate.go                # マイグレーションコマンド
│   │
│   └── infra/
│       ├── config.go                    # 設定読み込み
│       ├── MySQL.go                  # MySQL 接続初期化
│       ├── redis.go                     # Redis 接続初期化
│       ├── queue.go                     # QueuePort 初期化（Beta: Redis+BullMQ / asynq、本番: OCI Queue）
│       ├── logger.go                    # ロガー初期化
│       └── server.go                    # HTTP サーバー初期化
│
├── migrations/
│   ├── 001_create_albums_table.up.sql
│   ├── 001_create_albums_table.down.sql
│   ├── 002_create_album_media_table.up.sql
│   ├── 002_create_album_media_table.down.sql
│   ├── 003_create_album_comments_table.up.sql
│   ├── 003_create_album_comments_table.down.sql
│   ├── 004_create_highlight_videos_table.up.sql
│   ├── 004_create_highlight_videos_table.down.sql
│   └── 005_create_album_access_control_table.up.sql
│
├── test/
│   ├── unit/
│   │   ├── domain/
│   │   │   ├── album_test.go
│   │   │   └── value_objects_test.go
│   │   │
│   │   ├── application/
│   │   │   ├── create_album_test.go
│   │   │   ├── add_media_test.go
│   │   │   └── ... (other use case tests)
│   │   │
│   │   └── adapter/
│   │       ├── repository/
│   │       │   ├── MySQL_album_test.go
│   │       │   └── ... (other repo tests)
│   │       │
│   │       └── http/
│   │           └── album_controller_test.go
│   │
│   ├── integration/
│   │   ├── album_flow_test.go            # エンドツーエンドフロー
│   │   ├── media_flow_test.go
│   │   └── testdb.go                     # テスト用 DB セットアップ
│   │
│   └── fixtures/
│       ├── albums.json
│       └── media.json
│
├── config/
│   ├── config.yaml                      # 本番用設定
│   ├── config.dev.yaml                  # 開発用設定
│   └── config.test.yaml                 # テスト用設定
│
├── go.mod
├── go.sum
├── Makefile
├── Dockerfile
└── README.md
```

---

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー                    | テスト種別              | モック戦略                           | カバレッジ目標   |
| --------------------------- | ----------------------- | ------------------------------------ | ---------------- |
| **Domain**                  | Unit Test               | なし（純粋なロジック）               | 100%             |
| **Application (Use Cases)** | Unit Test               | リポジトリ・ポート全てをモック       | 90%+             |
| **Adapter (HTTP)**          | Unit Test + Integration | リポジトリはモック、他ポートはスタブ | 85%+             |
| **Adapter (Repository)**    | Integration Test        | テスト用 MySQL (testcontainers)      | 90%+             |
| **External Services**       | Contract Test           | HTTP モックサーバー (httptest)       | -                |
| **E2E**                     | Integration Flow        | 実 MySQL + Redis                     | 主要ユースケース |

### テストコード例

**1. ドメイン テスト (Unit)**:

```go
// test/unit/domain/album_test.go
package domain_test

import (
    "testing"
    "github.com/stretchr/testify/assert"
    "recuerdo/album-svc/internal/domain"
)

func TestNewAlbumTitle_ValidInput(t *testing.T) {
    title, err := domain.NewAlbumTitle("My Album")
    assert.NoError(t, err)
    assert.Equal(t, "My Album", title.Value)
}

func TestNewAlbumTitle_TooShort(t *testing.T) {
    _, err := domain.NewAlbumTitle("")
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "must be 1-200 characters")
}

func TestNewAlbumTitle_TooLong(t *testing.T) {
    longTitle := strings.Repeat("a", 201)
    _, err := domain.NewAlbumTitle(longTitle)
    assert.Error(t, err)
}
```

**2. ユースケース テスト (Unit)**:

```go
// test/unit/application/add_media_test.go
package application_test

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "recuerdo/album-svc/internal/application"
    "recuerdo/album-svc/internal/domain"
)

type MockAlbumRepository struct {
    mock.Mock
}

func (m *MockAlbumRepository) GetByID(ctx context.Context, albumID string) (*domain.Album, error) {
    args := m.Called(ctx, albumID)
    if args.Get(0) == nil {
        return nil, args.Error(1)
    }
    return args.Get(0).(*domain.Album), args.Error(1)
}

type MockPermissionService struct {
    mock.Mock
}

func (m *MockPermissionService) CheckAccess(ctx context.Context, userID, albumID string, requiredRoles []domain.Role) (domain.Role, error) {
    args := m.Called(ctx, userID, albumID, requiredRoles)
    return domain.Role(args.String(0)), args.Error(1)
}

func TestAddMedia_Success(t *testing.T) {
    // Setup
    mockAlbumRepo := new(MockAlbumRepository)
    mockPermissionSvc := new(MockPermissionService)
    mockMediaRepo := new(MockAlbumMediaRepository)
    mockEventPub := new(MockEventPublisher)
    mockJobQueue := new(MockJobQueue)

    album := &domain.Album{
        ID:    "album-1",
        OrgID: "org-1",
    }

    mockAlbumRepo.On("GetByID", mock.Anything, "album-1").Return(album, nil)
    mockPermissionSvc.On("CheckAccess", mock.Anything, "user-1", "album-1", 
        []domain.Role{domain.RoleContributor, domain.RoleOwner}).Return(domain.RoleContributor, nil)
    mockMediaRepo.On("Save", mock.Anything, mock.Anything).Return(nil)
    mockEventPub.On("PublishMediaAdded", mock.Anything, mock.Anything).Return(nil)
    mockJobQueue.On("EnqueueGenerateHighlightVideo", mock.Anything, "album-1", mock.Anything).Return(nil)

    // Execute
    usecase := application.NewAddMediaUseCase(
        mockAlbumRepo,
        mockMediaRepo,
        mockPermissionSvc,
        mockEventPub,
        mockJobQueue,
    )

    input := &application.AddMediaInput{
        AlbumID:   "album-1",
        MediaID:   "media-1",
        UploadedBy: "user-1",
        Caption:   "Summer memories",
    }

    output, err := usecase.Execute(context.Background(), input)

    // Assert
    assert.NoError(t, err)
    assert.NotNil(t, output)
    assert.Equal(t, "media-1", output.MediaID)
    mockAlbumRepo.AssertExpectations(t)
    mockPermissionSvc.AssertExpectations(t)
}

func TestAddMedia_AccessDenied(t *testing.T) {
    mockAlbumRepo := new(MockAlbumRepository)
    mockPermissionSvc := new(MockPermissionService)

    album := &domain.Album{ID: "album-1"}
    mockAlbumRepo.On("GetByID", mock.Anything, "album-1").Return(album, nil)
    mockPermissionSvc.On("CheckAccess", mock.Anything, "user-1", "album-1", mock.Anything).
        Return(domain.RoleViewer, domain.ErrAccessDenied)

    usecase := application.NewAddMediaUseCase(mockAlbumRepo, nil, mockPermissionSvc, nil, nil)

    input := &application.AddMediaInput{
        AlbumID:   "album-1",
        UploadedBy: "user-1",
    }

    _, err := usecase.Execute(context.Background(), input)
    assert.Error(t, err)
    assert.Equal(t, domain.ErrAccessDenied, err)
}
```

**3. HTTP コントローラ テスト (Integration)**:

```go
// test/unit/adapter/http/album_controller_test.go
package http_test

import (
    "bytes"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"
    "github.com/gin-gonic/gin"
    "github.com/stretchr/testify/assert"
    "recuerdo/album-svc/internal/adapter/http"
)

func TestGetEventAlbum_Success(t *testing.T) {
    gin.SetMode(gin.TestMode)
    router := gin.New()

    // Setup mock use case
    mockUseCase := new(MockGetEventAlbumUseCase)
    mockUseCase.On("Execute", mock.Anything, mock.Anything).Return(&application.AlbumOutput{
        ID:    "album-1",
        Title: "Summer Reunion 2026",
    }, nil)

    controller := http.NewAlbumController(mockUseCase)
    router.GET("/api/orgs/:org_id/events/:event_id/album", controller.GetEventAlbum)

    // Execute
    req := httptest.NewRequest(http.MethodGet, "/api/orgs/org-1/events/event-1/album", nil)
    req.Header.Set("X-User-ID", "user-1")
    w := httptest.NewRecorder()

    router.ServeHTTP(w, req)

    // Assert
    assert.Equal(t, http.StatusOK, w.Code)
    var resp struct {
        Data struct {
            ID    string `json:"id"`
            Title string `json:"title"`
        } `json:"data"`
    }
    json.NewDecoder(w.Body).Decode(&resp)
    assert.Equal(t, "album-1", resp.Data.ID)
}
```

**4. リポジトリ テスト (Integration)**:

```go
// test/integration/repository/MySQL_album_test.go
package repository_test

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "recuerdo/album-svc/internal/adapter/repository"
    "recuerdo/album-svc/test/integration"
)

func TestMySQLAlbumRepository_Save(t *testing.T) {
    db := integration.SetupTestDB(t)
    defer db.Close()

    repo := repository.NewMySQLAlbumRepository(db)
    album := &domain.Album{
        ID:    "album-1",
        OrgID: "org-1",
        Title: domain.AlbumTitle{Value: "Test Album"},
        CreatedBy: "user-1",
    }

    err := repo.Save(context.Background(), album)
    assert.NoError(t, err)

    retrieved, err := repo.GetByID(context.Background(), "album-1")
    assert.NoError(t, err)
    assert.Equal(t, album.ID, retrieved.ID)
}
```

---

## 8. エラーハンドリング

### ドメインエラー

```go
// internal/domain/errors.go

package domain

import "errors"

var (
    // Album errors
    ErrAlbumNotFound          = errors.New("album not found")
    ErrAlbumAlreadyExists     = errors.New("album already exists")
    ErrAlbumArchived          = errors.New("album is archived")
    ErrInvalidAlbumTitle      = errors.New("invalid album title")
    
    // Media errors
    ErrMediaNotFound          = errors.New("media not found")
    ErrMediaAlreadyInAlbum    = errors.New("media already in this album")
    ErrInvalidPosition        = errors.New("invalid position")
    ErrMediaCountInsufficient = errors.New("album must have at least 10 media items")
    
    // Comment errors
    ErrCommentNotFound        = errors.New("comment not found")
    ErrInvalidCommentBody     = errors.New("invalid comment body")
    
    // Access control errors
    ErrAccessDenied           = errors.New("access denied")
    ErrInvalidRole            = errors.New("invalid role")
    ErrNoOwner                = errors.New("album must have at least one owner")
    
    // Highlight video errors
    ErrHighlightVideoInProgress = errors.New("highlight video generation in progress")
    ErrHighlightVideoFailed     = errors.New("highlight video generation failed")
    
    // Event errors
    ErrEventNotFound          = errors.New("event not found")
    ErrEventAlbumAlreadyExists = errors.New("event already has an album")
    
    // Validation errors
    ErrInvalidInput           = errors.New("invalid input")
    ErrMissingField           = errors.New("missing required field")
)
```

### エラー → HTTPステータスマッピング

| ドメインエラー                  | HTTPステータス  | ユーザーメッセージ                                |
| ------------------------------- | --------------- | ------------------------------------------------- |
| **ErrAlbumNotFound**            | 404 Not Found   | `Album not found`                                 |
| **ErrMediaNotFound**            | 404 Not Found   | `Media not found`                                 |
| **ErrCommentNotFound**          | 404 Not Found   | `Comment not found`                               |
| **ErrAccessDenied**             | 403 Forbidden   | `You do not have permission to access this album` |
| **ErrAlbumArchived**            | 409 Conflict    | `Album is archived and cannot be modified`        |
| **ErrInvalidAlbumTitle**        | 400 Bad Request | `Album title must be 1-200 characters`            |
| **ErrInvalidCommentBody**       | 400 Bad Request | `Comment must be 1-5000 characters`               |
| **ErrMediaAlreadyInAlbum**      | 409 Conflict    | `Media already added to this album`               |
| **ErrMediaCountInsufficient**   | 400 Bad Request | `Album must have at least 10 media items`         |
| **ErrHighlightVideoInProgress** | 409 Conflict    | `Highlight video generation is in progress`       |
| **ErrInvalidRole**              | 400 Bad Request | `Invalid role specified`                          |
| **ErrNoOwner**                  | 409 Conflict    | `Album must have at least one owner`              |
| **ErrEventNotFound**            | 404 Not Found   | `Event not found`                                 |
| **ErrEventAlbumAlreadyExists**  | 409 Conflict    | `Event already has an album`                      |
| **ErrInvalidInput**             | 400 Bad Request | `Invalid input provided`                          |
| **ErrMissingField**             | 400 Bad Request | `Missing required field: {field_name}`            |

**エラーハンドリング Middleware**:

```go
// internal/adapter/http/error_handler.go

package http

import (
    "github.com/gin-gonic/gin"
    "recuerdo/album-svc/internal/domain"
)

func ErrorHandlerMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        c.Next()

        if len(c.Errors) > 0 {
            err := c.Errors[0].Err
            
            // Domain errors
            switch err {
            case domain.ErrAlbumNotFound:
                c.JSON(404, gin.H{"error": "Album not found"})
            case domain.ErrAccessDenied:
                c.JSON(403, gin.H{"error": "You do not have permission to access this album"})
            case domain.ErrInvalidAlbumTitle:
                c.JSON(400, gin.H{"error": "Album title must be 1-200 characters"})
            default:
                c.JSON(500, gin.H{"error": "Internal server error"})
            }
        }
    }
}
```

---

## 9. 未決事項

### 質問・決定事項

| #   | 質問                                                                              | ステータス | 決定                                                                 |
| --- | --------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------- |
| 1   | **Media storage format**: 写真と動画で異なる処理が必要か？                        | ✅ Decided | Storage Service が HLS（動画）/ JPEG+WebP（HEIC 変換）を生成。Album-svc は `metadata_id` のみ保持 |
| 2   | **Highlight video algorithm**: どのメディアを選出するのか？                       | ✅ Decided | **ユーザーが明示的に 2 本以上を選択したうえで FFmpeg concat で連結。ML による自動選定・自動生成は行わない** |
| 3   | **Album soft delete retention**: 削除済みアルバムの保持期間は？                   | ✅ Decided | 90 日間（Soft Delete）→ バッチで物理削除                             |
| 4   | **Comment moderation**: コメント内容の審査機能は必要か？                          | ✅ Decided | admin-console-svc のモデレーションキュー連携（QueuePort トピック `recuerdo.moderation.requested`） |
| 5   | **Real-time notifications**: アルバム更新時の Push 通知は必要か？                 | ✅ Decided | notifications-svc へ QueuePort `recuerdo.album.updated` を発行、FCM 配信 |
| 6   | **Bulk operations**: 複数メディアの一括削除は実装対象か？                         | ✅ Decided | MVP では個別削除のみ。v2 で一括削除エンドポイントを追加              |
| 7   | **Cache invalidation strategy**: Redis キャッシュの無効化戦略は？                 | ✅ Decided | TTL 5 分 + QueuePort イベント受信時の即時削除                        |
| 8   | **Concurrent media reorder**: 同時に複数ユーザーが reorder した場合の競合制御は？ | ✅ Decided | Optimistic locking（`version` 列、UPDATE ... WHERE version = ?）    |
| 9   | **Highlight video SLA**: 生成ジョブの完了時間は？                                 | ✅ Decided | p95 ≤ 5 分（優先度 normal、FFmpeg concat のみのため短時間）          |
| 10  | **Cross-org album visibility**: 異なる org のアルバム参照は可能か？               | ✅ Decided | `org_id` スコープ必須、クロスオーグ参照は不可                        |


---

最終更新: 2026-04-19 ポリシー適用
