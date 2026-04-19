# Timeline Module (recerdo-timeline)

**作成者**: Akira · **作成日**: 2026-04-14 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoの全ユーザー・組織に対して、時系列で整理された活動フィードとメモリタイムラインを提供するドメイン層設計書。Timeline Serviceは「記憶層」として機能し、イベント・アルバム・メディア・友人接続・グループ参加といった重要な出来事をいつ・どのように起きたのかをユーザーに見える化する。過去のメモリを辿りながら友人との再会・関係の深化を支援するコア機能。

Timeline Serviceの本質:
- **イベント駆動アーキテクチャ**: Events Service・Album Service・Auth Service・Messaging Service から **QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）** 経由で非同期イベントを受信し、TimelineItemレコードを生成（AWS SQS は不使用、[基本的方針](../core/policy.md) 参照）
  - **冪等性とトランザクショナルアウトボックス**: すべてのイベントリスニングおよび書き込み処理に対して、`Idempotency-Key` と対象アイテムのIDを用いた冪等性（Idempotency）を保証（Redisにて24時間保持）。自サービスからのイベント発行時は確実に Transactional Outbox パターンを用いて送信する。
- **読み取り最適化設計**: 大規模な読み取り負荷に対応するため、Redis cache + MySQL 8.0 / MariaDB 10.11 パーティション + cursor-based pagination
  - **スケーラビリティ (ハイブリッド Fan-out)**: Fan-out on Write を既定の同期戦略とするが、フォロワー数が500を超える場合はスパイクを防ぐため Fan-out on Read に動的に切り替える。
  - **縮退運転 (Graceful Degradation)**: 負荷上昇時やSLOエラーバジェット枯渇時は、タイムライン取得をキャッシュフォールバックへ縮退し、重い書き込み操作は Flipt 機能フラグ（Feature Flags）によって Fan-out on Read へ切り替えるか一時無効化してシステムを保護する。
- **イミュータブル・アペンドオンリー**: Timeline items は削除されず、visibility フラグで「表示/非表示」を制御
- **権限・可視性管理**: PRIVATE（所有者のみ） / FRIENDS（友人グループのみ） / PUBLIC（全員表示）の3段階可視性

### ビジネスコンテキスト

解決する問題:
- ユーザーが個人の活動履歴を時系列で見返す方法がない。アルバムやイベントはバラバラで、一貫した「時間軸」がない
- 組織（旧友グループ）に何が起こったのかが不透明。誰がいつ参加したのか、どんなメモリが共有されたのかを可視化できない
- モバイルアプリ（iOS）で無限スクロール式フィード表示をしたい。大量のhistoryを効率よく取得する方法が必要

Key User Stories:
- iOS ユーザーとして、自分の Timeline を開くと、最新のメモリから順に見え、スクロールで古いメモリを遡りたい
- グループマネージャーとして、組織 Timeline を見ると、メンバーが参加した日、アルバムが作成された日、ハイライト動画がアップロードされた日が時系列に並んでほしい
- プライバシー担当者として、PRIVATE な memory は所有者以外に見えない、FRIENDS items は friendship relation 確認後のみ表示される、と確信したい
- バックエンド開発者として、Events Service・Album Service から新しい event type が増えても、Timeline Service で「新しい item_type を add する → view に反映」と simple に extend したい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ    | 説明                                                                                                               | 主要属性                                                                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TimelineItem    | 時系列上の個別イベント。イミュータブル・append-only。削除されず visibility で非表示化。                            | id (ULID), user_id?, org_id?, event_id?, media_id?, item_type, payload (JSON), occurred_at, created_at, visibility (PUBLIC/FRIENDS/PRIVATE), hidden_at? |
| UserFeed        | ユーザーの personalized timeline。ユーザーが作成したもの + フレンドが共有したもの + 所属org item。キャッシュ対象。 | user_id, last_fetched_at, cursor (ULID+timestamp), item_count                                                                                            |
| OrgTimeline     | 組織レベルのタイムライン。Public/Friends items のみ。アグリゲート用。                                              | org_id, visibility (PUBLIC/FRIENDS), item_count, last_updated_at                                                                                         |
| TimelinePayload | item_type 毎にスキーマが異なる JSON。型チェック・バリデーション済み。                                             | event_id?, event_name?, album_name?, media_url?, thumbnail_url?, invited_by_user_id?, shared_by_user_id?, highlight_video_url?, memory_title?            |

### 値オブジェクト

| 値オブジェクト   | 説明                                                                                                                                            | バリデーションルール                                                                        |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| TimelineItemType | enum. EVENT_CREATED, ALBUM_CREATED, MEDIA_ADDED, FRIEND_JOINED, EVENT_INVITATION_ACCEPTED, HIGHLIGHT_VIDEO_READY, MEMORY_SHARED                 | enum に含まれる値のみ。新タイプ追加時は EventService・Timeline Service で同期               |
| Visibility       | PUBLIC / FRIENDS / PRIVATE                                                                                                                      | デフォルト FRIENDS。PRIVATE items は owner_id == user_id のときのみ表示                     |
| FeedCursor       | cursor-based pagination 用 value object。last_seen_id (ULID) + last_seen_timestamp (occurred_at)。レスポンスに含める次ページ cursor を encode。 | occurred_at は unix timestamp。id は valid ULID。encode 時に "id:timestamp" 形式で base64。 |
| TimelinePayload  | JSON Schema per item_type。バリデーション済み JSON。media_url は Storage Service cdn proxy URL。                                               | schema 定義を enum/const で管理。未知の field は無視。                                      |
| ULID             | Universally Unique Lexicographically Sortable Identifier。sortable by time。                                                                    | sortableで time-ordered。id generation は timestamp+randomness。                            |

### ドメインルール / 不変条件

- **Visibility PRIVATE**: TimelineItem の visibility=PRIVATE の場合、owner_id == requesting_user_id の場合のみ表示。権限なしは 403。
- **Visibility FRIENDS**: visibility=FRIENDS の場合、requesting_user と item owner が friendship relation を持つ場合のみ表示。Permission Service に friendship check を委譲。
- **削除禁止・アペンドオンリー**: Timeline items は DELETE されない。削除したい場合は visibility フラグを HIDDEN に set。delete cascade は「関連 item を hidden にする」ことで実装。
- **OrgTimeline 権限**: 組織 timeline は PUBLIC / FRIENDS items のみ表示。PRIVATE items は org member であっても非表示。owner privacy を尊重。
- **Event Cascade Deletion**: イベントが削除された場合、そのイベント由来の timeline items はすべて「hidden=true」として mark。
- **item_type + payload スキーマ**: item_type == "EVENT_CREATED" の場合、payload に必ず {event_id, event_name, description} を含む。スキーマ mismatch は domain error。
- **occurred_at immutable**: timeline item 作成後、occurred_at を変更してはならない。occurred_at は「いつ実際に起きたのか」の客観的事実。
- **Cursor validation**: FeedCursor の id は valid ULID・timestamp は valid unix。malformed cursor は InvalidCursorError。
- **キャッシュ一貫性**: Redis cache に「ユーザーの最新100 items」を保持。items insert → cache invalidate 必須。

### ドメインイベント

| イベント            | トリガー                                                                             | 主要ペイロード                                                                     |
| ------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| TimelineItemCreated | 新規 item insert 後                                                                  | timeline_item_id, user_id?, org_id?, item_type, occurred_at, visibility, timestamp |
| TimelineItemHidden  | visibility を HIDDEN に set 時                                                       | timeline_item_id, reason (delete_event/user_request/privacy_change), timestamp     |
| UserTimelineUpdated | user feed に新規 item add 時                                                         | user_id, item_count, updated_at                                                    |
| OrgTimelineUpdated  | org timeline に新規 public/friends item add 時                                       | org_id, item_count, updated_at                                                     |
| FriendshipCreated   | (Events Service から QueuePort) 新規友人接続 → 相手 PRIVATE items を visibility 確認後表示 | user_id_1, user_id_2, created_at                                              |
| EventDeleted        | (Events Service から QueuePort) イベント削除 → 関連 timeline items を hidden にする        | event_id, deleted_at                                                          |

### エンティティ定義（コードスケッチ）

```go
// Timeline Item - コア entity
type TimelineItem struct {
    ID         ULID
    UserID     *string           // item owner (可能性あり)
    OrgID      *string           // item 対象 org (可能性あり)
    EventID    *string           // 参照先 event (可能性あり)
    MediaID    *string           // 参照先 media (可能性あり)
    ItemType   TimelineItemType  // enum: EVENT_CREATED, ALBUM_CREATED, ...
    Payload    TimelinePayload   // JSON、item_type に応じた schema
    OccurredAt time.Time         // 実際に起きた時刻（immutable）
    CreatedAt  time.Time         // DB insert 時刻
    Visibility Visibility        // PUBLIC / FRIENDS / PRIVATE
    HiddenAt   *time.Time        // NULL = visible, non-NULL = hidden (soft delete)
}

func (t *TimelineItem) IsVisible(requestingUserID *string, permissionPort PermissionPort) (bool, error) {
    // PRIVATE: owner_id == requesting_user_id のみ
    if t.Visibility == VisibilityPRIVATE {
        if requestingUserID == nil || *requestingUserID != *t.UserID {
            return false, nil
        }
        return true, nil
    }
    // FRIENDS: friendship check via PermissionPort
    if t.Visibility == VisibilityFRIENDS {
        if requestingUserID == nil {
            return false, nil
        }
        ok, err := permissionPort.CheckFriendship(context.Background(), *requestingUserID, *t.UserID)
        if err != nil {
            return false, err
        }
        return ok, nil
    }
    // PUBLIC: 全員表示
    return true, nil
}

func (t *TimelineItem) Validate() error {
    if !t.ID.IsValid() {
        return ErrInvalidTimelineItemID
    }
    if t.ItemType == "" {
        return ErrInvalidItemType
    }
    if err := t.validatePayloadSchema(); err != nil {
        return err
    }
    if t.Visibility == "" {
        return ErrInvalidVisibility
    }
    if t.OccurredAt.After(time.Now()) {
        return ErrFutureOccurredAt
    }
    return nil
}

func (t *TimelineItem) validatePayloadSchema() error {
    switch t.ItemType {
    case ItemTypeEventCreated:
        required := []string{"event_id", "event_name", "description"}
        for _, field := range required {
            if !t.Payload.Has(field) {
                return ErrMissingPayloadField
            }
        }
    case ItemTypeAlbumCreated:
        required := []string{"album_id", "album_name", "album_thumbnail_url"}
        for _, field := range required {
            if !t.Payload.Has(field) {
                return ErrMissingPayloadField
            }
        }
    case ItemTypeMediaAdded:
        required := []string{"media_id", "media_url", "media_type"}
        for _, field := range required {
            if !t.Payload.Has(field) {
                return ErrMissingPayloadField
            }
    }
    // ... other item types
    return nil
}

// Visibility - Value Object
type Visibility string

const (
    VisibilityPUBLIC   Visibility = "PUBLIC"
    VisibilityFRIENDS  Visibility = "FRIENDS"
    VisibilityPRIVATE  Visibility = "PRIVATE"
)

func (v Visibility) IsValid() bool {
    return v == VisibilityPUBLIC || v == VisibilityFRIENDS || v == VisibilityPRIVATE
}

// FeedCursor - Value Object for pagination
type FeedCursor struct {
    LastSeenID       ULID
    LastSeenTimestamp int64 // unix seconds
}

func (c *FeedCursor) Encode() string {
    data := fmt.Sprintf("%s:%d", c.LastSeenID.String(), c.LastSeenTimestamp)
    return base64.StdEncoding.EncodeToString([]byte(data))
}

func DecodeFeedCursor(encoded string) (*FeedCursor, error) {
    data, err := base64.StdEncoding.DecodeString(encoded)
    if err != nil {
        return nil, ErrInvalidCursorFormat
    }
    parts := strings.Split(string(data), ":")
    if len(parts) != 2 {
        return nil, ErrInvalidCursorFormat
    }
    id, err := ParseULID(parts[0])
    if err != nil {
        return nil, ErrInvalidCursorID
    }
    ts, err := strconv.ParseInt(parts[1], 10, 64)
    if err != nil {
        return nil, ErrInvalidCursorTimestamp
    }
    return &FeedCursor{LastSeenID: id, LastSeenTimestamp: ts}, nil
}

// TimelinePayload - Value Object (JSON wrapper)
type TimelinePayload struct {
    data map[string]interface{}
}

func (p *TimelinePayload) Has(field string) bool {
    _, ok := p.data[field]
    return ok
}

func (p *TimelinePayload) Get(field string) (interface{}, error) {
    val, ok := p.data[field]
    if !ok {
        return nil, ErrPayloadFieldNotFound
    }
    return val, nil
}

func (p *TimelinePayload) Marshal() ([]byte, error) {
    return json.Marshal(p.data)
}

// TimelineItemType - enum
type TimelineItemType string

const (
    ItemTypeEventCreated               TimelineItemType = "EVENT_CREATED"
    ItemTypeAlbumCreated               TimelineItemType = "ALBUM_CREATED"
    ItemTypeMediaAdded                 TimelineItemType = "MEDIA_ADDED"
    ItemTypeFriendJoined               TimelineItemType = "FRIEND_JOINED"
    ItemTypeEventInvitationAccepted    TimelineItemType = "EVENT_INVITATION_ACCEPTED"
    ItemTypeHighlightVideoReady        TimelineItemType = "HIGHLIGHT_VIDEO_READY"
    ItemTypeMemoryShared               TimelineItemType = "MEMORY_SHARED"
)

func (t TimelineItemType) IsValid() bool {
    validTypes := map[TimelineItemType]bool{
        ItemTypeEventCreated:            true,
        ItemTypeAlbumCreated:            true,
        ItemTypeMediaAdded:              true,
        ItemTypeFriendJoined:            true,
        ItemTypeEventInvitationAccepted: true,
        ItemTypeHighlightVideoReady:     true,
        ItemTypeMemoryShared:            true,
    }
    return validTypes[t]
}

// UserFeed - aggregate root
type UserFeed struct {
    UserID    string
    Items     []TimelineItem
    Cursor    *FeedCursor
    HasMore   bool
}

func (f *UserFeed) AddItem(item TimelineItem) error {
    if !item.IsValid() {
        return ErrInvalidTimelineItem
    }
    f.Items = append(f.Items, item)
    return nil
}

// OrgTimeline - aggregate root
type OrgTimeline struct {
    OrgID      string
    Items      []TimelineItem
    ItemCount  int
    UpdatedAt  time.Time
}

func (o *OrgTimeline) AddItem(item TimelineItem) error {
    // org timeline には PUBLIC / FRIENDS items のみ許可
    if item.Visibility == VisibilityPRIVATE {
        return ErrPrivateItemsNotAllowedInOrgTimeline
    }
    o.Items = append(o.Items, item)
    o.ItemCount++
    o.UpdatedAt = time.Now()
    return nil
}
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース             | 入力DTO                                                                                 | 出力DTO                                                | 説明                                                                                       |
| ------------------------ | --------------------------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| GetUserTimeline          | GetUserTimelineInput{user_id, requesting_user_id?, cursor?, limit?}                     | GetUserTimelineOutput{items, next_cursor, has_more}    | ユーザーの personal timeline を時系列で取得。cursor-based pagination。権限チェック含む     |
| GetOrgTimeline           | GetOrgTimelineInput{org_id, requesting_user_id?, cursor?, limit?}                       | GetOrgTimelineOutput{items, next_cursor, has_more}     | 組織のタイムラインを取得。PUBLIC/FRIENDS items のみ                                        |
| GetUserFeed              | GetUserFeedInput{requesting_user_id, cursor?, limit?}                                   | GetUserFeedOutput{items, next_cursor, has_more}        | 現在ユーザーの personalized feed。自分の items + フレンドの shared items。キャッシュ最適化 |
| CreateTimelineItem       | CreateTimelineItemInput{user_id?, org_id?, item_type, payload, occurred_at, visibility} | CreateTimelineItemOutput{timeline_item_id, created_at} | 新規 timeline item 作成（内部API。Events Service・Album Service から呼び出し）             |
| HideTimelineItem         | HideTimelineItemInput{timeline_item_id, reason}                                         | HideTimelineItemOutput{success}                        | item を非表示（soft delete）。cascade: 関連 items も hidden                                |
| ConsumeEventServiceEvent | ConsumeEventServiceEventInput{queue_msg}                                                | ConsumeEventServiceEventOutput{timeline_items_created} | QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue）から Event Service event を受信。ULID 生成・item 作成 |
| ConsumeFriendshipEvent   | ConsumeFriendshipEventInput{queue_msg, user_id_1, user_id_2}                            | ConsumeFriendshipEventOutput{success}                  | QueuePort から friendship event を受信。user_id_1 と user_id_2 の mutual access enable     |
| CacheInvalidateUserFeed  | CacheInvalidateUserFeedInput{user_id}                                                   | CacheInvalidateUserFeedOutput{success}                 | Redis cache 無効化（item add 時に自動呼び出し）                                            |
| PreloadFeedCache         | PreloadFeedCacheInput{user_id, limit?}                                                  | PreloadFeedCacheOutput{item_count, cache_key}          | User feed を Redis に preload。cold start 対策                                             |

### ユースケース詳細（主要ユースケース）

## GetUserTimeline — 主要ユースケース詳細

### トリガー
iOS app / Web app から GET /api/users/{user_id}/timeline?cursor={cursor}&limit={limit}

### フロー
1. PathParameterPort.ParseUserID(user_id) → validate ULID
   - 不正 → 400
2. QueryParameterPort.ParseCursor(cursor query param)
   - cursor 指定時: DecodeFeedCursor() → if error, InvalidCursorError
   - cursor 未指定: cursor = nil（最新から開始）
3. QueryParameterPort.ParseLimit(limit query param)
   - デフォルト 20。最大 100。超過は 400
4. PermissionPort.GetUser(user_id) → user exists check
   - not found → 404
5. キャッシュ確認（Redis user:{user_id}:timeline）
   - cache hit かつ requesting_user_id が owner → cache から取得
   - cache miss → step 6
6. TimelineItemRepository.QueryUserTimeline(user_id, cursor, limit+1)
   - SQL: SELECT * FROM timeline_items WHERE user_id = ? AND hidden_at IS NULL ORDER BY occurred_at DESC LIMIT (limit+1)
   - partition key: month(occurred_at) で range partition
7. 取得 items に対して visibility check（requesting_user_id と friendship）
   - item.IsVisible(requesting_user_id, permissionPort)
   - hidden items は除外
8. limit 個を next_cursor 候補として確保。limit+1 取得できた = has_more=true
9. has_more=true の場合、最後の item から FeedCursor.Encode() して next_cursor 生成
10. リスポンス: {items (limit 個), next_cursor?, has_more}
11. キャッシュに書き込み（TTL 5分）: Redis SET user:{user_id}:timeline [items JSON] EX 300

### 注意事項
- requesting_user_id == user_id の場合、visibility check をスキップして全 items 返す
- requesting_user_id が nil（未認証）の場合、PUBLIC items のみ返す
- cursor pagination の load target: 大規模ユーザーで月単位 partition により最大 ~1秒以内

### リポジトリ・サービスポート（インターフェース）

```go
// Repository Ports
type TimelineItemRepository interface {
    // Create
    Create(ctx context.Context, item *TimelineItem) (ULID, error)
    
    // Query
    QueryUserTimeline(ctx context.Context, userID string, cursor *FeedCursor, limit int) ([]TimelineItem, error)
    QueryOrgTimeline(ctx context.Context, orgID string, cursor *FeedCursor, limit int) ([]TimelineItem, error)
    QueryUserFeed(ctx context.Context, userID string, friendIDs []string, cursor *FeedCursor, limit int) ([]TimelineItem, error)
    QueryByEventID(ctx context.Context, eventID string) ([]TimelineItem, error)
    QueryByItemType(ctx context.Context, itemType TimelineItemType) ([]TimelineItem, error)
    
    // Update
    Hide(ctx context.Context, timelineItemID ULID, reason string) error
    
    // Batch
    HideBatch(ctx context.Context, itemIDs []ULID, reason string) error
}

type FeedCacheRepository interface {
    // Redis cache for user feed (last 100 items)
    GetFeed(ctx context.Context, userID string) ([]TimelineItem, error)
    SetFeed(ctx context.Context, userID string, items []TimelineItem, ttl time.Duration) error
    InvalidateFeed(ctx context.Context, userID string) error
}

type OrgTimelineRepository interface {
    GetTimeline(ctx context.Context, orgID string, cursor *FeedCursor, limit int) (*OrgTimeline, error)
    UpdateTimeline(ctx context.Context, orgTimeline *OrgTimeline) error
}

// Service Ports
type PermissionPort interface {
    CheckFriendship(ctx context.Context, userID1, userID2 string) (bool, error)
    GetUser(ctx context.Context, userID string) (*User, error)
    GetFriendsOfUser(ctx context.Context, userID string) ([]string, error)
}

type EventServicePort interface {
    // QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）consumer 経由で EventDeleted event 受け取り
    // → HideTimelineItem cascade
}

type ULIDGeneratorPort interface {
    Generate() ULID
}

type EventPublisherPort interface {
    PublishTimelineItemCreated(ctx context.Context, event TimelineItemCreated) error
    PublishTimelineItemHidden(ctx context.Context, event TimelineItemHidden) error
    PublishUserTimelineUpdated(ctx context.Context, event UserTimelineUpdated) error
}

// Controller / Handler Ports
type HTTPTimelineHandler interface {
    GetUserTimeline(w http.ResponseWriter, r *http.Request)
    GetOrgTimeline(w http.ResponseWriter, r *http.Request)
    GetUserFeed(w http.ResponseWriter, r *http.Request)
}

// QueueEventConsumerPort は QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）から
// メッセージを取得して各 Consume ユースケースにディスパッチする。
type QueueEventConsumerPort interface {
    ConsumeEventServiceEvent(ctx context.Context, msg port.Job) error
    ConsumeFriendshipEvent(ctx context.Context, msg port.Job) error
    ConsumeEventDeletedEvent(ctx context.Context, msg port.Job) error
}
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ                   | ルート/トリガー                         | ユースケース                    |
| ------------------------------ | --------------------------------------- | ------------------------------- |
| HTTPTimelineHandler            | GET /api/users/{user_id}/timeline       | GetUserTimelineUseCase          |
| HTTPTimelineHandler            | GET /api/orgs/{org_id}/timeline         | GetOrgTimelineUseCase           |
| HTTPTimelineHandler            | GET /api/users/me/feed                  | GetUserFeedUseCase              |
| HTTPTimelineHandler (Internal) | POST /api/timeline                      | CreateTimelineItemUseCase       |
| HTTPTimelineHandler (Internal) | DELETE /api/timeline/{timeline_item_id} | HideTimelineItemUseCase         |
| QueueConsumer (BullMQ/asynq/OCI Queue) | Queue: recuerdo.events.service.published | ConsumeEventServiceEventUseCase |
| QueueConsumer (BullMQ/asynq/OCI Queue) | Queue: recuerdo.auth.friendship_created  | ConsumeFriendshipEventUseCase   |
| QueueConsumer (BullMQ/asynq/OCI Queue) | Queue: recuerdo.events.deleted           | ConsumeEventDeletedEventUseCase |

### リポジトリ実装

| ポートインターフェース | 実装クラス                  | データストア                                            |
| ---------------------- | --------------------------- | ------------------------------------------------------- |
| TimelineItemRepository | MySQLTimelineItemRepository | MySQL 8.0 / MariaDB 10.11 (timeline_items table, partition by month、CI で互換性テスト) |
| FeedCacheRepository    | RedisFeedCacheRepository    | Redis 7.x (Sorted Set by score=occurred_at timestamp、Beta: XServer VPS / 本番: OCI Cache with Redis) |
| OrgTimelineRepository  | MySQLOrgTimelineRepository  | MySQL 8.0 / MariaDB 10.11 (org_timelines view + 集計テーブル)                          |

### 外部サービスアダプタ

| ポートインターフェース | アダプタクラス               | 外部システム                                                                |
| ---------------------- | ---------------------------- | --------------------------------------------------------------------------- |
| PermissionPort         | PermissionServiceGRPCAdapter | recerdo-permission (gRPC CheckFriendship, GetUser)                     |
| EventPublisherPort     | QueueEventPublisher          | QueuePort トピック `recuerdo.timeline.events`（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service） |
| QueueEventConsumerPort | QueueEventConsumer           | QueuePort トピック `recuerdo.events.service.published`, `recuerdo.auth.friendship_created`, `recuerdo.events.deleted` |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + net/http (HTTPサーバー) + chi/v5 (router) + 構造化ログ (zap) + OpenTelemetry (tracing)

### データベース

**MySQL 8.0 / MariaDB 10.11** (main; Beta: XServer VPS、本番: OCI MySQL HeatWave):
- timeline_items table: 月単位でパーティション分割（`PARTITION BY RANGE (TO_DAYS(occurred_at))`、ALTER TABLE REORGANIZE PARTITION で月次追加）
- インデックス: (user_id, occurred_at DESC), (org_id, occurred_at DESC), (event_id), (hidden_at)
- JSON 列（`payload`）: MariaDB / MySQL の `JSON` 型を利用（PostgreSQL の JSONB ではない）
- リテンション: 7年間の full timeline 保持
- 互換性: `go-sql-driver/mysql` を利用し、MySQL 8.0 と MariaDB 10.11 双方を CI で検証（PostgreSQL 固有機能は不使用）

**Redis 7.x** (cache; Beta: XServer VPS 共用、本番: OCI Cache with Redis):
- user:{user_id}:timeline → Sorted Set (members = timeline_item JSON, score = occurred_at timestamp)
- TTL: 5分（頻繁にアクセスされるユーザー → 自動延長）
- connection pool: max 20

### 主要ライブラリ・SDK

| ライブラリ                               | 目的                                             | レイヤー       |
| ---------------------------------------- | ------------------------------------------------ | -------------- |
| github.com/oklog/ulid/v2                 | ULID 生成・parse（sortable ID）                  | Domain         |
| github.com/go-sql-driver/mysql           | MySQL 8.0 / MariaDB 10.11 driver（connection pooling, batch queries） | Infrastructure |
| github.com/redis/go-redis/v9             | Redis client (Sorted Set, cache操作)             | Infrastructure |
| github.com/hibiken/asynq                 | QueuePort Beta 実装（asynq / Go）                | Infrastructure |
| taskforcesh/bullmq (Node ワーカー側)     | QueuePort Beta 実装（Redis+BullMQ）              | Infrastructure |
| github.com/oracle/oci-go-sdk             | QueuePort 本番実装（OCI Queue Service）          | Infrastructure |
| google.golang.org/grpc                   | Permission Service gRPC client                   | Infrastructure |
| github.com/go-chi/chi/v5                 | HTTP router                                      | Infrastructure |
| encoding/json                            | JSON encode/decode                              | Infrastructure |
| go.opentelemetry.io/otel                 | distributed tracing・W3C traceparent             | Infrastructure |
| uber-go/zap                              | structured logging                               | Infrastructure |
| stretchr/testify                         | unit test assertions                             | Test           |

### 依存性注入

uber-go/fx を使用。

```go
fx.Provide(
    // Repositories
    NewMySQLTimelineItemRepository,  // → TimelineItemRepository
    NewRedisFeedCacheRepository,          // → FeedCacheRepository
    NewMySQLOrgTimelineRepository,   // → OrgTimelineRepository
    
    // Service Adapters
    NewPermissionServiceGRPCAdapter,      // → PermissionPort
    NewQueueEventPublisher,               // → EventPublisherPort (Beta: Redis+BullMQ/asynq、本番: OCI Queue)
    NewQueueEventConsumer,                // → QueueEventConsumerPort
    
    // Utilities
    NewULIDGenerator,                     // → ULIDGeneratorPort
    
    // UseCases
    NewGetUserTimelineUseCase,
    NewGetOrgTimelineUseCase,
    NewGetUserFeedUseCase,
    NewCreateTimelineItemUseCase,
    NewHideTimelineItemUseCase,
    NewConsumeEventServiceEventUseCase,
    NewConsumeFriendshipEventUseCase,
    
    // Handlers
    NewHTTPTimelineHandler,
    NewQueueEventConsumer,
)
```

## 6. ディレクトリ構成

### ディレクトリツリー

```
recerdo-timeline/
├── cmd/server/
│   ├── main.go
│   └── wire.go                    # fx DI setup
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── timeline_item.go
│   │   │   ├── user_feed.go
│   │   │   └── org_timeline.go
│   │   ├── valueobject/
│   │   │   ├── timeline_item_type.go
│   │   │   ├── visibility.go
│   │   │   ├── feed_cursor.go
│   │   │   ├── timeline_payload.go
│   │   │   └── ulid.go
│   │   ├── event/
│   │   │   └── domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── get_user_timeline.go      # 主要ユースケース
│   │   ├── get_org_timeline.go
│   │   ├── get_user_feed.go
│   │   ├── create_timeline_item.go
│   │   ├── hide_timeline_item.go
│   │   ├── consume_event_service_event.go
│   │   ├── consume_friendship_event.go
│   │   ├── consume_event_deleted_event.go
│   │   ├── cache_invalidate_user_feed.go
│   │   ├── preload_feed_cache.go
│   │   └── port/
│   │       ├── repository.go
│   │       └── service.go
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── timeline_handler.go
│   │   │   ├── health_handler.go
│   │   │   └── dto/
│   │   │       ├── request.go
│   │   │       └── response.go
│   │   ├── queue/
│   │   │   └── sqs_consumer.go
│   │   └── middleware/
│   │       ├── auth_middleware.go
│   │       └── trace_middleware.go
│   └── infrastructure/
│       ├── MySQL/
│       │   ├── timeline_item_repo.go
│       │   ├── org_timeline_repo.go
│       │   └── migration.sql       # timeline_items table definition
│       ├── redis/
│       │   └── feed_cache_repo.go
│       ├── grpc/
│       │   └── permission_adapter.go
│       ├── sqs/
│       │   ├── event_consumer.go
│       │   └── event_publisher.go
│       └── ulid/
│           └── generator.go
├── config/
│   └── config.yaml
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── statefulset.yaml            # Redis 必要？→ 外部管理
├── test/
│   ├── integration/
│   │   ├── timeline_item_test.go
│   │   ├── feed_cache_test.go
│   │   └── sqs_consumer_test.go
│   └── fixtures/
│       └── test_data.sql
├── go.mod
├── go.sum
└── Makefile
```

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー                    | テスト種別       | モック戦略                                                      | 例                                                                        |
| --------------------------- | ---------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Domain (entity/valueobject) | Unit test        | 外部依存なし                                                    | TimelineItem.Validate(), FeedCursor.Encode/Decode(), Visibility.IsValid() |
| UseCase                     | Unit test        | mockery で全ポート（PermissionPort/EventPublisherPort）をモック | GetUserTimelineUseCase.Execute() with mocked repository                   |
| Adapter (HTTP handler)      | Integration test | httptest.Server + mocked repositories                           | GET /api/users/{user_id}/timeline 完全フロー                              |
| Infrastructure (MySQL)      | Integration test | testcontainers-go で MySQL 8.0 / MariaDB 10.11 コンテナを両方起動 | timeline_items INSERT・partition、index query（互換性 CI）              |
| Infrastructure (Redis)      | Integration test | testcontainers-go でRedis 7コンテナ起動                         | feed cache SET/GET・TTL・Sorted Set操作                                   |
| Queue Consumer              | Integration test | testcontainers-go で Redis + BullMQ（または asynq）を起動 + mocked repositories | Queue event consume → CreateTimelineItem                    |
| E2E                         | E2E test         | real MySQL 8.0/MariaDB 10.11・Redis・Redis+BullMQ（testcontainers）    | create event → Queue consume → timeline item appears in feed |

### テストコード例

```go
// Entity Test
func TestTimelineItem_IsVisible_PrivateItemOwnersOnly(t *testing.T) {
    item := &TimelineItem{
        ID:         generateULID(),
        UserID:     stringPtr("user-1"),
        ItemType:   ItemTypeEventCreated,
        Visibility: VisibilityPRIVATE,
        OccurredAt: time.Now(),
    }
    
    // owner が閲覧 → visible
    ok, err := item.IsVisible(stringPtr("user-1"), nil)
    assert.NoError(t, err)
    assert.True(t, ok)
    
    // non-owner が閲覧 → invisible
    ok, err = item.IsVisible(stringPtr("user-2"), nil)
    assert.NoError(t, err)
    assert.False(t, ok)
    
    // anonymous が閲覧 → invisible
    ok, err = item.IsVisible(nil, nil)
    assert.NoError(t, err)
    assert.False(t, ok)
}

func TestTimelineItem_IsVisible_FriendsItemRequiresRelation(t *testing.T) {
    item := &TimelineItem{
        ID:         generateULID(),
        UserID:     stringPtr("user-1"),
        ItemType:   ItemTypeEventCreated,
        Visibility: VisibilityFRIENDS,
        OccurredAt: time.Now(),
    }
    
    mockPerm := new(MockPermissionPort)
    mockPerm.On("CheckFriendship", context.Background(), "user-2", "user-1").Return(true, nil)
    
    ok, err := item.IsVisible(stringPtr("user-2"), mockPerm)
    assert.NoError(t, err)
    assert.True(t, ok)
    mockPerm.AssertCalled(t, "CheckFriendship", context.Background(), "user-2", "user-1")
}

func TestTimelineItem_IsVisible_PublicItemsVisible(t *testing.T) {
    item := &TimelineItem{
        ID:         generateULID(),
        UserID:     stringPtr("user-1"),
        ItemType:   ItemTypeEventCreated,
        Visibility: VisibilityPUBLIC,
        OccurredAt: time.Now(),
    }
    
    // anyone can view
    ok, err := item.IsVisible(stringPtr("user-2"), nil)
    assert.NoError(t, err)
    assert.True(t, ok)
    
    ok, err = item.IsVisible(nil, nil)
    assert.NoError(t, err)
    assert.True(t, ok)
}

func TestTimelineItem_Validate_InvalidPayloadSchema(t *testing.T) {
    item := &TimelineItem{
        ID:       generateULID(),
        ItemType: ItemTypeEventCreated,
        Payload: TimelinePayload{
            data: map[string]interface{}{
                // missing required "event_name"
                "event_id": "evt-123",
            },
        },
        OccurredAt: time.Now(),
        Visibility: VisibilityFRIENDS,
    }
    
    err := item.Validate()
    assert.ErrorIs(t, err, ErrMissingPayloadField)
}

func TestFeedCursor_EncodeDecode_RoundTrip(t *testing.T) {
    original := &FeedCursor{
        LastSeenID:        generateULID(),
        LastSeenTimestamp: time.Now().Unix(),
    }
    
    encoded := original.Encode()
    assert.NotEmpty(t, encoded)
    
    decoded, err := DecodeFeedCursor(encoded)
    assert.NoError(t, err)
    assert.Equal(t, original.LastSeenID, decoded.LastSeenID)
    assert.Equal(t, original.LastSeenTimestamp, decoded.LastSeenTimestamp)
}

func TestFeedCursor_Decode_InvalidFormat(t *testing.T) {
    _, err := DecodeFeedCursor("not-base64!!!")
    assert.ErrorIs(t, err, ErrInvalidCursorFormat)
    
    _, err = DecodeFeedCursor(base64.StdEncoding.EncodeToString([]byte("missing-colon")))
    assert.ErrorIs(t, err, ErrInvalidCursorFormat)
    
    _, err = DecodeFeedCursor(base64.StdEncoding.EncodeToString([]byte("invalid-ulid:not-timestamp")))
    assert.ErrorIs(t, err, ErrInvalidCursorTimestamp)
}

// UseCase Test
func TestGetUserTimelineUseCase_HappyPath(t *testing.T) {
    mockRepo := new(MockTimelineItemRepository)
    mockCache := new(MockFeedCacheRepository)
    mockPerm := new(MockPermissionPort)
    
    // cache miss
    mockCache.On("GetFeed", context.Background(), "user-1").Return(nil, redis.Nil)
    
    // query from DB
    items := []TimelineItem{
        {
            ID:         generateULID(),
            UserID:     stringPtr("user-1"),
            ItemType:   ItemTypeEventCreated,
            Visibility: VisibilityPUBLIC,
            OccurredAt: time.Now().Add(-1 * time.Hour),
        },
    }
    mockRepo.On("QueryUserTimeline", context.Background(), "user-1", nil, 21).Return(items, nil)
    
    // friendship check for FRIENDS items
    mockPerm.On("CheckFriendship", context.Background(), "user-1", "user-1").Return(true, nil)
    
    // cache write
    mockCache.On("SetFeed", context.Background(), "user-1", mock.Anything, 5*time.Minute).Return(nil)
    
    uc := NewGetUserTimelineUseCase(mockRepo, mockCache, mockPerm)
    output, err := uc.Execute(context.Background(), GetUserTimelineInput{
        UserID:           "user-1",
        RequestingUserID: stringPtr("user-1"),
        Cursor:           nil,
        Limit:            20,
    })
    
    assert.NoError(t, err)
    assert.Len(t, output.Items, 1)
    assert.False(t, output.HasMore)
    mockCache.AssertCalled(t, "SetFeed", context.Background(), "user-1", mock.Anything, 5*time.Minute)
}

func TestGetUserTimelineUseCase_CursorPagination(t *testing.T) {
    mockRepo := new(MockTimelineItemRepository)
    mockCache := new(MockFeedCacheRepository)
    mockPerm := new(MockPermissionPort)
    
    // cache miss
    mockCache.On("GetFeed", context.Background(), "user-1").Return(nil, redis.Nil)
    
    // cursor 指定：21 item fetch（has_more 判定用）
    cursor := &FeedCursor{
        LastSeenID:        generateULID(),
        LastSeenTimestamp: time.Now().Unix(),
    }
    
    // generate 21 items
    var items []TimelineItem
    for i := 0; i < 21; i++ {
        items = append(items, TimelineItem{
            ID:         generateULID(),
            UserID:     stringPtr("user-1"),
            ItemType:   ItemTypeEventCreated,
            Visibility: VisibilityPUBLIC,
            OccurredAt: time.Now().Add(-1 * time.Duration(i) * time.Hour),
        })
    }
    
    mockRepo.On("QueryUserTimeline", context.Background(), "user-1", cursor, 21).Return(items, nil)
    mockPerm.On("CheckFriendship", context.Background(), "user-1", "user-1").Return(true, nil)
    mockCache.On("SetFeed", context.Background(), "user-1", mock.Anything, 5*time.Minute).Return(nil)
    
    uc := NewGetUserTimelineUseCase(mockRepo, mockCache, mockPerm)
    output, err := uc.Execute(context.Background(), GetUserTimelineInput{
        UserID:           "user-1",
        RequestingUserID: stringPtr("user-1"),
        Cursor:           cursor,
        Limit:            20,
    })
    
    assert.NoError(t, err)
    assert.Len(t, output.Items, 20)
    assert.True(t, output.HasMore)
    assert.NotNil(t, output.NextCursor)
}

// Integration Test: HTTP Handler
func TestGetUserTimelineHandler_Integration(t *testing.T) {
    // setup: real repo (testcontainers) + real cache
    pgContainer := setupMySQLContainer(t)
    defer pgContainer.Terminate(context.Background())
    
    redisContainer := setupRedisContainer(t)
    defer redisContainer.Terminate(context.Background())
    
    // insert test data
    item := &TimelineItem{
        ID:         generateULID(),
        UserID:     stringPtr("user-1"),
        ItemType:   ItemTypeEventCreated,
        Visibility: VisibilityPUBLIC,
        Payload: TimelinePayload{data: map[string]interface{}{
            "event_id":   "evt-123",
            "event_name": "Reunion 2024",
        }},
        OccurredAt: time.Now(),
    }
    repo.Create(context.Background(), item)
    
    // mock permission service
    mockPerm := new(MockPermissionPort)
    mockPerm.On("CheckFriendship", context.Background(), "user-1", "user-1").Return(true, nil)
    
    handler := NewHTTPTimelineHandler(repo, cache, mockPerm)
    
    // HTTP request
    req := httptest.NewRequest("GET", "/api/users/user-1/timeline", nil)
    req.Header.Set("X-User-Id", "user-1")
    w := httptest.NewRecorder()
    
    handler.GetUserTimeline(w, req)
    
    assert.Equal(t, http.StatusOK, w.Code)
    
    var resp GetUserTimelineResponse
    err := json.NewDecoder(w.Body).Decode(&resp)
    assert.NoError(t, err)
    assert.Len(t, resp.Items, 1)
    assert.Equal(t, "user-1", *resp.Items[0].UserID)
}

// Integration Test: Queue Consumer（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）
func TestConsumeEventServiceEvent_Integration(t *testing.T) {
    // setup: real MySQL 8.0 / MariaDB 10.11 + Redis（BullMQ / asynq 用）
    dbContainer := setupMySQLContainer(t) // MySQL 8.0 または MariaDB 10.11
    redisContainer := setupRedisContainer(t)

    // QueuePort 経由でメッセージを投入（Beta: asynq、テストでは redis-backed な testcontainer）
    queuePort := newAsynqQueueAdapter(redisContainer.Addr())

    event := map[string]interface{}{
        "event_id":    "evt-456",
        "event_name":  "Team Gathering",
        "event_type":  "EVENT_CREATED",
        "user_id":     "user-2",
        "occurred_at": time.Now().Unix(),
        "description": "Annual team gathering",
    }
    eventJSON, _ := json.Marshal(event)

    _ = queuePort.Enqueue(context.Background(), port.Job{
        ID:      "job-1",
        Topic:   "recuerdo.events.service.published",
        Payload: eventJSON,
    })

    // run consumer
    consumer := NewQueueEventConsumer(repo, cache, queuePort)
    err := consumer.ConsumeEventServiceEvent(context.Background(), port.Job{
        ID:      "job-1",
        Topic:   "recuerdo.events.service.published",
        Payload: eventJSON,
    })

    assert.NoError(t, err)

    // verify: timeline_item inserted
    items, err := repo.QueryByEventID(context.Background(), "evt-456")
    assert.NoError(t, err)
    assert.Len(t, items, 1)
    assert.Equal(t, ItemTypeEventCreated, items[0].ItemType)
}
```

## 8. エラーハンドリング

### ドメインエラー

- **ErrTimelineItemNotFound**: 指定 ULID の timeline item が存在しない
- **ErrInvalidTimelineItemID**: ULID 形式が不正
- **ErrInvalidItemType**: item_type が enum に含まれない
- **ErrInvalidVisibility**: visibility が PUBLIC/FRIENDS/PRIVATE でない
- **ErrMissingPayloadField**: payload に必須フィールドが不足（item_type 毎に検証）
- **ErrInvalidPayloadSchema**: payload スキーマが item_type と不一致
- **ErrFutureOccurredAt**: occurred_at が現在時刻より未来
- **ErrUserNotFound**: user_id が Permission Service に存在しない
- **ErrOrgNotFound**: org_id が存在しない
- **ErrPrivateItemsNotAllowedInOrgTimeline**: PRIVATE visibility item を org timeline に add しようとした
- **ErrInvalidCursorFormat**: cursor の base64 decode 失敗
- **ErrInvalidCursorID**: cursor の id が valid ULID でない
- **ErrInvalidCursorTimestamp**: cursor の timestamp が valid unix timestamp でない
- **ErrLimitExceeded**: query limit が最大値（100）を超えている
- **ErrFriendshipNotFound**: 2ユーザー間に friendship relation が存在しない
- **ErrEventDeleted**: 参照先 event_id が削除されている
- **ErrCacheWriteFailure**: Redis cache write に失敗（retry logic）

### エラー → HTTPステータスマッピング

| ドメインエラー                         | HTTPステータス            | ユーザーメッセージ                            | 処理内容                                   |
| -------------------------------------- | ------------------------- | --------------------------------------------- | ------------------------------------------ |
| ErrTimelineItemNotFound                | 404 Not Found             | Timeline item not found                       | ログ記録のみ                               |
| ErrUserNotFound                        | 404 Not Found             | User not found                                | 権限チェック失敗                           |
| ErrOrgNotFound                         | 404 Not Found             | Organization not found                        | org timeline 取得失敗                      |
| ErrInvalidTimelineItemID               | 400 Bad Request           | Invalid timeline item ID format               | リクエストバリデーション                   |
| ErrInvalidItemType                     | 400 Bad Request           | Invalid item type                             | item creation validation                   |
| ErrInvalidVisibility                   | 400 Bad Request           | Invalid visibility level                      | リクエストバリデーション                   |
| ErrMissingPayloadField                 | 400 Bad Request           | Missing required payload field: {field_name}  | item creation validation                   |
| ErrFutureOccurredAt                    | 400 Bad Request           | Occurred time cannot be in the future         | domain rule violation                      |
| ErrInvalidCursorFormat                 | 400 Bad Request           | Invalid cursor format                         | cursor parse error                         |
| ErrLimitExceeded                       | 400 Bad Request           | Limit exceeds maximum (100)                   | query param validation                     |
| ErrFriendshipNotFound                  | 403 Forbidden             | You do not have permission to view this item  | permission denied                          |
| ErrPrivateItemsNotAllowedInOrgTimeline | 400 Bad Request           | Private items cannot be added to org timeline | domain rule violation                      |
| ErrEventDeleted                        | 410 Gone                  | Referenced event has been deleted             | cascading delete                           |
| ErrCacheWriteFailure                   | 500 Internal Server Error | Internal server error                         | retry 後も失敗時はログ警告・リクエスト続行 |
| Other DB errors                        | 500 Internal Server Error | Internal server error                         | structured log + alert                     |

## 9. 未決事項

### 質問・決定事項

| #   | 質問                                                                                                                            | ステータス | 決定                                                                                                                               |
| --- | ------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Timeline item の retention policy は何年間か。7年間の full history 保持か、それともアーカイブ・削除ポリシーを導入するか         | ✅ Decided | 初期: 7年間 full retain（MySQL / MariaDB 10.11 互換、`PARTITION BY RANGE (YEAR*100+MONTH)`）。ボリューム増加時は月次 partition を Garage（Beta）／OCI Object Storage Archive tier（本番）へ NDJSON+gzip で冷蔵移送。AWS S3 は不使用（[基本的方針](../core/policy.md) §3.2） |
| 2   | Redis cache TTL 5分で十分か。ホットユーザー（毎日複数回アクセス）はキャッシュミスが多くないか                                   | Open       | 初期: 5分。アクセスパターン分析後、ホットユーザーは 15分 に延長検討                                                                |
| 3   | item_type 追加時の backward compatibility。新タイプを Timeline Service が理解しない QueuePort メッセージが流入したときどう扱うか | ✅ Decided | `unknown_item_type` 専用メトリクスをインクリメントしつつ log + skip（削除はせず DB に append-only で保存、Consumer は graceful degrade） |
| 4   | org timeline の materialized view をいつ refresh するのか。毎回集計計算か、定期バッチか                                         | Open       | 初期: CreateTimelineItem + HideTimelineItem 時に incremental update（UPSERT）。夜間バッチで full recalc 検討                       |
| 5   | Permission Service の friendship check で 150ms タイムアウト。Response time P95 > 100ms の場合、local friend cache を持つべきか | Open       | 未決定。Timeline Service が Permission Service dependency でレイテンシ増加。Cache local friends in Redis（sync latency <1sec）検討 |
| 6   | QueuePort consumer の dead letter queue (DLQ) handling。poison message（invalid JSON）をどこに保存して alert するか              | ✅ Decided | Beta: BullMQ failed queue / asynq archived queue、本番: OCI Queue DLQ に投入。Prometheus Alertmanager → admin-console-svc に Loki ログ通知。manual replay は Garage（Beta）/ OCI Object Storage（本番）に NDJSON+gzip で backup（AWS CloudWatch / S3 は不使用） |
| 7   | Cursor pagination の安定性。occurred_at が同一の items が大量存在する場合、cursor offset が ambiguous になる可能性がある        | Open       | 未決定。occurred_at 同一時点では secondary sort を ID (tie-breaker) に追加。DB query で確認                                        |
| 8   | Public/Friends timeline の "全員表示" アイテムを月単位で集計キャッシュする。月跨ぎ pagination はどう扱うか                      | Open       | 初期: cursor に month 情報を include。month 跨ぎ時に query 分割実装                                                                |

---

最終更新: 2026-04-19 ポリシー適用
