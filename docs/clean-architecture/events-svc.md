# クリーンアーキテクチャ設計書

| 項目                      | 値                                   |
| ------------------------- | ------------------------------------ |
| **モジュール/サービス名** | Events Service (recuerdo-events-svc) |
| **作成者**                | Akira                                |
| **作成日**                | 2026-04-13                           |
| **ステータス**            | ドラフト                             |
| **バージョン**            | 1.0                                  |

---

## 1. 概要

### 1.1 目的
Events Service はRecuerdo プラットフォームにおいて、イベント（パーティー、旅行、再会など）を中核的に管理するマイクロサービスである。組織内のメンバーを招待し、イベント参加者を追跡し、イベントベースの活動を調整する責務を担う。

### 1.2 ビジネスコンテキスト
- Recuerdo は古い友人や団体との再接続を可能にするソーシャルメモリプラットフォーム（Viejo App）
- イベントは組織内の活動の主な構成単位：写真共有、タイムラインアグリゲーション、招待フロー
- ユースケース：同窓会、家族再会、ノスタルジック旅行グループの企画と管理

### 1.3 アーキテクチャ原則
- **エンティティの独立性**：イベント管理ロジックはUI・フレームワーク・データベースに依存しない
- **ドメイン駆動設計**：EventStatus、EventCode、InvitationStatus などの値オブジェクトでビジネスルール表現
- **イベント駆動型アーキテクチャ**：EventCreated、EventArchived などを QueuePort 経由で発行し、Album Service、Timeline Service などと疎結合
  - Beta: Redis + BullMQ/asynq（self-hosted）
  - Prod: OCI Queue Service
  - AWS SQS / SNS は使用しない（ポリシー: AWS = Cognito のみ）
- **境界の明確化**：入力検証はユースケース層、UI マッピングはプレゼンター層で実施

---

## 2. レイヤーアーキテクチャ

### 2.1 アーキテクチャ図 (ASCII concentric circles)

```
┌─────────────────────────────────────────────────────┐
│  フレームワーク＆ドライバ層                          │
│  (Web: Gin, DB: MySQL(MariaDB互換),                │
│   Queue: Redis+BullMQ or OCI Queue, Redis)         │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  インターフェースアダプタ層                        │
│  (HTTP Handler, Repository Impl,                  │
│   Presenter, External API Adapter)                │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  ユースケース層 (アプリケーション)                │
│  (CreateEventUseCase, InviteMemberUseCase,        │
│   JoinEventByCodeUseCase, ArchiveEventUseCase)    │
└────────────┬──────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────┐
│  エンティティ層 (ドメイン)                        │
│  (Event, EventInvitation, EventParticipant,       │
│   ドメインルール、値オブジェクト)                 │
└─────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール
- **内側への依存のみ**：外側のレイヤーは内側のレイヤーに依存、内側は外側に依存しない
- **プラグイン性**：リポジトリ実装、外部API アダプタはインターフェースを通じた入れ替え可能
- **テスト性**：ユースケース層は Mock リポジトリ、Mock イベント発行者でテスト可能

---

## 3. エンティティ層（ドメイン）

### 3.1 ドメインモデル

| エンティティ         | 説明                                                                             |
| -------------------- | -------------------------------------------------------------------------------- |
| **Event**            | イベントの中核：パーティー、旅行、再会。所有組織、参加者、ステータスで管理       |
| **EventInvitation**  | ユーザーへのイベント招待：メールアドレスベース、有効期限あり、ステータス遷移管理 |
| **EventParticipant** | イベント参加者の追跡：Event - User のマッピング、ロール、参加日時                |

### 3.2 値オブジェクト

| 値オブジェクト       | 許可される値                                         | 不変性                                    |
| -------------------- | ---------------------------------------------------- | ----------------------------------------- |
| **EventStatus**      | DRAFT, ACTIVE, ARCHIVED                              | イミュータブル、遷移ルールで保護          |
| **InvitationStatus** | PENDING, ACCEPTED, DECLINED, EXPIRED                 | EXPIRED への自動遷移は expiresAt チェック |
| **EventCode**        | 英大文字・数字・ハイフン、max 30文字、org 内ユニーク | 作成時にバリデーション、変更不可          |
| **EventRole**        | OWNER, ADMIN, MEMBER, GUEST                          | イミュータブル                            |

### 3.3 ドメインルール / 不変条件

- **Event Code Uniqueness**：EventCode は組織内で一意（例：SUMMER-PARTY-2026）
- **Archive Read-Only**：ARCHIVED ステータスのイベントは変更不可、追加参加者も受け付けない
- **Invitation Expiry**：招待は発行から30日で自動 EXPIRED → 返却時にステータス自動評価
- **Invitation Permission**：OWNER/ADMIN のみが他のメンバーを招待可能
- **Date Ordering**：start_date < end_date は常に真
- **Draft to Active**：DRAFT → ACTIVE には title が必須、start_date/end_date の有効性チェック
- **Creator Constraint**：Event 作成者は自動的に OWNER ロール付与

### 3.4 ドメインイベント

| イベント                    | トリガー                 | ペイロード                             | 購読者                                    |
| --------------------------- | ------------------------ | -------------------------------------- | ----------------------------------------- |
| **EventCreated**            | Event.Create() 成功      | event_id, org_id, title, created_by    | Album Svc, Timeline Svc, Notification Svc |
| **EventArchived**           | Event.Archive() 成功     | event_id, org_id, archived_at          | Timeline Svc, Notification Svc            |
| **EventInvitationSent**     | Invitation.Send() 成功   | event_id, invitee_email, invited_by    | Notification Svc (メール送信)             |
| **EventInvitationAccepted** | Invitation.Accept() 成功 | event_id, user_id, org_id, accepted_at | Timeline Svc, Notification Svc            |

### 3.5 エンティティ定義 (Go pseudocode)

```go
package domain

import "time"

// EventStatus は Event のライフサイクルステータス
type EventStatus string

const (
    EventStatusDraft    EventStatus = "DRAFT"
    EventStatusActive   EventStatus = "ACTIVE"
    EventStatusArchived EventStatus = "ARCHIVED"
)

// EventCode はイベントの一意な識別子（ユーザー向け）
type EventCode struct {
    value string // 英大文字・数字・ハイフン、max 30
}

func NewEventCode(val string) (EventCode, error) {
    if len(val) == 0 || len(val) > 30 {
        return EventCode{}, fmt.Errorf("invalid length")
    }
    if !isValidEventCodeFormat(val) {
        return EventCode{}, fmt.Errorf("invalid format")
    }
    return EventCode{value: val}, nil
}

// Event ドメインエンティティ
type Event struct {
    ID              string       // ULID
    OrgID           string
    Title           string
    EventCode       EventCode
    Description     string
    StartDate       time.Time
    EndDate         time.Time
    Status          EventStatus
    CoverMediaID    *string
    CreatedBy       string // user_id
    CreatedAt       time.Time
    domainEvents    []interface{}
}

// Create ファクトリメソッド：ドメインルール適用
func NewEvent(orgID, title string, code EventCode, startDate, endDate time.Time, createdBy string) (*Event, error) {
    if startDate.After(endDate) {
        return nil, fmt.Errorf("start_date must be before end_date")
    }
    if title == "" {
        return nil, fmt.Errorf("title required")
    }
    
    e := &Event{
        ID:        generateULID(),
        OrgID:     orgID,
        Title:     title,
        EventCode: code,
        StartDate: startDate,
        EndDate:   endDate,
        Status:    EventStatusDraft,
        CreatedBy: createdBy,
        CreatedAt: time.Now(),
    }
    e.recordEvent(&EventCreatedEvent{
        EventID:   e.ID,
        OrgID:     orgID,
        Title:     title,
        CreatedBy: createdBy,
    })
    return e, nil
}

// Activate ドメイン操作：DRAFT → ACTIVE
func (e *Event) Activate() error {
    if e.Status != EventStatusDraft {
        return fmt.Errorf("only DRAFT events can be activated")
    }
    if e.Title == "" {
        return fmt.Errorf("title required to activate")
    }
    e.Status = EventStatusActive
    return nil
}

// Archive ドメイン操作：→ ARCHIVED（読み取り専用化）
func (e *Event) Archive() error {
    if e.Status == EventStatusArchived {
        return fmt.Errorf("already archived")
    }
    e.Status = EventStatusArchived
    e.recordEvent(&EventArchivedEvent{
        EventID:    e.ID,
        OrgID:      e.OrgID,
        ArchivedAt: time.Now(),
    })
    return nil
}

// IsReadOnly アーカイブ済みはロック
func (e *Event) IsReadOnly() bool {
    return e.Status == EventStatusArchived
}

// DomainEvents ドメインイベント取得＆クリア（集約パターン）
func (e *Event) DomainEvents() []interface{} {
    events := e.domainEvents
    e.domainEvents = []interface{}{}
    return events
}

func (e *Event) recordEvent(event interface{}) {
    e.domainEvents = append(e.domainEvents, event)
}

// InvitationStatus 招待ステータス
type InvitationStatus string

const (
    InvitationStatusPending  InvitationStatus = "PENDING"
    InvitationStatusAccepted InvitationStatus = "ACCEPTED"
    InvitationStatusDeclined InvitationStatus = "DECLINED"
    InvitationStatusExpired  InvitationStatus = "EXPIRED"
)

// EventInvitation ドメインエンティティ
type EventInvitation struct {
    ID        string
    EventID   string
    OrgID     string
    Email     string
    InvitedBy string // user_id
    Role      EventRole
    Status    InvitationStatus
    ExpiresAt time.Time
    CreatedAt time.Time
}

// NewEventInvitation ファクトリメソッド
func NewEventInvitation(eventID, orgID, email, invitedBy string, role EventRole) (*EventInvitation, error) {
    if !isValidEmail(email) {
        return nil, fmt.Errorf("invalid email")
    }
    return &EventInvitation{
        ID:        generateULID(),
        EventID:   eventID,
        OrgID:     orgID,
        Email:     email,
        InvitedBy: invitedBy,
        Role:      role,
        Status:    InvitationStatusPending,
        ExpiresAt: time.Now().AddDate(0, 0, 30), // 30日有効
        CreatedAt: time.Now(),
    }, nil
}

// EvaluateExpiry ステータス評価（自動 EXPIRED へ遷移）
func (ei *EventInvitation) EvaluateExpiry() {
    if ei.Status == InvitationStatusPending && time.Now().After(ei.ExpiresAt) {
        ei.Status = InvitationStatusExpired
    }
}

// Accept 招待受け入れ
func (ei *EventInvitation) Accept() error {
    ei.EvaluateExpiry()
    if ei.Status != InvitationStatusPending {
        return fmt.Errorf("invitation not in PENDING state")
    }
    ei.Status = InvitationStatusAccepted
    return nil
}

// EventParticipant イベント参加者
type EventParticipant struct {
    EventID  string
    UserID   string
    Role     EventRole
    JoinedAt time.Time
}

// EventRole ロール（権限）
type EventRole string

const (
    EventRoleOwner  EventRole = "OWNER"
    EventRoleAdmin  EventRole = "ADMIN"
    EventRoleMember EventRole = "MEMBER"
    EventRoleGuest  EventRole = "GUEST"
)

// ドメインイベント（集約外への発行）
type EventCreatedEvent struct {
    EventID   string
    OrgID     string
    Title     string
    CreatedBy string
}

type EventArchivedEvent struct {
    EventID    string
    OrgID      string
    ArchivedAt time.Time
}

type EventInvitationSentEvent struct {
    EventID    string
    InviteeEmail string
    InvitedBy  string
}

type EventInvitationAcceptedEvent struct {
    EventID    string
    UserID     string
    OrgID      string
    AcceptedAt time.Time
}
```

---

## 4. ユースケース層（アプリケーション）

### 4.1 ユースケース一覧

| ユースケース            | 説明                                 | アクター                 | 主成功シナリオ                                     |
| ----------------------- | ------------------------------------ | ------------------------ | -------------------------------------------------- |
| **CreateEvent**         | 新規イベント作成（DRAFT 状態）       | Org Member (ADMIN/OWNER) | Event 作成、ULID 生成、状態=DRAFT                  |
| **UpdateEvent**         | イベント編集（DRAFT のみ）           | Org Admin                | title/description/dates 更新                       |
| **ArchiveEvent**        | イベントをアーカイブ（読み取り専用） | Org Admin                | Status → ARCHIVED、新規参加者拒否                  |
| **InviteMemberByEmail** | メール経由でメンバーを招待           | Org Admin/Owner          | Invitation 作成、30日有効期限、通知発行            |
| **JoinEventByCode**     | イベントコードで参加                 | Org Member               | EventCode 検証、EventParticipant 追加              |
| **AcceptInvitation**    | 招待を受け入れる                     | Invited User             | Status PENDING→ACCEPTED、EventParticipant 追加     |
| **ListOrgEvents**       | 組織のイベント一覧                   | Org Member               | ページング、キャッシュサポート、ステータスフィルタ |

### 4.2 ユースケース詳細 (CreateEvent - main use case)

**Actor**: 組織管理者

**Pre-conditions**:
- ユーザーが org に属する
- ユーザーが ADMIN または OWNER ロール

**Main Flow**:
1. ユーザーが CreateEventRequest（title, description, startDate, endDate, eventCode）を入力
2. ユースケース層が Request を受け取る
3. EventCode の一意性チェック（リポジトリ呼び出し）
4. Event.NewEvent() でドメインエンティティを構築
5. Event.DomainEvents() を取得
6. EventRepository.Save() で DB に永続化
7. EventCreatedEvent を QueuePort 経由で発行（EventPublisher — Beta: Redis, Prod: OCI Queue）
8. EventID を含む Response を返却

**Post-conditions**:
- Event が DB に DRAFT 状態で保存
- EventCreated が QueuePort に発行 → Album Service, Timeline Service がリッスン

**Errors**:
- EventCode 重複：`ErrEventCodeAlreadyExists`
- 権限不足：`ErrUnauthorized`
- バリデーション失敗：`ErrInvalidInput`

### 4.3 入出力DTO (Go struct pseudocode)

```go
package application

// CreateEventRequest ユースケース入力
type CreateEventRequest struct {
    OrgID       string    `json:"org_id"`
    Title       string    `json:"title"`
    Description string    `json:"description"`
    StartDate   time.Time `json:"start_date"`
    EndDate     time.Time `json:"end_date"`
    EventCode   string    `json:"event_code"`
    CoverMediaID *string  `json:"cover_media_id,omitempty"`
    CreatedBy   string    `json:"created_by"` // user_id
}

// CreateEventResponse ユースケース出力
type CreateEventResponse struct {
    EventID   string    `json:"event_id"`
    Status    string    `json:"status"`
    CreatedAt time.Time `json:"created_at"`
}

// UpdateEventRequest
type UpdateEventRequest struct {
    EventID     string     `json:"event_id"`
    Title       *string    `json:"title,omitempty"`
    Description *string    `json:"description,omitempty"`
    StartDate   *time.Time `json:"start_date,omitempty"`
    EndDate     *time.Time `json:"end_date,omitempty"`
}

// InviteMemberRequest
type InviteMemberRequest struct {
    EventID   string `json:"event_id"`
    OrgID     string `json:"org_id"`
    Email     string `json:"email"`
    Role      string `json:"role"` // MEMBER, GUEST
    InvitedBy string `json:"invited_by"` // user_id
}

// InviteMemberResponse
type InviteMemberResponse struct {
    InvitationID string    `json:"invitation_id"`
    Email        string    `json:"email"`
    ExpiresAt    time.Time `json:"expires_at"`
}

// JoinEventByCodeRequest
type JoinEventByCodeRequest struct {
    OrgID     string `json:"org_id"`
    EventCode string `json:"event_code"`
    UserID    string `json:"user_id"`
}

// JoinEventByCodeResponse
type JoinEventByCodeResponse struct {
    EventID  string `json:"event_id"`
    Title    string `json:"title"`
    JoinedAt time.Time `json:"joined_at"`
}

// AcceptInvitationRequest
type AcceptInvitationRequest struct {
    InvitationID string `json:"invitation_id"`
    UserID       string `json:"user_id"`
}

// ListOrgEventsRequest
type ListOrgEventsRequest struct {
    OrgID      string  `json:"org_id"`
    Status     *string `json:"status,omitempty"` // DRAFT, ACTIVE, ARCHIVED
    Limit      int     `json:"limit"`
    Offset     int     `json:"offset"`
}

// ListOrgEventsResponse
type ListOrgEventsResponse struct {
    Events []EventDTO `json:"events"`
    Total  int64      `json:"total"`
}

type EventDTO struct {
    EventID      string     `json:"event_id"`
    Title        string     `json:"title"`
    Description  string     `json:"description"`
    EventCode    string     `json:"event_code"`
    StartDate    time.Time  `json:"start_date"`
    EndDate      time.Time  `json:"end_date"`
    Status       string     `json:"status"`
    ParticipantCount int    `json:"participant_count"`
    CreatedAt    time.Time  `json:"created_at"`
}
```

### 4.4 リポジトリインターフェース（ポート）

```go
package application

import "context"

// EventRepository イベント永続化のポート
type EventRepository interface {
    // Save イベントを保存（作成・更新両対応）
    Save(ctx context.Context, event *domain.Event) error
    
    // FindByID イベントを ID で検索
    FindByID(ctx context.Context, eventID string) (*domain.Event, error)
    
    // FindByCode イベントをコードで検索（org 内で一意）
    FindByCode(ctx context.Context, orgID, code string) (*domain.Event, error)
    
    // ListByOrg 組織内のイベント一覧（ページング対応）
    ListByOrg(ctx context.Context, orgID string, limit, offset int) ([]*domain.Event, int64, error)
    
    // ExistsByCode EventCode が既に存在するか（重複チェック用）
    ExistsByCode(ctx context.Context, orgID, code string) (bool, error)
}

// EventInvitationRepository 招待永続化のポート
type EventInvitationRepository interface {
    // Save 招待を保存
    Save(ctx context.Context, invitation *domain.EventInvitation) error
    
    // FindByID 招待を ID で検索
    FindByID(ctx context.Context, invitationID string) (*domain.EventInvitation, error)
    
    // FindByEmail イベント内で該当メールの招待を検索
    FindByEmail(ctx context.Context, eventID, email string) (*domain.EventInvitation, error)
    
    // ListPendingByEmail メールアドレス宛の保留中招待一覧
    ListPendingByEmail(ctx context.Context, email string) ([]*domain.EventInvitation, error)
}

// EventParticipantRepository 参加者管理のポート
type EventParticipantRepository interface {
    // Save 参加者追加
    Save(ctx context.Context, participant *domain.EventParticipant) error
    
    // FindByEventAndUser イベント内のユーザー参加情報取得
    FindByEventAndUser(ctx context.Context, eventID, userID string) (*domain.EventParticipant, error)
    
    // ListByEvent イベントの全参加者リスト
    ListByEvent(ctx context.Context, eventID string) ([]*domain.EventParticipant, error)
    
    // CountByEvent イベント参加者数
    CountByEvent(ctx context.Context, eventID string) (int, error)
}
```

### 4.5 外部サービスインターフェース（ポート）

```go
package application

// EventPublisher イベント発行のポート（QueuePort 実装）
// Beta: RedisBullMQAdapter / AsynqAdapter
// Prod: OCIQueueAdapter
type EventEmitter interface {
    // Publish ドメインイベントを発行
    Publish(ctx context.Context, event interface{}) error
    
    // PublishBatch 複数イベントをバッチ発行
    PublishBatch(ctx context.Context, events []interface{}) error
}

// NotificationService 通知サービスのポート
type NotificationService interface {
    // SendInvitationEmail 招待メール送信
    SendInvitationEmail(ctx context.Context, inviteeEmail, eventTitle string, expiresAt time.Time) error
}

// PermissionService 権限検証のポート
type PermissionService interface {
    // CanManageEvent ユーザーがイベントを管理できるか
    CanManageEvent(ctx context.Context, userID, orgID string) (bool, error)
    
    // HasOrgMembership ユーザーが組織に属しているか
    HasOrgMembership(ctx context.Context, userID, orgID string) (bool, error)
}
```

---

## 5. インターフェースアダプタ層

### 5.1 コントローラ / ハンドラ

| ハンドラ                    | HTTP Method | Path                         | 入力                    | 出力                    | 責務                                                       |
| --------------------------- | ----------- | ---------------------------- | ----------------------- | ----------------------- | ---------------------------------------------------------- |
| **CreateEventHandler**      | POST        | /api/events                  | CreateEventRequest      | CreateEventResponse     | リクエスト検証、ユースケース呼び出し、レスポンスマッピング |
| **UpdateEventHandler**      | PUT         | /api/events/{id}             | UpdateEventRequest      | EventDTO                | 権限検証、更新ユースケース呼び出し                         |
| **ArchiveEventHandler**     | PATCH       | /api/events/{id}/archive     | -                       | StatusResponse          | イベントアーカイブ                                         |
| **InviteMemberHandler**     | POST        | /api/events/{id}/invite      | InviteMemberRequest     | InviteMemberResponse    | メール検証、招待ユースケース                               |
| **JoinByCodeHandler**       | POST        | /api/events/join-code        | JoinEventByCodeRequest  | JoinEventByCodeResponse | イベントコード検証、参加                                   |
| **AcceptInvitationHandler** | POST        | /api/invitations/{id}/accept | AcceptInvitationRequest | StatusResponse          | 招待受け入れ                                               |
| **ListOrgEventsHandler**    | GET         | /api/orgs/{org_id}/events    | Query params            | ListOrgEventsResponse   | ページング、キャッシュ取得                                 |

### 5.2 プレゼンター / レスポンスマッパー

```go
package adapter

// EventPresenter ドメインモデル → HTTP レスポンスへのマッピング
type EventPresenter struct {
    cache cacheProvider // Redis キャッシュ
}

// PresentEventDTO Event ドメイン → EventDTO
func (p *EventPresenter) PresentEventDTO(event *domain.Event) *EventDTO {
    return &EventDTO{
        EventID:      event.ID,
        Title:        event.Title,
        Description:  event.Description,
        EventCode:    event.EventCode.String(),
        StartDate:    event.StartDate,
        EndDate:      event.EndDate,
        Status:       string(event.Status),
        CreatedAt:    event.CreatedAt,
    }
}

// PresentListResponse リスト レスポンス構築
func (p *EventPresenter) PresentListResponse(events []*domain.Event, total int64) *ListOrgEventsResponse {
    dtos := make([]EventDTO, len(events))
    for i, e := range events {
        dtos[i] = *p.PresentEventDTO(e)
    }
    return &ListOrgEventsResponse{
        Events: dtos,
        Total:  total,
    }
}

// PresentErrorResponse エラー応答
func PresentErrorResponse(err error) (statusCode int, body map[string]string) {
    if errors.Is(err, ErrUnauthorized) {
        return http.StatusForbidden, map[string]string{"error": "unauthorized"}
    }
    if errors.Is(err, ErrEventCodeAlreadyExists) {
        return http.StatusConflict, map[string]string{"error": "event_code_duplicate"}
    }
    return http.StatusInternalServerError, map[string]string{"error": "internal_error"}
}
```

### 5.3 リポジトリ実装（アダプタ）

| リポジトリ実装                      | 対象             | 技術                  | キャッシング戦略               |
| ----------------------------------- | ---------------- | --------------------- | ------------------------------ |
| **MySQLEventRepository**            | Event            | `database/sql` + sqlc | リスト結果 → Redis (TTL 5min)  |
| **MySQLEventInvitationRepository**  | EventInvitation  | `database/sql` + sqlc | 保留中招待 → Redis (TTL 10min) |
| **MySQLEventParticipantRepository** | EventParticipant | `database/sql` + sqlc | Count → Redis (TTL 2min)       |

### 5.4 外部サービスアダプタ

> **ポリシー適用（2026-04-19）**: AWS SQS / SNS は使用しない。キューは `QueuePort` 経由で差し替える。
> 通知（メール・プッシュ）は別サービス（Notifications Svc）に責務を委譲し、本サービスは
> ドメインイベント発行のみを担う。

| アダプタ                 | ポート                 | 環境 | 実装                                     | エラーハンドリング                      |
| ------------------------ | ---------------------- | ---- | ---------------------------------------- | --------------------------------------- |
| **RedisBullMQAdapter**   | `QueuePort` / `EventPublisher` | Beta | `github.com/hibiken/asynq` / BullMQ（Redis） | リトライ 3回、DLQ へ送信          |
| **OCIQueueAdapter**      | `QueuePort` / `EventPublisher` | Prod | `github.com/oracle/oci-go-sdk/v65`      | リトライ 3回、DLQ + OCI Monitoring     |
| **AuthServiceClient**    | `AuthGateway`           | 両方 | gRPC                                    | タイムアウト 5sec、サーキットブレーカー |

> **削除済み**: `SQSEventEmitter`、`SNSNotificationAdapter` はポリシーにより使用しない。
> 通知は Notifications Svc が `FCMPushAdapter`（push）/ `PostfixSMTPAdapter`（mail）で処理する。

### 5.5 マッパー

```go
package adapter

// EventMapper DB行 ↔ ドメインエンティティ
type EventMapper struct{}

// ToEntity SQL 結果 → ドメイン Event
func (m *EventMapper) ToEntity(row *EventRow) (*domain.Event, error) {
    code, err := domain.NewEventCode(row.EventCode)
    if err != nil {
        return nil, err
    }
    return &domain.Event{
        ID:           row.ID,
        OrgID:        row.OrgID,
        Title:        row.Title,
        EventCode:    code,
        Description:  row.Description,
        StartDate:    row.StartDate,
        EndDate:      row.EndDate,
        Status:       domain.EventStatus(row.Status),
        CoverMediaID: row.CoverMediaID,
        CreatedBy:    row.CreatedBy,
        CreatedAt:    row.CreatedAt,
    }, nil
}

// ToPersistence ドメイン Event → DB 挿入用
func (m *EventMapper) ToPersistence(event *domain.Event) *EventRow {
    return &EventRow{
        ID:           event.ID,
        OrgID:        event.OrgID,
        Title:        event.Title,
        EventCode:    event.EventCode.String(),
        Description:  event.Description,
        StartDate:    event.StartDate,
        EndDate:      event.EndDate,
        Status:       string(event.Status),
        CoverMediaID: event.CoverMediaID,
        CreatedBy:    event.CreatedBy,
        CreatedAt:    event.CreatedAt,
    }
}
```

---

## 6. フレームワーク＆ドライバ層（インフラストラクチャ）

### 6.1 Webフレームワーク
- **フレームワーク**: Gin v1.10
- **ポート**: 8001
- **ベースパス**: `/api`
- **ミドルウェア**: CORS, Request ID, Auth Token検証, ロギング, Panic Recovery

### 6.2 データベース (MySQL 15)

```sql
-- events テーブル
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL,
    title TEXT NOT NULL,
    event_code TEXT NOT NULL,
    description TEXT,
    start_date TIMESTAMP WITH TIME ZONE NOT NULL,
    end_date TIMESTAMP WITH TIME ZONE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'ACTIVE', 'ARCHIVED')),
    cover_media_id TEXT,
    created_by TEXT NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT events_org_code_unique UNIQUE (org_id, event_code),
    CONSTRAINT events_start_before_end CHECK (start_date < end_date),
    FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL,
    FOREIGN KEY (cover_media_id) REFERENCES media_files(id) ON DELETE SET NULL
);

CREATE INDEX idx_events_org_id ON events(org_id);
CREATE INDEX idx_events_status ON events(status);
CREATE INDEX idx_events_created_at ON events(created_at DESC);

-- event_invitations テーブル
CREATE TABLE IF NOT EXISTS event_invitations (
    id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL,
    org_id TEXT NOT NULL,
    email TEXT NOT NULL,
    invited_by TEXT NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'MEMBER' CHECK (role IN ('OWNER', 'ADMIN', 'MEMBER', 'GUEST')),
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'ACCEPTED', 'DECLINED', 'EXPIRED')),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT event_invitations_event_email_unique UNIQUE (event_id, email),
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE,
    FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE,
    FOREIGN KEY (invited_by) REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX idx_event_invitations_event_id ON event_invitations(event_id);
CREATE INDEX idx_event_invitations_email_status ON event_invitations(email, status);
CREATE INDEX idx_event_invitations_expires_at ON event_invitations(expires_at);

-- event_participants テーブル
CREATE TABLE IF NOT EXISTS event_participants (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,           -- BIGSERIAL の MySQL/MariaDB 互換
    event_id CHAR(36) NOT NULL,
    user_id CHAR(36) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'MEMBER' CHECK (role IN ('OWNER', 'ADMIN', 'MEMBER', 'GUEST')),
    joined_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT event_participants_event_user_unique UNIQUE (event_id, user_id),
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX idx_event_participants_event_id ON event_participants(event_id);
CREATE INDEX idx_event_participants_user_id ON event_participants(user_id);
CREATE INDEX idx_event_participants_joined_at ON event_participants(joined_at DESC);
```

### 6.3 メッセージブローカー

**ポリシー確定（2026-04-19）**: AWS SQS / SNS は使用しない。Beta / Prod で `QueuePort` アダプタを差し替える。

| 環境 | アダプタ                | 実装                              | キュー識別子                                  |
| ---- | ----------------------- | --------------------------------- | --------------------------------------------- |
| Beta | `RedisBullMQAdapter`    | Redis + asynq / BullMQ            | `recuerdo-events` (Redis Stream / asynq queue) |
| Prod | `OCIQueueAdapter`       | OCI Queue Service                 | OCID: `ocid1.queue.oc1..<tenancy>.<id>`       |

- **メッセージ仕様**:
  - Type: JSON（全環境共通）
  - TTL: 4日
  - Dead Letter Queue: `recuerdo-events-dlq`（max receive count: 3）
- **消費者**: Album Service, Timeline Service, Notifications Service

### 6.4 外部ライブラリ＆SDK

| ライブラリ                     | 用途                | バージョン |
| ------------------------------ | ------------------- | ---------- |
| `github.com/gin-gonic/gin`     | Web フレームワーク  | v1.10      |
| `github.com/go-sql-driver/mysql` | MySQL/MariaDB 互換ドライバ | v1.8+ |
| `github.com/redis/go-redis/v9` | Redis クライアント  | v9.3       |
| `github.com/google/uuid`       | ULID 生成           | v1.5       |
| `github.com/oklog/ulid/v2`     | ULID 生成（改善版） | v2.1       |
| `google.golang.org/grpc`       | gRPC クライアント   | v1.57      |
| `golang.org/x/exp`             | Slices パッケージ   | latest     |

### 6.5 依存性注入 (uber-go/fx code example)

```go
package infra

import (
    "go.uber.org/fx"
    "github.com/gin-gonic/gin"
    _ "github.com/go-sql-driver/mysql"
    "database/sql"
)

// Module Events Service 全体の fx Module
func Module() fx.Option {
    return fx.Module("events-service",
        // インフラストラクチャプロバイダ
        fx.Provide(
            provideMySQLDB,                // MySQL 8.x / MariaDB 互換
            provideRedisClient,
            provideQueueAdapter,           // Beta: RedisBullMQAdapter / Prod: OCIQueueAdapter
            provideGinEngine,
        ),
        // リポジトリプロバイダ（アダプタ）
        fx.Provide(
            func(db *sql.DB) adapter.EventRepository {
                return adapter.NewMySQLEventRepository(db)
            },
            func(db *sql.DB) adapter.EventInvitationRepository {
                return adapter.NewMySQLEventInvitationRepository(db)
            },
            func(db *sql.DB) adapter.EventParticipantRepository {
                return adapter.NewMySQLEventParticipantRepository(db)
            },
        ),
        // 外部サービスアダプタ（QueuePort → EventPublisher）
        fx.Provide(
            func(q application.QueuePort) application.EventPublisher {
                return adapter.NewQueueEventPublisher(q)
            },
        ),
        // ユースケース（アプリケーション層）
        fx.Provide(
            func(
                eventRepo adapter.EventRepository,
                publisher application.EventPublisher,
                permSvc application.PermissionService,
            ) application.CreateEventUseCase {
                return application.NewCreateEventUseCase(eventRepo, publisher, permSvc)
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
        Addr:     cfg.Address,
        Password: cfg.Password,
    })
}

// provideQueueAdapter: ポリシーに従い Beta/Prod でアダプタを差し替える。
// AWS SQS / SNS は使用しない。
func provideQueueAdapter(cfg *config.QueueConfig, redis *redis.Client) application.QueuePort {
    switch cfg.Provider {
    case "redis-bullmq":
        return adapter.NewRedisBullMQAdapter(redis)
    case "oci-queue":
        return adapter.NewOCIQueueAdapter(cfg.OCIQueueOCID, cfg.OCIRegion)
    default:
        panic("unsupported queue.provider: " + cfg.Provider)
    }
}

func provideGinEngine() *gin.Engine {
    engine := gin.New()
    engine.Use(gin.Recovery())
    return engine
}

func registerHandlers(
    engine *gin.Engine,
    createEventUC application.CreateEventUseCase,
    // 他のユースケース...
) {
    api := engine.Group("/api")
    {
        events := api.Group("/events")
        {
            events.POST("", func(c *gin.Context) {
                handler := adapter.NewCreateEventHandler(createEventUC)
                handler.Handle(c)
            })
            // 他のハンドラ登録...
        }
    }
}
```

---

## 7. ディレクトリ構成

```
recuerdo-events-svc/
├── cmd/
│   └── main.go                 # アプリケーション起動エントリポイント
├── internal/
│   ├── domain/
│   │   ├── event.go            # Event エンティティ、ドメインロジック
│   │   ├── invitation.go        # EventInvitation エンティティ
│   │   ├── participant.go       # EventParticipant エンティティ
│   │   ├── value_objects.go    # EventStatus, EventCode, EventRole
│   │   └── events.go            # ドメインイベント定義
│   ├── application/
│   │   ├── dto.go              # リクエスト/レスポンス DTO
│   │   ├── ports.go            # インターフェース（リポジトリ、外部サービス）
│   │   ├── create_event.go      # CreateEventUseCase
│   │   ├── update_event.go      # UpdateEventUseCase
│   │   ├── archive_event.go     # ArchiveEventUseCase
│   │   ├── invite_member.go     # InviteMemberUseCase
│   │   ├── join_by_code.go      # JoinEventByCodeUseCase
│   │   ├── accept_invitation.go # AcceptInvitationUseCase
│   │   └── list_org_events.go   # ListOrgEventsUseCase
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── create_event_handler.go
│   │   │   ├── update_event_handler.go
│   │   │   ├── invite_handler.go
│   │   │   ├── join_handler.go
│   │   │   └── list_handler.go
│   │   ├── persistence/
│   │   │   ├── MySQL_event_repo.go
│   │   │   ├── MySQL_invitation_repo.go
│   │   │   └── MySQL_participant_repo.go
│   │   ├── external/
│   │   │   ├── sqs_event_emitter.go
│   │   │   └── auth_service_client.go
│   │   ├── presenter.go         # レスポンスマッピング
│   │   └── mapper.go            # Entity ↔ DTO マッピング
│   └── infra/
│       ├── config.go            # 設定読み込み
│       ├── database.go          # DB 接続
│       ├── redis.go             # Redis クライアント
│       ├── redis_bullmq.go      # Beta: Redis + BullMQ/asynq クライアント
│       ├── oci_queue.go         # Prod: OCI Queue クライアント
│       ├── fx_module.go         # 依存性注入設定
│       └── migrations/
│           └── 001_create_events.sql
├── test/
│   ├── integration/
│   │   ├── create_event_test.go
│   │   ├── invite_member_test.go
│   │   └── join_by_code_test.go
│   └── unit/
│       ├── domain/
│       │   ├── event_test.go
│       │   └── invitation_test.go
│       └── application/
│           └── create_event_usecase_test.go
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
| **フレームワーク＆ドライバ層** | すべて下位       | Gin エンジン → Repository アダプタ → ポート |
| **インターフェースアダプタ層** | ユースケース以下 | Handler → UseCase → Domain                  |
| **ユースケース層**             | ドメイン層のみ   | CreateEventUseCase → domain.Event           |
| **ドメイン層**                 | なし             | ドメイン層は自己完結、外部に依存しない      |

### 8.2 境界の横断
- **ポート経由の横断**：ユースケース → リポジトリポート（実装はアダプタ層）
- **DTO を通じた境界**：HTTP リクエスト → DTO → ユースケース → ドメイン
- **イベント駆動の境界**：ドメインイベント → EventPublisher (QueuePort) → 他サービス（疎結合）

### 8.3 ルールの強制
- **コンパイル時**：Go の型チェック、package visibility (private/public)
- **実行時**：linter (golangci-lint) で import チェック
- **レビュー時**：コードレビュー時にインポート検証（forbidden imports リスト）

```go
// 許可されないインポートの例（linter で検出）
// adapter/handler.go から domain 内のリポジトリ型への直接インポートは禁止
import "events-svc/internal/adapter/persistence" // ✗ 禁止
import "events-svc/internal/application"         // ✓ 許可

// golangci-lint depguard 設定
// .golangci.yml
depguard:
  rules:
    main:
      deny:
        - pkg: "events-svc/internal/adapter/persistence"
          desc: "Do not import persistence adapters in domain layer"
```

---

## 9. テスト戦略

### 9.1 テストピラミッド

| テストタイプ               | 割合 | 対象                                | ツール                       |
| -------------------------- | ---- | ----------------------------------- | ---------------------------- |
| **ユニットテスト**         | 70%  | ドメイン、ユースケース（Mock 依存） | `testing` + `testify/assert` |
| **統合テスト**             | 20%  | Handler + UseCase + Repo（実 DB）   | `testcontainers-go` (MySQL)  |
| **エンドツーエンドテスト** | 10%  | 全フロー（外部サービス含む）        | `docker-compose`, API テスト |

### 9.2 テスト例 (Go test code)

```go
package domain_test

import (
    "testing"
    "time"
    "github.com/stretchr/testify/assert"
    "events-svc/internal/domain"
)

// ユニットテスト：ドメインエンティティ
func TestNewEvent_Success(t *testing.T) {
    // Arrange
    code, _ := domain.NewEventCode("PARTY-2026")
    startDate := time.Now().AddDate(0, 1, 0)
    endDate := startDate.AddDate(0, 0, 7)
    
    // Act
    event, err := domain.NewEvent(
        "org-123",
        "Summer Party",
        code,
        startDate,
        endDate,
        "user-456",
    )
    
    // Assert
    assert.NoError(t, err)
    assert.Equal(t, "org-123", event.OrgID)
    assert.Equal(t, domain.EventStatusDraft, event.Status)
    assert.Len(t, event.DomainEvents(), 1)
}

func TestNewEvent_InvalidDates(t *testing.T) {
    code, _ := domain.NewEventCode("PARTY-2026")
    startDate := time.Now().AddDate(0, 1, 0)
    endDate := startDate.AddDate(0, 0, -1) // end < start
    
    _, err := domain.NewEvent(
        "org-123",
        "Summer Party",
        code,
        startDate,
        endDate,
        "user-456",
    )
    
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "start_date must be before end_date")
}

func TestEventCode_InvalidFormat(t *testing.T) {
    _, err := domain.NewEventCode("invalid code!")
    assert.Error(t, err)
}

// 統合テスト：ユースケース + リポジトリ
package application_test

import (
    "context"
    "testing"
    "github.com/testcontainers/testcontainers-go"
    "github.com/stretchr/testify/assert"
    "events-svc/internal/application"
    "events-svc/internal/adapter"
)

func TestCreateEventUseCase_Integration(t *testing.T) {
    // Arrange: testcontainers で MySQL スピンアップ
    ctx := context.Background()
    req := testcontainers.GenericContainerRequest{
        ContainerRequest: testcontainers.ContainerRequest{
            Image:        "MySQL:15-alpine",
            ExposedPorts: []string{"5432/tcp"},
            Env: map[string]string{
                "MySQL_DB":       "test_events",
                "MySQL_PASSWORD": "testpass",
            },
            WaitingFor: wait.ForLog("database system is ready to accept connections"),
        },
        Started: true,
    }
    container, _ := testcontainers.GenericContainer(ctx, req)
    defer container.Terminate(ctx)
    
    // テーブル作成、リポジトリ初期化...
    db, _ := setupTestDB(container)
    eventRepo := adapter.NewMySQLEventRepository(db)
    emitter := &mockEventEmitter{}
    permSvc := &mockPermissionService{canManage: true}
    
    uc := application.NewCreateEventUseCase(eventRepo, emitter, permSvc)
    
    // Act
    resp, err := uc.Execute(ctx, &application.CreateEventRequest{
        OrgID:     "org-123",
        Title:     "Test Event",
        EventCode: "TEST-2026",
        StartDate: time.Now().AddDate(0, 1, 0),
        EndDate:   time.Now().AddDate(0, 1, 7),
        CreatedBy: "user-456",
    })
    
    // Assert
    assert.NoError(t, err)
    assert.NotEmpty(t, resp.EventID)
    assert.Equal(t, "DRAFT", resp.Status)
    
    // 発行されたイベント検証
    assert.Len(t, emitter.publishedEvents, 1)
}

// Mock 実装
type mockEventEmitter struct {
    publishedEvents []interface{}
}

func (m *mockEventEmitter) Publish(ctx context.Context, event interface{}) error {
    m.publishedEvents = append(m.publishedEvents, event)
    return nil
}

func (m *mockEventEmitter) PublishBatch(ctx context.Context, events []interface{}) error {
    m.publishedEvents = append(m.publishedEvents, events...)
    return nil
}

type mockPermissionService struct {
    canManage bool
}

func (m *mockPermissionService) CanManageEvent(ctx context.Context, userID, orgID string) (bool, error) {
    return m.canManage, nil
}

func (m *mockPermissionService) HasOrgMembership(ctx context.Context, userID, orgID string) (bool, error) {
    return true, nil
}
```

---

## 10. エラーハンドリング

### 10.1 ドメインエラー

```go
package domain

// ドメインレベルのエラー定義（値オブジェクト、エンティティのバリデーション）
var (
    ErrInvalidEventCode = errors.New("invalid event code format")
    ErrInvalidEmail     = errors.New("invalid email address")
    ErrInvalidDateRange = errors.New("start_date must be before end_date")
    ErrEmptyTitle       = errors.New("event title cannot be empty")
    ErrInvitationExpired = errors.New("invitation has expired")
)
```

### 10.2 アプリケーションエラー

```go
package application

// ユースケースレベルのエラー定義（リポジトリ、外部サービス）
var (
    ErrEventNotFound           = errors.New("event not found")
    ErrEventCodeAlreadyExists  = errors.New("event code already exists in organization")
    ErrUnauthorized            = errors.New("user not authorized to perform this action")
    ErrInvitationNotFound      = errors.New("invitation not found")
    ErrEventArchived           = errors.New("cannot modify archived event")
    ErrUserAlreadyParticipant  = errors.New("user is already a participant")
    ErrOrgMembershipRequired   = errors.New("user must be organization member")
)
```

### 10.3 エラー変換 (HTTP mapping table)

| ドメイン/アプリエラー       | HTTP ステータス          | レスポンスボディ                                      |
| --------------------------- | ------------------------ | ----------------------------------------------------- |
| `ErrInvalidEventCode`       | 400 Bad Request          | `{"error": "invalid_event_code", "message": "..."}`   |
| `ErrEventCodeAlreadyExists` | 409 Conflict             | `{"error": "event_code_duplicate", "message": "..."}` |
| `ErrEventNotFound`          | 404 Not Found            | `{"error": "not_found", "message": "..."}`            |
| `ErrUnauthorized`           | 403 Forbidden            | `{"error": "unauthorized", "message": "..."}`         |
| `ErrEventArchived`          | 422 Unprocessable Entity | `{"error": "archived_event", "message": "..."}`       |
| `ErrOrgMembershipRequired`  | 403 Forbidden            | `{"error": "not_member", "message": "..."}`           |

```go
package adapter

// HTTP エラーマッパー
func mapErrorToHTTP(err error) (statusCode int, errorBody ErrorResponse) {
    switch {
    case errors.Is(err, domain.ErrInvalidEventCode):
        return http.StatusBadRequest, ErrorResponse{Error: "invalid_event_code"}
    case errors.Is(err, application.ErrEventCodeAlreadyExists):
        return http.StatusConflict, ErrorResponse{Error: "event_code_duplicate"}
    case errors.Is(err, application.ErrEventNotFound):
        return http.StatusNotFound, ErrorResponse{Error: "not_found"}
    case errors.Is(err, application.ErrUnauthorized):
        return http.StatusForbidden, ErrorResponse{Error: "unauthorized"}
    case errors.Is(err, application.ErrEventArchived):
        return http.StatusUnprocessableEntity, ErrorResponse{Error: "archived_event"}
    default:
        return http.StatusInternalServerError, ErrorResponse{Error: "internal_error"}
    }
}

type ErrorResponse struct {
    Error   string `json:"error"`
    Message string `json:"message,omitempty"`
}
```

---

## 11. 横断的関心事

### 11.1 ロギング
- **ライブラリ**: `go.uber.org/zap`
- **レベル**: DEBUG, INFO, WARN, ERROR
- **ログ対象**: ユースケース実行前後、DB 操作、外部API 呼び出し、エラー
- **フォーマット**: JSON (ログアグリゲーション向け)
- **実装**: Middleware で自動化、ユースケースで重要イベント記録

### 11.2 認証・認可
- **認証**: JWT トークン（Authorization ヘッダ）
- **認可**: 権限チェックは Permission Service 経由
- **ポリシー**：OWNER/ADMIN がイベント管理、MEMBER/GUEST は読み取り・参加
- **実装**: HTTP Middleware で token 検証 → context に user_id 埋め込み → ユースケース内で権限検証

### 11.3 バリデーション
- **入力バリデーション**: Handler 層でリクエストボディ検証（構造体タグ + govalidator）
- **ドメインバリデーション**: 値オブジェクト構築時（EventCode.NewEventCode など）
- **ビジネスロジックバリデーション**: ユースケース層でリポジトリ照合（重複チェックなど）

### 11.4 キャッシング
- **キャッシュレイヤー**: Redis 7.x
- **キャッシュキー戦略**: `events:{orgID}:list`, `event:{eventID}`, `invitation:{invitationID}`
- **TTL**: リスト 5min、個別 10min、参加者数 2min
- **無効化**: イベント更新時に明示的キャッシュ削除、TTL 自動期限切れ

---

## 12. マイグレーション計画

### 12.1 現状
- モノリシック構造のイベント管理（仮想）
- イベントステータスは simple flag
- 招待管理が他サービスに散在

### 12.2 目標状態
- 独立した Events Service マイクロサービス
- 完全なイベントライフサイクル管理（DRAFT → ACTIVE → ARCHIVED）
- 招待管理の一元化
- イベント駆動アーキテクチャによる他サービスとの疎結合

### 12.3 マイグレーション手順

| フェーズ                      | 実施内容                                                 | 期間  | 依存関係  |
| ----------------------------- | -------------------------------------------------------- | ----- | --------- |
| **1. インフラ準備**           | MySQL(MariaDB互換) テーブル作成、Queue 作成（Beta: Redis, Prod: OCI Queue）、Redis namespace 設定 | 1週間 | なし      |
| **2. コア実装**               | ドメイン層、ユースケース層、リポジトリ実装               | 2週間 | フェーズ1 |
| **3. HTTP インターフェース**  | Handler、Presenter、レスポンスマッピング実装             | 1週間 | フェーズ2 |
| **4. 統合テスト**             | Integration、E2E テスト（testcontainers）                | 1週間 | フェーズ3 |
| **5. デプロイ**               | Kubernetes 環境へのデプロイ、ブルーグリーン切り替え      | 2日   | フェーズ4 |
| **6. データマイグレーション** | 既存システムからのデータ移行、同期検証                   | 1週間 | フェーズ5 |
| **7. 本番運用**               | モニタリング、ログ監視、インシデント対応準備             | 継続  | フェーズ6 |

---

## 13. 未決事項と決定事項

| 項目                         | 現在の決定                                       | 状態     | 備考                                             |
| ---------------------------- | ------------------------------------------------ | -------- | ------------------------------------------------ |
| **イベントコード生成戦略**   | 手動入力（ユーザー指定）                         | 決定済み | 自動生成ではなくユーザーが意味のあるコードを指定 |
| **招待の再送信機能**         | 未実装                                           | 保留中   | 有効期限内なら再送信可能にするか検討中           |
| **イベント削除機能**         | 物理削除なし（archive のみ）                     | 決定済み | 監査証跡保持のため soft delete パターン採用      |
| **複数組織でのイベント共有** | サポートなし（単一 org）                         | 決定済み | 今後の拡張機能として検討                         |
| **タイムゾーン対応**         | UTC で統一（クライアント側で変換）               | 決定済み | DB と API は UTC、UI は user locale              |
| **招待の権限レベル**         | MEMBER, GUEST のみ（自分より高い権限は付与不可） | 決定済み | セキュリティ最小権限の原則                       |

---

## 14. 参考資料

- **Clean Architecture**: Robert C. Martin "Clean Architecture: A Craftsman's Guide to Software Structure and Design"
- **Domain-Driven Design**: Eric Evans "Domain-Driven Design: Tackling Complexity in the Heart of Software"
- **Event Sourcing**: Martin Fowler blog articles on Event Sourcing and CQRS
- **Go Best Practices**: `https://golang.org/doc/effective_go`
- **MySQL Docs**: `https://www.MySQL.org/docs/15/`
- **OCI Queue Service**: `https://docs.oracle.com/iaas/Content/queue/home.htm`
- **asynq (Beta)**: `https://github.com/hibiken/asynq`
- **BullMQ (Beta)**: `https://docs.bullmq.io/`
- **Gin Framework**: `https://github.com/gin-gonic/gin`

---

最終更新: 2026-04-19 ポリシー適用
