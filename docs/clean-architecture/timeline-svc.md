# クリーンアーキテクチャ設計書

| 項目                      | 値                                       |
| ------------------------- | ---------------------------------------- |
| **モジュール/サービス名** | Timeline Service (recuerdo-timeline-svc) |
| **作成者**                | Akira                                    |
| **作成日**                | 2026-04-13                               |
| **ステータス**            | ドラフト                                 |
| **バージョン**            | 1.0                                      |

---

## 1. 概要

### 1.1 目的
Timeline Service はRecuerdo プラットフォームにおいて、すべてのユーザー活動を時系列でアグリゲートし、個人フィード・組織フィードとして提供する、いわば"メモリレイヤー"である。ユーザーや組織が過去の活動（イベント作成、アルバム追加、友人参加）を振り返ることができる中核サービス。

### 1.2 ビジネスコンテキスト
- Recuerdo はノスタルジアと再接続をテーマとするソーシャルメモリプラットフォーム
- Timeline は個人履歴＆組織記録の両面：「私は誰とどんな時を過ごしたか」「我々の組織はどう成長したか」
- プライベート（個人のみ）、フレンドリー（親友）、パブリック（公開）の3段階の可視性管理
- イベント駆動アーキテクチャのコンシューマ：他すべてのサービスから通知を受け取る

### 1.3 アーキテクチャ原則
- **イベント駆動型**：SQS メッセージをリスニング、TimelineItem を非同期作成
- **アクセス制御**：可視性ルール（PRIVATE/FRIENDS/PUBLIC）をドメイン層で保護
- **スケーラビリティ**：月次パーティショニング（MySQL）+ Redis ソートセット FIFOキャッシュ
- **イミュータビリティ**：TimelineItem は削除されない、表示/非表示フラグで制御

---

## 2. レイヤーアーキテクチャ

### 2.1 アーキテクチャ図 (ASCII concentric circles)

```
┌─────────────────────────────────────────────────────┐
│  フレームワーク＆ドライバ層                          │
│  (Web: Gin, DB: MySQL, Queue: SQS consumer)  │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  インターフェースアダプタ層                        │
│  (HTTP Handler, Repository Impl,                  │
│   SQS Message Consumer, Presenter)                │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  ユースケース層 (アプリケーション)                │
│  (CreateTimelineItem, GetUserTimeline,            │
│   GetOrgTimeline, HideTimelineItem)               │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  エンティティ層 (ドメイン)                        │
│  (TimelineItem, TimelinePayload,                  │
│   Visibility ルール、値オブジェクト)              │
└─────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール
- **内向き依存のみ**：Adapter → UseCase → Domain
- **SQS メッセージはホストサービス扱い**：外側（インフラ）から内側（ドメイン）への入力
- **可視性チェック**：Permission Service 呼び出しはアダプタ層の責務

---

## 3. エンティティ層（ドメイン）

### 3.1 ドメインモデル

| エンティティ     | 説明                                                                   |
| ---------------- | ---------------------------------------------------------------------- |
| **TimelineItem** | 時系列で記録される単一の活動：イベント作成、メディア追加、友人参加など |
| **FeedCursor**   | ページネーション状態：last_seen_id + occurred_at タプル                |

### 3.2 値オブジェクト

| 値オブジェクト       | 許可される値                                                                                                              | 不変性                             |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| **TimelineItemType** | EVENT_CREATED, ALBUM_CREATED, MEDIA_ADDED, FRIEND_JOINED, EVENT_INVITATION_ACCEPTED, HIGHLIGHT_VIDEO_READY, MEMORY_SHARED | イミュータブル（列挙値）           |
| **Visibility**       | PUBLIC, FRIENDS, PRIVATE                                                                                                  | イミュータブル、ドメインルール適用 |
| **FeedCursor**       | (last_seen_id: string, occurred_at: timestamp)                                                                            | イミュータブル                     |
| **TimelinePayload**  | item_type に応じて異なる JSON 構造                                                                                        | イミュータブル（JSONB）            |

### 3.3 ドメインルール / 不変条件

- **Visibility ルール**：PRIVATE は owner のみ、FRIENDS は接続ユーザーのみ、PUBLIC は全員
- **Immutability**：TimelineItem は作成後変更不可（hidden フラグでのみ制御）
- **Occurred At Immutability**：occurred_at は作成時に固定、イベント発生時刻を記録
- **Organization Timeline Filter**：org timeline は FRIENDS/PUBLIC のみ表示、PRIVATE は除外
- **Hidden Flag**：item は delete されず、hidden=true で表示除外
- **Payload Validation**：TimelinePayload は item_type に応じた構造を強制（スキーマ検証）

### 3.4 ドメインイベント

| イベント                | トリガー                | ペイロード                                      | 購読者                                      |
| ----------------------- | ----------------------- | ----------------------------------------------- | ------------------------------------------- |
| **TimelineItemCreated** | CreateTimelineItem 成功 | item_id, user_id, org_id, item_type, visibility | Notification Svc (ユーザーフィード更新通知) |
| **TimelineItemHidden**  | HideTimelineItem 成功   | item_id, hidden_by                              | Notification Svc (UI 更新通知)              |

### 3.5 エンティティ定義 (Go pseudocode)

```go
package domain

import (
    "database/sql"
    "encoding/json"
    "time"
)

// TimelineItemType は Timeline 上の活動の種類
type TimelineItemType string

const (
    TimelineItemTypeEventCreated            TimelineItemType = "EVENT_CREATED"
    TimelineItemTypeAlbumCreated            TimelineItemType = "ALBUM_CREATED"
    TimelineItemTypeMediaAdded              TimelineItemType = "MEDIA_ADDED"
    TimelineItemTypeFriendJoined            TimelineItemType = "FRIEND_JOINED"
    TimelineItemTypeEventInvitationAccepted TimelineItemType = "EVENT_INVITATION_ACCEPTED"
    TimelineItemTypeHighlightVideoReady     TimelineItemType = "HIGHLIGHT_VIDEO_READY"
    TimelineItemTypeMemoryShared            TimelineItemType = "MEMORY_SHARED"
)

// Visibility 可視性レベル
type Visibility string

const (
    VisibilityPrivate  Visibility = "PRIVATE"   // 所有者のみ
    VisibilityFriends  Visibility = "FRIENDS"   // 接続ユーザー
    VisibilityPublic   Visibility = "PUBLIC"    // すべてのメンバー
)

// TimelinePayload item_type に応じた可変構造（JSONB）
type TimelinePayload struct {
    data map[string]interface{}
}

func NewTimelinePayload(itemType TimelineItemType, data map[string]interface{}) (*TimelinePayload, error) {
    if !isValidPayloadForType(itemType, data) {
        return nil, fmt.Errorf("invalid payload for item type %s", itemType)
    }
    return &TimelinePayload{data: data}, nil
}

func (p *TimelinePayload) MarshalJSON() ([]byte, error) {
    return json.Marshal(p.data)
}

func (p *TimelinePayload) UnmarshalJSON(b []byte) error {
    return json.Unmarshal(b, &p.data)
}

// FeedCursor カーソルベースのページネーション
type FeedCursor struct {
    LastSeenID string    // last_seen timeline_item id
    OccurredAt time.Time // last occurred_at timestamp
}

func NewFeedCursor(lastSeenID string, occurredAt time.Time) FeedCursor {
    return FeedCursor{
        LastSeenID: lastSeenID,
        OccurredAt: occurredAt,
    }
}

// Encode カーソルをコードに変換（API レスポンスで使用）
func (fc FeedCursor) Encode() string {
    // Base64 エンコード: "{lastSeenID}:{occurredAt.Unix()}"
    data := fmt.Sprintf("%s:%d", fc.LastSeenID, fc.OccurredAt.Unix())
    return base64.StdEncoding.EncodeToString([]byte(data))
}

// TimelineItem ドメインエンティティ
type TimelineItem struct {
    ID        string              // ULID
    UserID    *string             // 個人活動の場合のみ; NULL なら org_id が主体
    OrgID     *string             // 組織活動の場合のみ
    EventID   *string             // イベント関連活動の場合のみ
    ItemType  TimelineItemType
    Payload   *TimelinePayload    // JSON
    OccurredAt time.Time          // イベント発生時刻（イミュータブル）
    Visibility Visibility
    Hidden    bool                // soft delete フラグ
    HiddenBy  *string             // who hid it
    HiddenAt  *time.Time
    CreatedAt time.Time
    domainEvents []interface{}
}

// NewTimelineItem ファクトリメソッド
func NewTimelineItem(
    userID *string,
    orgID *string,
    eventID *string,
    itemType TimelineItemType,
    payload *TimelinePayload,
    occurredAt time.Time,
    visibility Visibility,
) (*TimelineItem, error) {
    // バリデーション：user_id か org_id いずれか必須
    if (userID == nil || *userID == "") && (orgID == nil || *orgID == "") {
        return nil, fmt.Errorf("either user_id or org_id required")
    }
    
    if payload == nil {
        return nil, fmt.Errorf("payload required")
    }
    
    item := &TimelineItem{
        ID:         generateULID(),
        UserID:     userID,
        OrgID:      orgID,
        EventID:    eventID,
        ItemType:   itemType,
        Payload:    payload,
        OccurredAt: occurredAt,
        Visibility: visibility,
        Hidden:     false,
        CreatedAt:  time.Now(),
    }
    
    item.recordEvent(&TimelineItemCreatedEvent{
        ItemID:    item.ID,
        UserID:    userID,
        OrgID:     orgID,
        ItemType:  itemType,
        Visibility: visibility,
        CreatedAt: time.Now(),
    })
    
    return item, nil
}

// Hide soft delete
func (ti *TimelineItem) Hide(hiddenBy string) error {
    if ti.Hidden {
        return fmt.Errorf("already hidden")
    }
    ti.Hidden = true
    ti.HiddenBy = &hiddenBy
    now := time.Now()
    ti.HiddenAt = &now
    
    ti.recordEvent(&TimelineItemHiddenEvent{
        ItemID:   ti.ID,
        HiddenBy: hiddenBy,
        HiddenAt: now,
    })
    
    return nil
}

// IsVisibleTo 可視性チェック（アクセス制御）
func (ti *TimelineItem) IsVisibleTo(viewerID string, isConnected bool) bool {
    if ti.Hidden {
        return false
    }
    
    // 所有者には常に見える
    if ti.UserID != nil && *ti.UserID == viewerID {
        return true
    }
    
    switch ti.Visibility {
    case VisibilityPrivate:
        return ti.UserID != nil && *ti.UserID == viewerID
    case VisibilityFriends:
        return isConnected
    case VisibilityPublic:
        return true
    default:
        return false
    }
}

// DomainEvents ドメインイベント取得＆クリア
func (ti *TimelineItem) DomainEvents() []interface{} {
    events := ti.domainEvents
    ti.domainEvents = []interface{}{}
    return events
}

func (ti *TimelineItem) recordEvent(event interface{}) {
    ti.domainEvents = append(ti.domainEvents, event)
}

// ドメインイベント
type TimelineItemCreatedEvent struct {
    ItemID     string
    UserID     *string
    OrgID      *string
    ItemType   TimelineItemType
    Visibility Visibility
    CreatedAt  time.Time
}

type TimelineItemHiddenEvent struct {
    ItemID   string
    HiddenBy string
    HiddenAt time.Time
}

// ペイロード構造の例（item_type ごと）
func EventCreatedPayload(eventID, eventTitle, createdBy string) map[string]interface{} {
    return map[string]interface{}{
        "event_id":  eventID,
        "title":     eventTitle,
        "created_by": createdBy,
    }
}

func AlbumCreatedPayload(albumID, albumName, eventID string) map[string]interface{} {
    return map[string]interface{}{
        "album_id":  albumID,
        "name":      albumName,
        "event_id":  eventID,
    }
}
```

---

## 4. ユースケース層（アプリケーション）

### 4.1 ユースケース一覧

| ユースケース           | 説明                                                 | アクター                | 主成功シナリオ                                           |
| ---------------------- | ---------------------------------------------------- | ----------------------- | -------------------------------------------------------- |
| **CreateTimelineItem** | SQS メッセージから TimelineItem 作成（非同期）       | SQS Consumer            | メッセージパース、ドメイン構築、DB 保存、キャッシュ更新  |
| **GetUserTimeline**    | ユーザーの個人フィード取得                           | Org Member              | カーソルベースページング、可視性フィルタ、キャッシュ活用 |
| **GetOrgTimeline**     | 組織フィード取得                                     | Org Member              | PUBLIC/FRIENDS のみ、個人 PRIVATE 除外、ページング       |
| **HideTimelineItem**   | アイテムを非表示（soft delete）                      | Item Owner or Org Admin | Hidden=true 設定、キャッシュ無効化                       |
| **GetUserFeed**        | ユーザーのカスタマイズされたフィード（友人活動含む） | Org Member              | グラフベース可視性チェック、マージソート（時系列）       |

### 4.2 ユースケース詳細 (CreateTimelineItem - main use case)

**Actor**: SQS Consumer (非同期ワーカー)

**Pre-conditions**:
- SQS キューに JSON メッセージあり
- メッセージスキーマ有効

**Main Flow**:
1. SQS メッセージ受信（例：EventCreatedEvent）
2. JSON をドメインイベント型にパース
3. TimelineItemType を決定（EventCreated → EVENT_CREATED）
4. TimelinePayload を構築（バリデーション含む）
5. Visibility を決定（EVENT_CREATED の場合は FRIENDS）
6. TimelineItem.NewTimelineItem() でドメインエンティティ作成
7. TimelineRepository.Save() で DB 保存
8. FeedCache を無効化（affected user/org）
9. DomainEvents を取得、Notification Service 呼び出し

**Post-conditions**:
- TimelineItem が DB に保存（月次パーティション）
- ユーザーフィード Redis キャッシュ無効化
- TimelineItemCreatedEvent が Notification Service に送信

**Errors**:
- メッセージパース失敗：`ErrInvalidMessage`
- ペイロード検証失敗：`ErrInvalidPayload`
- DB 保存失敗：`ErrPersistenceFailed`（リトライ対象）

### 4.3 入出力DTO (Go struct pseudocode)

```go
package application

// CreateTimelineItemRequest SQS メッセージペイロード
type CreateTimelineItemRequest struct {
    EventType   string                 `json:"event_type"` // EventCreated, AlbumCreated など
    UserID      *string                `json:"user_id,omitempty"`
    OrgID       *string                `json:"org_id,omitempty"`
    EventID     *string                `json:"event_id,omitempty"`
    Payload     map[string]interface{} `json:"payload"`
    OccurredAt  time.Time              `json:"occurred_at"`
    Visibility  string                 `json:"visibility"` // PUBLIC, FRIENDS, PRIVATE
}

// CreateTimelineItemResponse
type CreateTimelineItemResponse struct {
    ItemID    string    `json:"item_id"`
    ItemType  string    `json:"item_type"`
    CreatedAt time.Time `json:"created_at"`
}

// GetUserTimelineRequest
type GetUserTimelineRequest struct {
    UserID string  `json:"user_id"`
    Limit  int     `json:"limit"`       // default: 20, max: 100
    Cursor *string `json:"cursor,omitempty"` // base64 encoded
}

// GetUserTimelineResponse
type GetUserTimelineResponse struct {
    Items      []TimelineItemDTO `json:"items"`
    NextCursor *string           `json:"next_cursor,omitempty"`
    Total      int64             `json:"total"`
}

// TimelineItemDTO プレゼンテーション用
type TimelineItemDTO struct {
    ID         string                 `json:"id"`
    ItemType   string                 `json:"item_type"`
    Payload    map[string]interface{} `json:"payload"`
    OccurredAt time.Time              `json:"occurred_at"`
    Visibility string                 `json:"visibility"`
    CreatedAt  time.Time              `json:"created_at"`
}

// GetOrgTimelineRequest
type GetOrgTimelineRequest struct {
    OrgID  string  `json:"org_id"`
    Limit  int     `json:"limit"`
    Cursor *string `json:"cursor,omitempty"`
}

// HideTimelineItemRequest
type HideTimelineItemRequest struct {
    ItemID  string `json:"item_id"`
    HiddenBy string `json:"hidden_by"` // user_id
}

// GetUserFeedRequest（拡張フィード：友人活動含む）
type GetUserFeedRequest struct {
    UserID string `json:"user_id"`
    Limit  int    `json:"limit"`
    Offset int    `json:"offset"`
}

// GetUserFeedResponse
type GetUserFeedResponse struct {
    Items []TimelineItemDTO `json:"items"` // マージ済み、時系列順
    Total int64             `json:"total"`
}
```

### 4.4 リポジトリインターフェース（ポート）

```go
package application

import "context"

// TimelineItemRepository Timeline Item 永続化のポート
type TimelineItemRepository interface {
    // Save TimelineItem を保存
    Save(ctx context.Context, item *domain.TimelineItem) error
    
    // FindByID ID で検索
    FindByID(ctx context.Context, itemID string) (*domain.TimelineItem, error)
    
    // ListByUser ユーザーの timeline（ページング）
    ListByUser(ctx context.Context, userID string, limit int, cursor *domain.FeedCursor) ([]*domain.TimelineItem, *domain.FeedCursor, error)
    
    // ListByOrg 組織の timeline（ページング）
    ListByOrg(ctx context.Context, orgID string, limit int, cursor *domain.FeedCursor) ([]*domain.TimelineItem, *domain.FeedCursor, error)
    
    // ListByEvent イベント関連アイテム
    ListByEvent(ctx context.Context, eventID string) ([]*domain.TimelineItem, error)
    
    // Update アイテム更新（Hidden フラグなど）
    Update(ctx context.Context, item *domain.TimelineItem) error
    
    // CountByUser ユーザーのアイテム総数
    CountByUser(ctx context.Context, userID string) (int64, error)
}

// FeedCacheRepository フィードキャッシュのポート（Redis）
type FeedCacheRepository interface {
    // GetUserFeed ユーザーフィード取得（Redis sorted set）
    GetUserFeed(ctx context.Context, userID string, start, stop int) ([]string, error)
    
    // InvalidateUserFeed ユーザーフィードキャッシュ無効化
    InvalidateUserFeed(ctx context.Context, userID string) error
    
    // InvalidateOrgFeed 組織フィードキャッシュ無効化
    InvalidateOrgFeed(ctx context.Context, orgID string) error
}
```

### 4.5 外部サービスインターフェース（ポート）

```go
package application

// PermissionService アクセス制御のポート（gRPC）
type PermissionService interface {
    // IsUserConnected ユーザー間の接続状態チェック
    IsUserConnected(ctx context.Context, userID1, userID2 string) (bool, error)
    
    // CanViewItem ユーザーがアイテムを見られるか
    CanViewItem(ctx context.Context, viewerID string, item *domain.TimelineItem) (bool, error)
}

// NotificationService 通知サービスのポート
type NotificationService interface {
    // NotifyFeedUpdate フィード更新通知
    NotifyFeedUpdate(ctx context.Context, userID, itemID string) error
}

// SQSMessageConsumer SQS コンシューマのポート
type SQSMessageConsumer interface {
    // Listen SQS メッセージリスニング開始
    Listen(ctx context.Context, handler func(ctx context.Context, message interface{}) error) error
}
```

---

## 5. インターフェースアダプタ層

### 5.1 コントローラ / ハンドラ

| ハンドラ                      | HTTP Method  | Path                      | 入力         | 出力                       | 責務                                       |
| ----------------------------- | ------------ | ------------------------- | ------------ | -------------------------- | ------------------------------------------ |
| **GetUserTimelineHandler**    | GET          | /api/timelines/users/{id} | Query params | GetUserTimelineResponse    | ページング、可視性フィルタ、キャッシュ確認 |
| **GetOrgTimelineHandler**     | GET          | /api/timelines/orgs/{id}  | Query params | GetUserTimelineResponse    | 組織フィルタ、PRIVATE 除外                 |
| **HideTimelineItemHandler**   | DELETE       | /api/timeline-items/{id}  | -            | StatusResponse             | 権限チェック、Hidden 設定                  |
| **GetUserFeedHandler**        | GET          | /api/feeds/users/{id}     | Query params | GetUserFeedResponse        | 友人グラフ結合、統合ソート                 |
| **SQSMessageConsumerHandler** | (background) | (async)                   | SQS message  | CreateTimelineItemResponse | メッセージパース、ドメイン構築             |

### 5.2 プレゼンター / レスポンスマッパー

```go
package adapter

// TimelinePresenter ドメインモデル → HTTP レスポンス
type TimelinePresenter struct {
    cache *feedCacheProvider
}

// PresentTimelineItemDTO TimelineItem → DTO
func (p *TimelinePresenter) PresentTimelineItemDTO(item *domain.TimelineItem) *TimelineItemDTO {
    return &TimelineItemDTO{
        ID:         item.ID,
        ItemType:   string(item.ItemType),
        Payload:    item.Payload.Data(),
        OccurredAt: item.OccurredAt,
        Visibility: string(item.Visibility),
        CreatedAt:  item.CreatedAt,
    }
}

// PresentUserTimelineResponse ユーザーフィード レスポンス
func (p *TimelinePresenter) PresentUserTimelineResponse(
    items []*domain.TimelineItem,
    nextCursor *domain.FeedCursor,
    total int64,
) *GetUserTimelineResponse {
    dtos := make([]TimelineItemDTO, len(items))
    for i, item := range items {
        dtos[i] = *p.PresentTimelineItemDTO(item)
    }
    
    var cursorStr *string
    if nextCursor != nil {
        encoded := nextCursor.Encode()
        cursorStr = &encoded
    }
    
    return &GetUserTimelineResponse{
        Items:      dtos,
        NextCursor: cursorStr,
        Total:      total,
    }
}
```

### 5.3 リポジトリ実装（アダプタ）

| リポジトリ実装                  | 対象                     | 技術                                           | キャッシング戦略                            |
| ------------------------------- | ------------------------ | ---------------------------------------------- | ------------------------------------------- |
| **MySQLTimelineItemRepository** | TimelineItem             | `database/sql` + sqlc + 月次パーティショニング | リスト結果→Redis sorted set (TTL 10min)     |
| **RedisTimelineItemCache**      | Timeline Item キャッシュ | Redis Sorted Set                               | スコア=occurred_at.Unix(), メンバー=item_id |

### 5.4 外部サービスアダプタ

| アダプタ                      | 外部サービス       | 実装                               | エラーハンドリング               |
| ----------------------------- | ------------------ | ---------------------------------- | -------------------------------- |
| **PermissionServiceClient**   | Permission Service | gRPC                               | タイムアウト 2sec、default false |
| **SQSMessageConsumerAdapter** | SQS                | `github.com/aws/aws-sdk-go-v2/sqs` | リトライ 3回、DLQ へ送信         |

### 5.5 マッパー

```go
package adapter

// TimelineItemMapper DB ↔ ドメインエンティティ
type TimelineItemMapper struct{}

// ToEntity SQL 結果 → ドメイン TimelineItem
func (m *TimelineItemMapper) ToEntity(row *TimelineItemRow) (*domain.TimelineItem, error) {
    payload, err := domain.NewTimelinePayload(
        domain.TimelineItemType(row.ItemType),
        row.PayloadJSON,
    )
    if err != nil {
        return nil, err
    }
    
    return &domain.TimelineItem{
        ID:         row.ID,
        UserID:     row.UserID,
        OrgID:      row.OrgID,
        EventID:    row.EventID,
        ItemType:   domain.TimelineItemType(row.ItemType),
        Payload:    payload,
        OccurredAt: row.OccurredAt,
        Visibility: domain.Visibility(row.Visibility),
        Hidden:     row.Hidden,
        HiddenBy:   row.HiddenBy,
        HiddenAt:   row.HiddenAt,
        CreatedAt:  row.CreatedAt,
    }, nil
}

// ToPersistence ドメイン TimelineItem → DB 挿入用
func (m *TimelineItemMapper) ToPersistence(item *domain.TimelineItem) *TimelineItemRow {
    payloadJSON, _ := json.Marshal(item.Payload)
    return &TimelineItemRow{
        ID:          item.ID,
        UserID:      item.UserID,
        OrgID:       item.OrgID,
        EventID:     item.EventID,
        ItemType:    string(item.ItemType),
        PayloadJSON: payloadJSON,
        OccurredAt:  item.OccurredAt,
        Visibility:  string(item.Visibility),
        Hidden:      item.Hidden,
        HiddenBy:    item.HiddenBy,
        HiddenAt:    item.HiddenAt,
        CreatedAt:   item.CreatedAt,
    }
}

// SQSMessageMapper SQS JSON → CreateTimelineItemRequest
func SQSMessageToRequest(message []byte) (*CreateTimelineItemRequest, error) {
    var req CreateTimelineItemRequest
    err := json.Unmarshal(message, &req)
    return &req, err
}
```

---

## 6. フレームワーク＆ドライバ層（インフラストラクチャ）

### 6.1 Webフレームワーク
- **フレームワーク**: Gin v1.10
- **ポート**: 8002
- **ベースパス**: `/api`
- **ミドルウェア**: CORS, Auth Token 検証, Request ID, ロギング, Panic Recovery

### 6.2 データベース (MySQL 15 with monthly partitioning)

```sql
-- timeline_items テーブル（base）
CREATE TABLE IF NOT EXISTS timeline_items (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    org_id TEXT,
    event_id TEXT,
    item_type VARCHAR(50) NOT NULL CHECK (item_type IN (
        'EVENT_CREATED', 'ALBUM_CREATED', 'MEDIA_ADDED',
        'FRIEND_JOINED', 'EVENT_INVITATION_ACCEPTED',
        'HIGHLIGHT_VIDEO_READY', 'MEMORY_SHARED'
    )),
    payload JSONB NOT NULL,
    occurred_at TIMESTAMP WITH TIME ZONE NOT NULL,
    visibility VARCHAR(20) NOT NULL DEFAULT 'PUBLIC' CHECK (visibility IN ('PRIVATE', 'FRIENDS', 'PUBLIC')),
    hidden BOOLEAN NOT NULL DEFAULT FALSE,
    hidden_by TEXT,
    hidden_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT timeline_items_user_or_org CHECK (
        (user_id IS NOT NULL AND org_id IS NULL) OR
        (user_id IS NULL AND org_id IS NOT NULL)
    ),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE,
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE SET NULL,
    FOREIGN KEY (hidden_by) REFERENCES users(id) ON DELETE SET NULL
) PARTITION BY RANGE (YEAR(created_at), MONTH(created_at));

-- 月別パーティション（例：2026-04）
CREATE TABLE timeline_items_2026_04 PARTITION OF timeline_items
    FOR VALUES FROM (2026, 4) TO (2026, 5);

CREATE TABLE timeline_items_2026_05 PARTITION OF timeline_items
    FOR VALUES FROM (2026, 5) TO (2026, 6);

-- インデックス
CREATE INDEX idx_timeline_items_user_id ON timeline_items(user_id, hidden, occurred_at DESC);
CREATE INDEX idx_timeline_items_org_id ON timeline_items(org_id, hidden, occurred_at DESC);
CREATE INDEX idx_timeline_items_event_id ON timeline_items(event_id, occurred_at DESC);
CREATE INDEX idx_timeline_items_occurred_at ON timeline_items(occurred_at DESC);
CREATE INDEX idx_timeline_items_visibility ON timeline_items(visibility);

-- timeline_item_read_status テーブル（最後に見た位置）
CREATE TABLE IF NOT EXISTS timeline_item_read_status (
    id BIGSERIAL PRIMARY KEY,
    user_id TEXT NOT NULL,
    last_read_item_id TEXT,
    last_read_at TIMESTAMP WITH TIME ZONE,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT timeline_item_read_status_user_unique UNIQUE (user_id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (last_read_item_id) REFERENCES timeline_items(id) ON DELETE SET NULL
);

CREATE INDEX idx_timeline_item_read_status_user_id ON timeline_item_read_status(user_id);
```

### 6.3 メッセージブローカー
- **入力**: SQS キューから複数サービスのイベント受信
  - Events Service: `EventCreated`, `EventArchived`, `EventInvitationAccepted`
  - Album Service: `AlbumCreated`, `MediaAdded`
  - Auth Service: `UserCreated`, `UserJoinedOrg`
  - Messaging Service: `MemoryShared`
- **処理**: 非同期 Consumer (background worker)
- **エラー**: リトライ 3回 → DLQ

### 6.4 外部ライブラリ＆SDK

| ライブラリ                     | 用途               | バージョン |
| ------------------------------ | ------------------ | ---------- |
| `github.com/gin-gonic/gin`     | Web フレームワーク | v1.10      |
| `github.com/lib/pq`            | MySQL ドライバ     | v1.10      |
| `github.com/redis/go-redis/v9` | Redis ソートセット | v9.3       |
| `github.com/oklog/ulid/v2`     | ULID 生成          | v2.1       |
| `google.golang.org/grpc`       | Permission Service | v1.57      |
| `encoding/json`                | JSON パース        | stdlib     |

### 6.5 依存性注入 (uber-go/fx code example)

```go
package infra

import (
    "go.uber.org/fx"
    "github.com/gin-gonic/gin"
    "github.com/lib/pq"
    "database/sql"
)

// Module Timeline Service fx Module
func Module() fx.Option {
    return fx.Module("timeline-service",
        // インフラプロバイダ
        fx.Provide(
            provideMySQLDB,
            provideRedisClient,
            provideSQSClient,
            provideGinEngine,
        ),
        // リポジトリプロバイダ
        fx.Provide(
            func(db *sql.DB) adapter.TimelineItemRepository {
                return adapter.NewMySQLTimelineItemRepository(db)
            },
            func(redis *redis.Client) adapter.FeedCacheRepository {
                return adapter.NewRedisTimelineItemCache(redis)
            },
        ),
        // 外部サービスアダプタ
        fx.Provide(
            func(grpcConn *grpc.ClientConn) application.PermissionService {
                return adapter.NewPermissionServiceClient(grpcConn)
            },
            func(sqsClient *sqs.Client) application.SQSMessageConsumer {
                return adapter.NewSQSMessageConsumerAdapter(sqsClient)
            },
        ),
        // ユースケース
        fx.Provide(
            func(
                itemRepo adapter.TimelineItemRepository,
                feedCache adapter.FeedCacheRepository,
                permSvc application.PermissionService,
            ) application.CreateTimelineItemUseCase {
                return application.NewCreateTimelineItemUseCase(itemRepo, feedCache, permSvc)
            },
            func(
                itemRepo adapter.TimelineItemRepository,
                feedCache adapter.FeedCacheRepository,
                permSvc application.PermissionService,
            ) application.GetUserTimelineUseCase {
                return application.NewGetUserTimelineUseCase(itemRepo, feedCache, permSvc)
            },
            // その他...
        ),
        // ハンドラ登録
        fx.Invoke(registerHandlers),
    )
}

func provideMySQLDB(cfg *config.DatabaseConfig) (*sql.DB, error) {
    connStr := fmt.Sprintf(
        "MySQL://%s:%s@%s:%d/%s?sslmode=require",
        cfg.User, cfg.Password, cfg.Host, cfg.Port, cfg.Database,
    )
    return sql.Open("MySQL", connStr)
}

func provideRedisClient(cfg *config.RedisConfig) *redis.Client {
    return redis.NewClient(&redis.Options{
        Addr: cfg.Address,
    })
}

func registerHandlers(
    engine *gin.Engine,
    createItemUC application.CreateTimelineItemUseCase,
    getUserTimelineUC application.GetUserTimelineUseCase,
    hideItemUC application.HideTimelineItemUseCase,
) {
    api := engine.Group("/api")
    {
        timelines := api.Group("/timelines")
        {
            timelines.GET("/users/:id", func(c *gin.Context) {
                handler := adapter.NewGetUserTimelineHandler(getUserTimelineUC)
                handler.Handle(c)
            })
        }
        items := api.Group("/timeline-items")
        {
            items.DELETE("/:id", func(c *gin.Context) {
                handler := adapter.NewHideTimelineItemHandler(hideItemUC)
                handler.Handle(c)
            })
        }
    }
}
```

---

## 7. ディレクトリ構成

```
recuerdo-timeline-svc/
├── cmd/
│   ├── main.go                 # アプリケーション起動
│   └── consumer/
│       └── main.go             # SQS Consumer ワーカー
├── internal/
│   ├── domain/
│   │   ├── timeline_item.go    # TimelineItem エンティティ
│   │   ├── value_objects.go    # TimelineItemType, Visibility, FeedCursor
│   │   ├── feed_cursor.go      # ページネーション
│   │   └── events.go           # ドメインイベント
│   ├── application/
│   │   ├── dto.go              # DTO 定義
│   │   ├── ports.go            # インターフェース
│   │   ├── create_timeline_item.go
│   │   ├── get_user_timeline.go
│   │   ├── get_org_timeline.go
│   │   ├── hide_timeline_item.go
│   │   └── get_user_feed.go
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── get_user_timeline_handler.go
│   │   │   ├── get_org_timeline_handler.go
│   │   │   ├── hide_timeline_item_handler.go
│   │   │   └── get_user_feed_handler.go
│   │   ├── persistence/
│   │   │   ├── MySQL_timeline_item_repo.go
│   │   │   └── redis_timeline_item_cache.go
│   │   ├── external/
│   │   │   ├── sqs_message_consumer.go
│   │   │   └── permission_service_client.go
│   │   ├── consumer/
│   │   │   └── sqs_message_handler.go   # SQS Consumer logic
│   │   ├── presenter.go
│   │   └── mapper.go
│   └── infra/
│       ├── config.go
│       ├── database.go
│       ├── redis.go
│       ├── sqs.go
│       ├── fx_module.go
│       └── migrations/
│           └── 001_create_timeline_items.sql
├── test/
│   ├── integration/
│   │   ├── create_timeline_item_test.go
│   │   └── get_user_timeline_test.go
│   └── unit/
│       ├── domain/
│       │   └── timeline_item_test.go
│       └── application/
│           └── create_timeline_item_usecase_test.go
├── go.mod
├── go.sum
├── Dockerfile
└── README.md
```

---

## 8. 依存性ルールと境界

### 8.1 許可される依存関係

| レイヤー                       | 依存可能な対象   | 例                                    |
| ------------------------------ | ---------------- | ------------------------------------- |
| **フレームワーク＆ドライバ層** | すべて下位       | SQS Consumer → UseCase → Domain       |
| **インターフェースアダプタ層** | ユースケース以下 | Handler → UseCase → Domain            |
| **ユースケース層**             | ドメイン層のみ   | GetUserTimeline → domain.TimelineItem |
| **ドメイン層**                 | なし             | 自己完結                              |

### 8.2 境界の横断
- **ポート経由**：ユースケース → リポジトリポート
- **DTO 経由**：SQS メッセージ → DTO → ユースケース → ドメイン
- **イベント駆動**：ドメインイベント → 他サービス（疎結合）

### 8.3 ルールの強制
- **コンパイル時**：Go 型チェック
- **実行時**：linter (golangci-lint depguard)
- **レビュー時**：コードレビュー

---

## 9. テスト戦略

### 9.1 テストピラミッド

| テストタイプ         | 割合 | 対象                           | ツール                     |
| -------------------- | ---- | ------------------------------ | -------------------------- |
| **ユニットテスト**   | 70%  | ドメイン、ユースケース（Mock） | `testing` + `testify`      |
| **統合テスト**       | 20%  | Handler + UseCase + Repo       | `testcontainers-go`        |
| **エンドツーエンド** | 10%  | 全フロー（SQS 含む）           | docker-compose, API テスト |

### 9.2 テスト例 (Go test code)

```go
package domain_test

import (
    "testing"
    "time"
    "github.com/stretchr/testify/assert"
    "timeline-svc/internal/domain"
)

func TestNewTimelineItem_Success(t *testing.T) {
    // Arrange
    userID := "user-123"
    itemType := domain.TimelineItemTypeEventCreated
    payload, _ := domain.NewTimelinePayload(
        itemType,
        map[string]interface{}{"event_id": "evt-456", "title": "Party"},
    )
    
    // Act
    item, err := domain.NewTimelineItem(
        &userID,
        nil, // no org
        nil, // no event
        itemType,
        payload,
        time.Now(),
        domain.VisibilityPublic,
    )
    
    // Assert
    assert.NoError(t, err)
    assert.Equal(t, &userID, item.UserID)
    assert.False(t, item.Hidden)
    assert.Len(t, item.DomainEvents(), 1)
}

func TestTimelineItem_IsVisibleTo(t *testing.T) {
    userID := "user-123"
    otherUserID := "user-999"
    payload, _ := domain.NewTimelinePayload(
        domain.TimelineItemTypeEventCreated,
        map[string]interface{}{},
    )
    
    tests := []struct {
        name        string
        visibility  domain.Visibility
        viewerID    string
        isConnected bool
        expected    bool
    }{
        {
            name:        "Private visible to owner",
            visibility:  domain.VisibilityPrivate,
            viewerID:    userID,
            isConnected: false,
            expected:    true,
        },
        {
            name:        "Private not visible to others",
            visibility:  domain.VisibilityPrivate,
            viewerID:    otherUserID,
            isConnected: false,
            expected:    false,
        },
        {
            name:        "Friends visible to connected",
            visibility:  domain.VisibilityFriends,
            viewerID:    otherUserID,
            isConnected: true,
            expected:    true,
        },
        {
            name:        "Public visible to all",
            visibility:  domain.VisibilityPublic,
            viewerID:    "anyone",
            isConnected: false,
            expected:    true,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            item, _ := domain.NewTimelineItem(
                &userID, nil, nil,
                domain.TimelineItemTypeEventCreated,
                payload,
                time.Now(),
                tt.visibility,
            )
            
            result := item.IsVisibleTo(tt.viewerID, tt.isConnected)
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
    "timeline-svc/internal/application"
)

func TestCreateTimelineItemUseCase_Integration(t *testing.T) {
    ctx := context.Background()
    
    // testcontainers で MySQL セットアップ
    db, cleanup := setupTestDB(t)
    defer cleanup()
    
    itemRepo := adapter.NewMySQLTimelineItemRepository(db)
    cacheRepo := &mockFeedCacheRepository{}
    permSvc := &mockPermissionService{connected: true}
    
    uc := application.NewCreateTimelineItemUseCase(itemRepo, cacheRepo, permSvc)
    
    // Act
    resp, err := uc.Execute(ctx, &application.CreateTimelineItemRequest{
        EventType:  "EVENT_CREATED",
        UserID:     strPtr("user-123"),
        Payload:    map[string]interface{}{"event_id": "evt-456"},
        OccurredAt: time.Now(),
        Visibility: "PUBLIC",
    })
    
    // Assert
    assert.NoError(t, err)
    assert.NotEmpty(t, resp.ItemID)
    assert.Equal(t, 1, cacheRepo.invalidateCount)
}

// Mock 実装
type mockFeedCacheRepository struct {
    invalidateCount int
}

func (m *mockFeedCacheRepository) GetUserFeed(ctx context.Context, userID string, start, stop int) ([]string, error) {
    return []string{}, nil
}

func (m *mockFeedCacheRepository) InvalidateUserFeed(ctx context.Context, userID string) error {
    m.invalidateCount++
    return nil
}

func (m *mockFeedCacheRepository) InvalidateOrgFeed(ctx context.Context, orgID string) error {
    return nil
}
```

---

## 10. エラーハンドリング

### 10.1 ドメインエラー

```go
package domain

var (
    ErrInvalidVisibility     = errors.New("invalid visibility")
    ErrInvalidItemType       = errors.New("invalid item type")
    ErrInvalidPayload        = errors.New("payload invalid for item type")
    ErrUserAndOrgBothSet     = errors.New("either user or org required, not both")
    ErrAlreadyHidden         = errors.New("item already hidden")
)
```

### 10.2 アプリケーションエラー

```go
package application

var (
    ErrTimelineItemNotFound      = errors.New("timeline item not found")
    ErrUnauthorizedToHide        = errors.New("not authorized to hide item")
    ErrPersistenceFailed         = errors.New("failed to persist item")
    ErrInvalidMessage            = errors.New("invalid SQS message")
    ErrCursorInvalid             = errors.New("invalid cursor")
)
```

### 10.3 エラー変換 (HTTP mapping table)

| エラー                    | HTTP ステータス           | レスポンス                    |
| ------------------------- | ------------------------- | ----------------------------- |
| `ErrTimelineItemNotFound` | 404 Not Found             | `{"error": "not_found"}`      |
| `ErrUnauthorizedToHide`   | 403 Forbidden             | `{"error": "unauthorized"}`   |
| `ErrCursorInvalid`        | 400 Bad Request           | `{"error": "invalid_cursor"}` |
| `ErrPersistenceFailed`    | 500 Internal Server Error | `{"error": "internal_error"}` |

---

## 11. 横断的関心事

### 11.1 ロギング
- **ライブラリ**: `go.uber.org/zap`
- **レベル**: DEBUG, INFO, WARN, ERROR
- **ログポイント**: SQS メッセージ受信、ドメイン操作、DB アクセス、可視性チェック結果
- **フォーマット**: JSON

### 11.2 認証・認可
- **認証**: JWT トークン
- **認可**: Permission Service 経由で接続状態・権限チェック
- **ポリシー**: ユーザーは自身のアイテムのみ非表示化可能、Org Admin は任意アイテム非表示化可

### 11.3 バリデーション
- **入力**: HTTP request JSON スキーマバリデーション
- **ドメイン**: TimelineItemType、Visibility、Payload 構造検証
- **SQS**: メッセージスキーマバリデーション

### 11.4 キャッシング
- **層**: Redis Sorted Set（スコア=occurred_at.Unix()）
- **キー**: `timeline:user:{userID}`, `timeline:org:{orgID}`
- **TTL**: 10分
- **無効化**: 新規アイテム作成時、アイテム非表示化時に明示削除

---

## 12. マイグレーション計画

### 12.1 現状
- モノリシック内の activity log（単純なテーブル）
- 時系列ソート・ページング未実装
- キャッシング戦略なし

### 12.2 目標状態
- 独立した Timeline Service
- カーソルベースページング、月次パーティショニング
- Redis Sorted Set キャッシュ
- 複数サービスからのイベント統合

### 12.3 マイグレーション手順

| フェーズ                                | 実施内容                              | 期間  | 依存関係  |
| --------------------------------------- | ------------------------------------- | ----- | --------- |
| **1. インフラ準備**                     | MySQL パーティション作成、Redis setup | 1週間 | なし      |
| **2. コア実装**                         | ドメイン層、ユースケース、リポジトリ  | 2週間 | フェーズ1 |
| **3. HTTP + キャッシュ**                | Handler、Presenter、Redis キャッシュ  | 1週間 | フェーズ2 |
| **4. SQS Consumer**                     | SQS メッセージハンドラ、ワーカー実装  | 1週間 | フェーズ3 |
| **5. テスト**                           | 統合・E2E テスト                      | 1週間 | フェーズ4 |
| **6. デプロイ・データマイグレーション** | 本番へのロールアウト、既存データ移行  | 1週間 | フェーズ5 |

---

## 13. 未決事項と決定事項

| 項目                           | 現在の決定                      | 状態     | 備考                           |
| ------------------------------ | ------------------------------- | -------- | ------------------------------ |
| **パーティショニング戦略**     | 月次（RANGE by year, month）    | 決定済み | 年4回の archive + テーブル削除 |
| **Soft Delete vs Hard Delete** | Soft Delete（hidden フラグ）    | 決定済み | 監査証跡保持                   |
| **カーソルエンコーディング**   | Base64（lastSeenID:occurredAt） | 決定済み | API 外部公開用                 |
| **友人フィード更新頻度**       | リアルタイム（SQS 駆動）        | 決定済み | eventual consistency 許容      |
| **キャッシュの一貫性**         | Eventually Consistent           | 決定済み | 10分 TTL で十分                |
| **グラフDB 導入**              | 未検討                          | 保留中   | 友人グラフが複雑化したら検討   |

---

## 14. 参考資料

- **Clean Architecture**: Robert C. Martin, "Clean Architecture"
- **Event-Driven Architecture**: Sam Newman, "Building Event-Driven Microservices"
- **MySQL Partitioning**: `https://www.MySQL.org/docs/15/ddl-partitioning.html`
- **Redis Sorted Set**: `https://redis.io/docs/data-types/sorted-sets/`
- **Cursor-Based Pagination**: `https://medium.com/swlh/pagination-in-graphql`
- **Gin Framework**: `https://github.com/gin-gonic/gin`
