# Events Module (recerdo-events)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

Recuerdoアプリケーションのイベント（パーティー・旅行・同窓会等の「思い出の瞬間」）管理を一元化するマイクロサービス。各組織（org）に紐づく複数のイベントを作成・更新・アーカイブし、イベントコード（e.g. "SUMMER-PARTY-2026"）による招待機能を提供する。イベントはアルバム・メディア・タイムラインの組織化単位として機能し、イベント作成時にはAlbum Serviceへ自動でアルバムを作成、メンバー招待時にはNotification Serviceへメール送信を依頼する。イベントのライフサイクル（DRAFT→ACTIVE→ARCHIVED）・招待ステータス（PENDING→ACCEPTED/DECLINED）・メンバー権限（OWNER/ADMIN/MEMBER/GUEST）を厳密に管理し、ドメインイベント（EventCreated・EventInvitationSent等）を QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）経由で下流サービスへ伝播する（[基本的方針](../core/policy.md) 参照）。

### ビジネスコンテキスト

解決する問題:
- Recuerdoでイベントを中心に思い出を整理したいが、イベント管理機能がなく、アルバムやメディアの整理が困難
- グループメンバーをイベントに招待する際、メールアドレス・招待ステータス・期限管理が一元化されていない
- 組織内で複数のイベントが存在する場合、イベント一覧・検索・フィルタリング機能が不足

Key User Stories:
- モバイルアプリユーザーとして、夏のパーティーを「イベント」として登録し、メンバーをメールで招待し、そのイベント用のアルバムを自動作成したい
- グループ管理者として、イベント一覧を表示し、招待状況を確認し、期限切れ招待を削除したい
- メンバーとして、招待されたイベントを確認し、「参加」「不参加」を返答したい
- イベント企画者として、イベントコード（e.g. "SUMMER-2026"）を生成し、メンバーがコードを入力してイベントに参加できるようにしたい
- アナリティクスチームとして、イベント作成数・招待受理率・参加メンバー数を集計したい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ     | 説明                                                                       | 主要属性                                                                                                                                                                       |
| ---------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Event            | イベント。組織内の思い出の瞬間を示す                                       | id (ULID), org_id, title, description?, start_date, end_date, status (DRAFT/ACTIVE/ARCHIVED), event_code (unique per org), cover_media_id?, created_by, created_at, updated_at |
| EventInvitation  | イベントへのメンバー招待。メールアドレスベース                             | id (ULID), event_id, org_id, email, invited_by, role (MEMBER/GUEST), status (PENDING/ACCEPTED/DECLINED/EXPIRED), invited_at, responded_at?, accepted_user_id?, expires_at      |
| EventCode        | イベント参加用コード。ユニークでメモ可能な形式（e.g. "SUMMER-PARTY-2026"） | code (slug format), event_id, org_id, is_active, created_at                                                                                                                    |
| EventParticipant | イベント参加実績。招待受理・コード参加ユーザーを統一的に管理               | id (ULID), event_id, org_id, user_id, email, role (OWNER/ADMIN/MEMBER/GUEST), joined_via (INVITATION/EVENT_CODE/DIRECT), joined_at, last_activity_at                           |

### 値オブジェクト

| 値オブジェクト   | 説明                                     | バリデーションルール                                                                                |
| ---------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------- |
| EventStatus      | イベントの状態遷移                       | DRAFT (下書き) → ACTIVE (公開) → ARCHIVED (終了・アーカイブ). 逆遷移不可                            |
| InvitationStatus | 招待の回答状態                           | PENDING (未返答) → ACCEPTED/DECLINED/EXPIRED. 一度返答されたら変更不可。期限切れ自動遷移あり        |
| EventCode        | イベント参加コード。人間が入力可能な形式 | 大文字英数字ハイフン。最大30文字。org内でユニーク。大文字のみ (e.g. "SUMMER-PARTY-2026")            |
| EventRole        | イベント内のメンバー権限                 | OWNER (作成者、全権), ADMIN (管理者、メンバー管理), MEMBER (一般メンバー), GUEST (ゲスト、読取のみ) |
| EventDateRange   | イベント期間の妥当性チェック             | start_date < end_date 必須。過去日付も許可（思い出イベント用）                                      |
| InvitationEmail  | 招待メールアドレス                       | RFC 5321準拠の妥当なメール形式                                                                      |

### ドメインルール / 不変条件

- event_codeはorg内でユニークでなければならない
- アーカイブ済みイベント（status=ARCHIVED）は読取のみ。更新・招待追加は禁止
- 招待メール有効期限は招待日時から30日。期限切れはExpiredに自動遷移
- メンバー・ゲストの招待はOWNER/ADMIN権限者のみ実行可能
- イベント作成時に title が必須。description・cover_media_idはオプション
- DRAFT状態のイベントはメンバーに非表示。ACTIVE化して初めて表示
- start_date は end_date より前でなければならない
- DRAFT→ACTIVE遷移時、最低限 title が必須（description等なくても可）
- イベント削除は禁止。アーカイブのみ
- EventCodeは1イベント1つだけ有効。複数発行不可
- 招待受理時、EventParticipantに参加者を追加。role・email記録必須
- コードで参加したユーザーも EventParticipant に記録。joined_via=EVENT_CODE
- 同一ユーザーが複数ロールで参加不可。最初の参加ロールで固定

### ドメインイベント

| イベント                | トリガー                                   | 主要ペイロード                                                                           |
| ----------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------- |
| EventCreated            | イベント作成完了時                         | event_id, org_id, title, created_by, status, start_date, end_date, created_at, timestamp |
| EventStatusChanged      | イベントステータス遷移時（DRAFT→ACTIVE等） | event_id, org_id, old_status, new_status, changed_by, changed_at, timestamp              |
| EventArchived           | イベントアーカイブ時（ACTIVE→ARCHIVED）    | event_id, org_id, archived_by, archived_at, participant_count, timestamp                 |
| EventInvitationSent     | メンバー招待実行時                         | event_id, org_id, invitation_id, email, invited_by, role, expires_at, timestamp          |
| EventInvitationAccepted | 招待受理時                                 | event_id, org_id, invitation_id, email, accepted_user_id, accepted_at, timestamp         |
| EventInvitationDeclined | 招待拒否時                                 | event_id, org_id, invitation_id, email, declined_at, timestamp                           |
| EventInvitationExpired  | 招待期限切れ時                             | event_id, org_id, invitation_id, email, expired_at, timestamp                            |
| EventCodeCreated        | イベント参加コード生成時                   | event_id, org_id, event_code, created_by, created_at, timestamp                          |
| UserJoinedEventByCode   | ユーザーがコードでイベント参加時           | event_id, org_id, user_id, email, event_code, joined_at, timestamp                       |

### エンティティ定義（コードスケッチ）

```go
// Event エンティティ
type Event struct {
    ID            string    // ULID
    OrgID         string    // UUID
    Title         string
    Description   *string
    StartDate     time.Time
    EndDate       time.Time
    Status        string    // DRAFT, ACTIVE, ARCHIVED
    EventCode     *string   // unique per org, e.g. "SUMMER-PARTY-2026"
    CoverMediaID  *string   // reference to media service
    CreatedBy     string    // user_id
    CreatedAt     time.Time
    UpdatedAt     time.Time
}

func (e *Event) Validate() error {
    if e.Title == "" {
        return ErrEventTitleRequired
    }
    if e.StartDate.After(e.EndDate) {
        return ErrInvalidDateRange
    }
    if e.Status != "DRAFT" && e.Status != "ACTIVE" && e.Status != "ARCHIVED" {
        return ErrInvalidEventStatus
    }
    return nil
}

func (e *Event) IsArchived() bool {
    return e.Status == "ARCHIVED"
}

func (e *Event) CanBeUpdated() bool {
    return e.Status != "ARCHIVED"
}

func (e *Event) CanInviteMembers() bool {
    return e.Status == "ACTIVE"
}

func (e *Event) TransitionToDraft() error {
    if e.Status != "DRAFT" {
        return ErrCannotTransitionToDraft
    }
    return nil
}

func (e *Event) TransitionToActive() error {
    if e.Status != "DRAFT" {
        return ErrCannotTransitionToActive
    }
    if e.Title == "" {
        return ErrEventTitleRequired
    }
    e.Status = "ACTIVE"
    return nil
}

func (e *Event) TransitionToArchived() error {
    if e.Status == "ARCHIVED" {
        return ErrAlreadyArchived
    }
    e.Status = "ARCHIVED"
    return nil
}

// EventInvitation エンティティ
type EventInvitation struct {
    ID            string     // ULID
    EventID       string
    OrgID         string
    Email         string
    InvitedBy     string     // user_id
    Role          string     // MEMBER, GUEST
    Status        string     // PENDING, ACCEPTED, DECLINED, EXPIRED
    InvitedAt     time.Time
    RespondedAt   *time.Time
    AcceptedUserID *string   // user_id of who accepted
    ExpiresAt     time.Time
}

func (i *EventInvitation) IsExpired(now time.Time) bool {
    return now.After(i.ExpiresAt)
}

func (i *EventInvitation) CanRespond(now time.Time) bool {
    return i.Status == "PENDING" && !i.IsExpired(now)
}

func (i *EventInvitation) Accept(userID string, now time.Time) error {
    if !i.CanRespond(now) {
        return ErrCannotRespondToInvitation
    }
    i.Status = "ACCEPTED"
    i.RespondedAt = &now
    i.AcceptedUserID = &userID
    return nil
}

func (i *EventInvitation) Decline(now time.Time) error {
    if !i.CanRespond(now) {
        return ErrCannotRespondToInvitation
    }
    i.Status = "DECLINED"
    i.RespondedAt = &now
    return nil
}

func (i *EventInvitation) ExpireIfNeeded(now time.Time) {
    if i.IsExpired(now) && i.Status == "PENDING" {
        i.Status = "EXPIRED"
    }
}

// EventCode 値オブジェクト
type EventCode string

func NewEventCode(code string) (EventCode, error) {
    if len(code) == 0 || len(code) > 30 {
        return "", ErrInvalidEventCodeLength
    }
    // Must be alphanumeric + hyphens, uppercase only
    if !regexp.MustCompile(`^[A-Z0-9\-]+$`).MatchString(code) {
        return "", ErrInvalidEventCodeFormat
    }
    return EventCode(code), nil
}

func (ec EventCode) String() string {
    return string(ec)
}

// EventParticipant エンティティ
type EventParticipant struct {
    ID         string    // ULID
    EventID    string
    OrgID      string
    UserID     string    // user_id
    Email      string
    Role       string    // OWNER, ADMIN, MEMBER, GUEST
    JoinedVia  string    // INVITATION, EVENT_CODE, DIRECT
    JoinedAt   time.Time
    LastActivityAt time.Time
}

func (ep *EventParticipant) CanManageEvent() bool {
    return ep.Role == "OWNER" || ep.Role == "ADMIN"
}

func (ep *EventParticipant) CanInvite() bool {
    return ep.Role == "OWNER" || ep.Role == "ADMIN"
}

func (ep *EventParticipant) HasEditAccess() bool {
    return ep.Role == "OWNER" || ep.Role == "ADMIN" || ep.Role == "MEMBER"
}

// EventRole 値オブジェクト
type EventRole string

const (
    RoleOwner   EventRole = "OWNER"
    RoleAdmin   EventRole = "ADMIN"
    RoleMember  EventRole = "MEMBER"
    RoleGuest   EventRole = "GUEST"
)

func (r EventRole) CanInvite() bool {
    return r == RoleOwner || r == RoleAdmin
}

func (r EventRole) CanEdit() bool {
    return r == RoleOwner || r == RoleAdmin || r == RoleMember
}
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース          | 入力DTO                                                                                           | 出力DTO                                                       | 説明                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------ |
| CreateEvent           | CreateEventInput{org_id, title, start_date, end_date, description?, cover_media_id?}              | CreateEventOutput{event_id, event_code, status}               | 新規イベント作成。DRAFTステータスで開始。EventCodeは自動生成 |
| UpdateEvent           | UpdateEventInput{event_id, org_id, title?, start_date?, end_date?, description?, cover_media_id?} | UpdateEventOutput{event, updated_fields}                      | イベント情報更新。ARCHIVEDイベントは更新不可                 |
| ActivateEvent         | ActivateEventInput{event_id, org_id}                                                              | ActivateEventOutput{event, activated_at}                      | DRAFTイベントをACTIVEに遷移。titleが必須                     |
| ArchiveEvent          | ArchiveEventInput{event_id, org_id}                                                               | ArchiveEventOutput{event, archived_at, participant_count}     | イベントをアーカイブ（ARCHIVED）。読取専用に遷移             |
| GetEvent              | GetEventInput{event_id, org_id}                                                                   | GetEventOutput{event, participant_count, invitation_count}    | イベント詳細を取得                                           |
| ListEventsByOrg       | ListEventsByOrgInput{org_id, status?, limit, offset}                                              | ListEventsByOrgOutput{events[], total_count, has_more}        | 組織内のイベント一覧を取得。ステータスフィルタ可能           |
| InviteMemberByEmail   | InviteMemberByEmailInput{event_id, org_id, email, role, invited_by}                               | InviteMemberByEmailOutput{invitation_id, expires_at}          | メンバーをメールアドレスで招待。Notification Serviceへ委譲   |
| RespondToInvitation   | RespondToInvitationInput{invitation_id, org_id, response (ACCEPT/DECLINE), user_id?, email}       | RespondToInvitationOutput{invitation, user_id, event_id}      | 招待に返答。ACCEPT時はEventParticipantに追加                 |
| JoinEventByCode       | JoinEventByCodeInput{event_code, org_id, user_id, email}                                          | JoinEventByCodeOutput{event, participant_id, role}            | イベントコードを使用してイベントに参加                       |
| ListEventInvitations  | ListEventInvitationsInput{event_id, org_id, status?, limit, offset}                               | ListEventInvitationsOutput{invitations[], total_count}        | イベントへの招待一覧を取得                                   |
| ListEventParticipants | ListEventParticipantsInput{event_id, org_id, limit, offset}                                       | ListEventParticipantsOutput{participants[], total_count}      | イベント参加メンバー一覧を取得                               |
| GetEventCode          | GetEventCodeInput{event_id, org_id}                                                               | GetEventCodeOutput{event_code, is_active}                     | イベント参加コードを取得                                     |
| RegenerateEventCode   | RegenerateEventCodeInput{event_id, org_id, regenerated_by}                                        | RegenerateEventCodeOutput{new_code, old_code, regenerated_at} | 参加コードを再生成（セキュリティ目的）                       |
| RemoveParticipant     | RemoveParticipantInput{event_id, org_id, participant_id, removed_by}                              | RemoveParticipantOutput{participant, removed_at}              | メンバーをイベントから削除                                   |
| GetUserEvents         | GetUserEventsInput{user_id, org_id, status?}                                                      | GetUserEventsOutput{events[], total_count}                    | ユーザーが参加しているイベント一覧を取得                     |
| ExpireOldInvitations  | ExpireOldInvitationsInput{batch_size}                                                             | ExpireOldInvitationsOutput{expired_count, timestamp}          | 期限切れ招待をバッチで自動遷移（スケジュール実行）           |

### ユースケース詳細（主要ユースケース）

## CreateEvent — 主要ユースケース詳細

### トリガー
モバイルアプリ/Web アプリからの POST /api/orgs/{org_id}/events リクエスト

### フロー
1. 権限チェック: PermissionPort.CanCreateEvent(org_id, user_id)
   - 権限なし → ErrUnauthorized (403)
2. リクエストバリデーション
   - title は 1～200文字 → ErrInvalidEventTitle
   - start_date < end_date → ErrInvalidDateRange
3. Event エンティティ作成
   - status = DRAFT
   - created_by = user_id
   - created_at = now
4. イベント保存: EventRepository.Create(event)
5. EventCode自動生成 (一意のコード生成ロジック)
   a. EventCodeGeneratorPort.Generate(org_id, title) → e.g. "SUMMER-PARTY-2026"
   b. 重複チェック: EventCodeRepository.Exists(org_id, code) で再試行
   c. EventCodeRepository.Create(code, event_id, org_id)
6. EventParticipant作成 (作成者をOWNER権限で追加)
   - role = OWNER
   - joined_via = DIRECT
   - user_id = created_by
7. QueuePort.Publish(EventCreated)
   - payload: {event_id, org_id, title, created_by, status, created_at}
   - 下流: Album Service (アルバム自動作成), Timeline Service
8. レスポンス:
   ```json
   {
     "event_id": "ulid",
     "org_id": "uuid",
     "title": "Summer Party 2026",
     "status": "DRAFT",
     "event_code": "SUMMER-PARTY-2026",
     "start_date": "2026-07-15T00:00:00Z",
     "end_date": "2026-07-16T00:00:00Z",
     "created_at": "2026-04-13T10:00:00Z"
   }
   ```

### 注意事項
- イベント作成時、アルバムは自動作成されない（ACTIVE時に作成）
- EventCodeは英数字・ハイフン、大文字のみ
- DRAFTイベントはメンバーには非表示（リスト取得時にフィルタ）
- event_code は org内でユニークであることを保証

## InviteMemberByEmail — 詳細

### トリガー
POST /api/orgs/{org_id}/events/{event_id}/invitations リクエスト

### フロー
1. 権限チェック: PermissionPort.CanInviteToEvent(org_id, event_id, user_id)
   - OWNER/ADMIN のみ → ErrUnauthorized (403)
2. イベント確認: EventRepository.Get(event_id)
   - なし → ErrEventNotFound (404)
   - ARCHIVEDステータス → ErrCannotInviteToArchivedEvent (400)
3. メールバリデーション
   - RFC 5321準拠 → ErrInvalidEmail (400)
4. 重複招待チェック: EventInvitationRepository.GetByEmailAndEvent(event_id, email)
   - 既に PENDING 招待あり → ErrAlreadyInvited (409)
5. EventInvitation エンティティ作成
   - status = PENDING
   - invited_by = user_id
   - invited_at = now
   - expires_at = now + 30days
6. EventInvitationRepository.Create(invitation)
7. QueuePort.Publish(EventInvitationSent)
   - payload: {event_id, org_id, invitation_id, email, invited_by, expires_at}
   - 下流: Notification Service (メール送信)
8. レスポンス:
   ```json
   {
     "invitation_id": "ulid",
     "email": "user@example.com",
     "status": "PENDING",
     "expires_at": "2026-05-13T10:00:00Z"
   }
   ```

### 注意事項
- メール送信は Notification Service への委譲（Events Serviceは確認なし）
- 招待有効期限は30日固定
- 同一メールアドレスへの複数招待（ステータス別）は許可（PENDINGのみ重複禁止）

## JoinEventByCode — イベントコード参加詳細

### トリガー
POST /api/events/join/{event_code} リクエスト (認証済みユーザー)

### フロー
1. EventCodeRepository.GetByCode(event_code, org_id) → event_id
   - なし → ErrInvalidEventCode (404)
2. EventRepository.Get(event_id)
   - ステータスが ACTIVE でない → ErrEventNotAccessible (400)
3. 既参加チェック: EventParticipantRepository.GetByEventAndUser(event_id, user_id)
   - 既に参加 → ErrAlreadyParticipant (409)
4. EventParticipant作成
   - role = MEMBER (GUEST選択肢もあるが、デフォルトMEMBER)
   - joined_via = EVENT_CODE
   - user_id, email 記録
   - joined_at = now
5. EventParticipantRepository.Create(participant)
6. QueuePort.Publish(UserJoinedEventByCode)
   - payload: {event_id, org_id, user_id, email, event_code, joined_at}
   - 下流: Notification Service (参加通知)
7. レスポンス:
   ```json
   {
     "event_id": "ulid",
     "participant_id": "ulid",
     "role": "MEMBER",
     "joined_at": "2026-04-13T10:00:00Z"
   }
   ```

### 注意事項
- コード参加でのロールはMEMBER固定（招待受理とは異なる）
- 既参加ユーザーは参加不可（冪等性なし）
- イベントコードは複数回使用可（複数ユーザーが参加可）

### リポジトリ・サービスポート（インターフェース）

```go
// Repository Ports
type EventRepository interface {
    Create(ctx context.Context, event *Event) error
    GetByID(ctx context.Context, eventID string) (*Event, error)
    UpdateByID(ctx context.Context, eventID string, event *Event) error
    ListByOrgID(ctx context.Context, orgID string, status *string, limit, offset int) ([]*Event, int64, error)
    DeleteByID(ctx context.Context, eventID string) error // Actually archive
}

type EventInvitationRepository interface {
    Create(ctx context.Context, invitation *EventInvitation) error
    GetByID(ctx context.Context, invitationID string) (*EventInvitation, error)
    GetByEmailAndEvent(ctx context.Context, email, eventID string) (*EventInvitation, error)
    UpdateByID(ctx context.Context, invitationID string, invitation *EventInvitation) error
    ListByEventID(ctx context.Context, eventID string, status *string, limit, offset int) ([]*EventInvitation, int64, error)
    ListExpiredPending(ctx context.Context, beforeTime time.Time, limit int) ([]*EventInvitation, error)
    UpdateStatusByID(ctx context.Context, invitationID string, newStatus string) error
}

type EventCodeRepository interface {
    Create(ctx context.Context, code, eventID, orgID string) error
    GetByEventID(ctx context.Context, eventID string) (*EventCode, error)
    GetByCode(ctx context.Context, code, orgID string) (*EventCode, error)
    UpdateByEventID(ctx context.Context, eventID string, newCode string) error
    ExistsByCode(ctx context.Context, code, orgID string) (bool, error)
}

type EventParticipantRepository interface {
    Create(ctx context.Context, participant *EventParticipant) error
    GetByID(ctx context.Context, participantID string) (*EventParticipant, error)
    GetByEventAndUser(ctx context.Context, eventID, userID string) (*EventParticipant, error)
    UpdateByID(ctx context.Context, participantID string, participant *EventParticipant) error
    ListByEventID(ctx context.Context, eventID string, limit, offset int) ([]*EventParticipant, int64, error)
    ListByUserID(ctx context.Context, userID string, limit, offset int) ([]*EventParticipant, int64, error)
    DeleteByID(ctx context.Context, participantID string) error
}

// Service Ports
type PermissionPort interface {
    CanCreateEvent(ctx context.Context, orgID, userID string) (bool, error)
    CanEditEvent(ctx context.Context, orgID, eventID, userID string) (bool, error)
    CanInviteToEvent(ctx context.Context, orgID, eventID, userID string) (bool, error)
    CanArchiveEvent(ctx context.Context, orgID, eventID, userID string) (bool, error)
    IsOrgMember(ctx context.Context, orgID, userID string) (bool, error)
}

type EventCodeGeneratorPort interface {
    Generate(ctx context.Context, orgID, eventTitle string) (string, error)
}

type NotificationPort interface {
    SendInvitationEmail(ctx context.Context, email, eventTitle string, invitationID string) error
    SendParticipationNotification(ctx context.Context, userID string, eventID string) error
}

type AuthServicePort interface {
    GetUserByEmail(ctx context.Context, email string) (*AuthUser, error)
}

type EventPublisherPort interface {
    PublishEventCreated(ctx context.Context, event *Event, createdBy string) error
    PublishEventStatusChanged(ctx context.Context, eventID string, oldStatus, newStatus string, changedBy string) error
    PublishEventArchived(ctx context.Context, event *Event, archivedBy string) error
    PublishEventInvitationSent(ctx context.Context, invitation *EventInvitation) error
    PublishEventInvitationAccepted(ctx context.Context, invitation *EventInvitation) error
    PublishEventInvitationDeclined(ctx context.Context, invitation *EventInvitation) error
    PublishUserJoinedByCode(ctx context.Context, eventID, orgID, userID, email, code string) error
}
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ           | ルート/トリガー                                                           | ユースケース                 |
| ---------------------- | ------------------------------------------------------------------------- | ---------------------------- |
| EventHTTPHandler       | POST /api/orgs/{org_id}/events                                            | CreateEventUseCase           |
| EventHTTPHandler       | GET /api/orgs/{org_id}/events                                             | ListEventsByOrgUseCase       |
| EventHTTPHandler       | GET /api/orgs/{org_id}/events/{event_id}                                  | GetEventUseCase              |
| EventHTTPHandler       | PUT /api/orgs/{org_id}/events/{event_id}                                  | UpdateEventUseCase           |
| EventHTTPHandler       | POST /api/orgs/{org_id}/events/{event_id}/activate                        | ActivateEventUseCase         |
| EventHTTPHandler       | POST /api/orgs/{org_id}/events/{event_id}/archive                         | ArchiveEventUseCase          |
| InvitationHTTPHandler  | POST /api/orgs/{org_id}/events/{event_id}/invitations                     | InviteMemberByEmailUseCase   |
| InvitationHTTPHandler  | GET /api/orgs/{org_id}/events/{event_id}/invitations                      | ListEventInvitationsUseCase  |
| InvitationHTTPHandler  | POST /api/invitations/{invitation_id}/respond                             | RespondToInvitationUseCase   |
| ParticipantHTTPHandler | GET /api/orgs/{org_id}/events/{event_id}/participants                     | ListEventParticipantsUseCase |
| ParticipantHTTPHandler | DELETE /api/orgs/{org_id}/events/{event_id}/participants/{participant_id} | RemoveParticipantUseCase     |
| EventCodeHTTPHandler   | GET /api/orgs/{org_id}/events/{event_id}/code                             | GetEventCodeUseCase          |
| EventCodeHTTPHandler   | POST /api/orgs/{org_id}/events/{event_id}/regenerate-code                 | RegenerateEventCodeUseCase   |
| JoinHTTPHandler        | POST /api/events/join/{event_code}                                        | JoinEventByCodeUseCase       |
| UserEventsHTTPHandler  | GET /api/users/{user_id}/events                                           | GetUserEventsUseCase         |
| ScheduledTaskHandler   | Cron job (daily 00:00 UTC)                                                | ExpireOldInvitationsUseCase  |

### リポジトリ実装

| ポートインターフェース     | 実装クラス                      | データストア                         |
| -------------------------- | ------------------------------- | ------------------------------------ |
| EventRepository            | MySQLEventRepository            | MySQL 8.0 / MariaDB 10.11 (events table)             |
| EventInvitationRepository  | MySQLEventInvitationRepository  | MySQL 8.0 / MariaDB 10.11 (event_invitations table)  |
| EventCodeRepository        | MySQLEventCodeRepository        | MySQL 8.0 / MariaDB 10.11 (event_codes table)        |
| EventParticipantRepository | MySQLEventParticipantRepository | MySQL 8.0 / MariaDB 10.11 (event_participants table) |

### 外部サービスアダプタ

| ポートインターフェース | アダプタクラス                | 外部システム                                 |
| ---------------------- | ----------------------------- | -------------------------------------------- |
| PermissionPort         | PermissionServiceGRPCAdapter  | recerdo-permission (gRPC)               |
| EventCodeGeneratorPort | UUIDSlugCodeGenerator         | 内部実装（タイトル + ランダム部で生成）      |
| NotificationPort       | NotificationServiceQueueAdapter | QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue）→ recerdo-notifications |
| AuthServicePort        | AuthServiceGRPCAdapter        | recerdo-auth (gRPC)                     |
| EventPublisherPort     | QueueEventPublisher           | QueuePort トピック `recuerdo.events.*`（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service） |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + net/http (HTTPサーバー) + gorilla/mux (ルーティング)

### データベース

MySQL 8.0 / MariaDB 10.11

**テーブル定義:**

```sql
-- Events テーブル
CREATE TABLE events (
    id CHAR(26) PRIMARY KEY,        -- ULID
    org_id UUID NOT NULL,
    title VARCHAR(200) NOT NULL,
    description TEXT,
    start_date TIMESTAMP NOT NULL,
    end_date TIMESTAMP NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('DRAFT', 'ACTIVE', 'ARCHIVED')),
    cover_media_id VARCHAR(255),
    created_by UUID NOT NULL,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    deleted_at TIMESTAMP,
    CONSTRAINT fk_org_id FOREIGN KEY (org_id) REFERENCES organizations(id),
    CONSTRAINT start_before_end CHECK (start_date < end_date)
);

CREATE INDEX idx_events_org_id_status ON events(org_id, status);
CREATE INDEX idx_events_org_id_created_at ON events(org_id, created_at DESC);

-- Event Invitations テーブル
CREATE TABLE event_invitations (
    id CHAR(26) PRIMARY KEY,        -- ULID
    event_id CHAR(26) NOT NULL,
    org_id UUID NOT NULL,
    email VARCHAR(255) NOT NULL,
    invited_by UUID NOT NULL,
    role VARCHAR(20) NOT NULL CHECK (role IN ('MEMBER', 'GUEST')),
    status VARCHAR(20) NOT NULL CHECK (status IN ('PENDING', 'ACCEPTED', 'DECLINED', 'EXPIRED')),
    invited_at TIMESTAMP NOT NULL,
    responded_at TIMESTAMP,
    accepted_user_id UUID,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    CONSTRAINT fk_event_id FOREIGN KEY (event_id) REFERENCES events(id),
    CONSTRAINT fk_org_id FOREIGN KEY (org_id) REFERENCES organizations(id)
);

CREATE INDEX idx_invitations_event_id_status ON event_invitations(event_id, status);
CREATE INDEX idx_invitations_email_event ON event_invitations(email, event_id);
CREATE INDEX idx_invitations_expires_at ON event_invitations(expires_at) WHERE status = 'PENDING';
CREATE INDEX idx_invitations_accepted_user ON event_invitations(accepted_user_id) WHERE accepted_user_id IS NOT NULL;

-- Event Codes テーブル
CREATE TABLE event_codes (
    code VARCHAR(30) NOT NULL,
    event_id CHAR(26) NOT NULL,
    org_id UUID NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    PRIMARY KEY (org_id, code),
    CONSTRAINT fk_event_id FOREIGN KEY (event_id) REFERENCES events(id),
    CONSTRAINT fk_org_id FOREIGN KEY (org_id) REFERENCES organizations(id),
    CONSTRAINT unique_code_per_org UNIQUE (org_id, code)
);

CREATE INDEX idx_event_codes_event_id ON event_codes(event_id);

-- Event Participants テーブル
CREATE TABLE event_participants (
    id CHAR(26) PRIMARY KEY,        -- ULID
    event_id CHAR(26) NOT NULL,
    org_id UUID NOT NULL,
    user_id UUID NOT NULL,
    email VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL CHECK (role IN ('OWNER', 'ADMIN', 'MEMBER', 'GUEST')),
    joined_via VARCHAR(20) NOT NULL CHECK (joined_via IN ('INVITATION', 'EVENT_CODE', 'DIRECT')),
    joined_at TIMESTAMP NOT NULL,
    last_activity_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    CONSTRAINT fk_event_id FOREIGN KEY (event_id) REFERENCES events(id),
    CONSTRAINT fk_org_id FOREIGN KEY (org_id) REFERENCES organizations(id),
    CONSTRAINT unique_participant UNIQUE (event_id, user_id)
);

CREATE INDEX idx_participants_event_id ON event_participants(event_id);
CREATE INDEX idx_participants_user_id ON event_participants(user_id);
CREATE INDEX idx_participants_event_user ON event_participants(event_id, user_id);
CREATE INDEX idx_participants_org_user ON event_participants(org_id, user_id);
```

### 主要ライブラリ・SDK

| ライブラリ                          | 目的                                          | レイヤー                |
| ----------------------------------- | --------------------------------------------- | ----------------------- |
| github.com/go-sql-driver/mysql      | MySQL 8.0 / MariaDB 10.11 ドライバ            | Infrastructure          |
| github.com/jmoiron/sqlc             | SQL→Go型安全コード生成                        | Infrastructure          |
| oklog/ulid                          | ULID生成・パース                              | Domain / Infrastructure |
| github.com/google/uuid              | UUID生成                                      | Infrastructure          |
| google.golang.org/grpc              | gRPC クライアント（Permission・Auth Service） | Infrastructure          |
| hibiken/asynq                       | QueuePort Beta 実装（asynq）                  | Infrastructure          |
| taskforcesh/bullmq (Node ワーカー)  | QueuePort Beta 実装（Redis+BullMQ）           | Infrastructure          |
| oracle/oci-go-sdk                   | QueuePort 本番実装（OCI Queue Service）       | Infrastructure          |
| github.com/gorilla/mux              | HTTP ルーティング                             | Adapter                 |
| uber-go/fx                          | 依存性注入                                    | Infrastructure          |
| uber-go/zap                         | 構造化ログ                                    | Infrastructure          |
| go.opentelemetry.io/otel            | 分散トレーシング                              | Infrastructure          |
| github.com/prometheus/client_golang | メトリクス収集                                | Infrastructure          |

### 依存性注入

uber-go/fx を使用。全ポートをインターフェースとして登録。

```go
fx.Provide(
    // Repositories
    NewMySQLEventRepository,           // → EventRepository
    NewMySQLEventInvitationRepository, // → EventInvitationRepository
    NewMySQLEventCodeRepository,       // → EventCodeRepository
    NewMySQLEventParticipantRepository,// → EventParticipantRepository
    
    // Service Adapters
    NewPermissionServiceGRPCAdapter,  // → PermissionPort
    NewAuthServiceGRPCAdapter,        // → AuthServicePort
    NewNotificationServiceQueueAdapter, // → NotificationPort (QueuePort)
    NewUUIDSlugCodeGenerator,           // → EventCodeGeneratorPort
    NewQueueEventPublisher,             // → EventPublisherPort (Beta: Redis+BullMQ/asynq、本番: OCI Queue)
    
    // Use Cases
    NewCreateEventUseCase,
    NewUpdateEventUseCase,
    NewActivateEventUseCase,
    NewArchiveEventUseCase,
    NewGetEventUseCase,
    NewListEventsByOrgUseCase,
    NewInviteMemberByEmailUseCase,
    NewRespondToInvitationUseCase,
    NewJoinEventByCodeUseCase,
    NewListEventInvitationsUseCase,
    NewListEventParticipantsUseCase,
    NewRemoveParticipantUseCase,
    NewGetUserEventsUseCase,
    NewExpireOldInvitationsUseCase,
    
    // HTTP Handlers
    NewEventHTTPHandler,
    NewInvitationHTTPHandler,
    NewParticipantHTTPHandler,
    NewEventCodeHTTPHandler,
    NewJoinHTTPHandler,
)
```

## 6. ディレクトリ構成

### ディレクトリツリー

```
recerdo-events/
├── cmd/server/
│   └── main.go
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── event.go
│   │   │   ├── event_invitation.go
│   │   │   ├── event_code.go
│   │   │   ├── event_participant.go
│   │   │   └── event_role.go
│   │   ├── valueobject/
│   │   │   ├── event_status.go
│   │   │   ├── invitation_status.go
│   │   │   ├── event_code_vo.go
│   │   │   ├── event_role_vo.go
│   │   │   └── event_date_range.go
│   │   ├── event/
│   │   │   └── domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── create_event.go
│   │   ├── update_event.go
│   │   ├── activate_event.go
│   │   ├── archive_event.go
│   │   ├── get_event.go
│   │   ├── list_events_by_org.go
│   │   ├── invite_member_by_email.go
│   │   ├── respond_to_invitation.go
│   │   ├── join_event_by_code.go
│   │   ├── list_event_invitations.go
│   │   ├── list_event_participants.go
│   │   ├── remove_participant.go
│   │   ├── get_user_events.go
│   │   ├── get_event_code.go
│   │   ├── regenerate_event_code.go
│   │   ├── expire_old_invitations.go
│   │   ├── dto.go
│   │   └── port/
│   │       ├── repository.go
│   │       ├── service.go
│   │       └── publisher.go
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── event_handler.go
│   │   │   ├── invitation_handler.go
│   │   │   ├── participant_handler.go
│   │   │   ├── event_code_handler.go
│   │   │   ├── join_handler.go
│   │   │   ├── user_events_handler.go
│   │   │   ├── error_handler.go
│   │   │   └── middleware/
│   │   │       ├── auth.go
│   │   │       ├── org_context.go
│   │   │       └── logging.go
│   │   ├── grpc/
│   │   │   ├── permission_adapter.go
│   │   │   └── auth_adapter.go
│   │   ├── queue/
│   │   │   └── sqs_publisher.go
│   │   └── sqs_consumer/
│   │       └── invitation_expiration_consumer.go
│   └── infrastructure/
│       ├── MySQL/
│       │   ├── db.go
│       │   ├── event_repo.go
│       │   ├── event_invitation_repo.go
│       │   ├── event_code_repo.go
│       │   ├── event_participant_repo.go
│       │   └── migration/
│       │       └── *.up.sql / *.down.sql
│       ├── codegen/
│       │   └── event_code_generator.go
│       ├── notification/
│       │   └── notification_sqs_adapter.go
│       └── config/
│           └── config.go
├── pkg/
│   └── ulid/ (またはutility functions)
├── migrations/
│   ├── 001_create_events_tables.up.sql
│   ├── 001_create_events_tables.down.sql
│   └── ...
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── cronjob.yaml (expire invitations)
├── config/
│   └── config.yaml
├── test/
│   ├── integration/
│   │   ├── event_repo_test.go
│   │   └── ...
│   └── e2e/
│       └── event_flows_test.go
├── go.mod
├── go.sum
└── Makefile
```

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー                    | テスト種別       | モック戦略                                                     | 対象                                                                                        |
| --------------------------- | ---------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Domain (entity/valueobject) | Unit test        | 外部依存なし                                                   | Event.Validate(), EventCode.NewEventCode(), EventInvitation.Accept(), EventRole.CanInvite() |
| UseCase                     | Unit test        | mockeryで全ポート（PermissionPort/NotificationPort等）をモック | CreateEventUseCase, InviteMemberByEmailUseCase, RespondToInvitationUseCase                  |
| Adapter (HTTP)              | Integration test | httptest.Server + モック下流サービス                           | POST /api/orgs/{org_id}/events, GET /api/events/join/{code}                                 |
| Infrastructure (MySQL)      | Integration test | testcontainers-go でMySQL14コンテナを起動                      | EventRepository.Create(), EventInvitationRepository.ListExpiredPending()                    |
| E2E                         | E2E test         | MySQL 8.0/MariaDB 10.11 + Redis+BullMQ (testcontainers) + gRPC モック | イベント作成→招待→返答→参加の完全シナリオ                                            |
| Security test               | Penetration test | OWASP ZAP + カスタム検証                                       | SQL injection, authorization bypass, code enumeration                                       |

### テストコード例

```go
// Entity Test
func TestEvent_Validate_InvalidDateRange(t *testing.T) {
    event := &Event{
        Title:     "Summer Party",
        StartDate: time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC),
        EndDate:   time.Date(2026, 7, 15, 0, 0, 0, 0, time.UTC), // 逆
        Status:    "DRAFT",
    }
    err := event.Validate()
    assert.ErrorIs(t, err, ErrInvalidDateRange)
}

func TestEvent_TransitionToActive_SuccessfullyTransitions(t *testing.T) {
    event := &Event{
        Title:  "Summer Party",
        Status: "DRAFT",
    }
    err := event.TransitionToActive()
    assert.NoError(t, err)
    assert.Equal(t, "ACTIVE", event.Status)
}

func TestEventCode_NewEventCode_InvalidFormat(t *testing.T) {
    _, err := NewEventCode("summer-party-2026") // lowercase
    assert.ErrorIs(t, err, ErrInvalidEventCodeFormat)
    
    _, err = NewEventCode("SUMMER_PARTY_2026") // underscore
    assert.ErrorIs(t, err, ErrInvalidEventCodeFormat)
}

func TestEventInvitation_Accept_Success(t *testing.T) {
    invitation := &EventInvitation{
        Status:    "PENDING",
        ExpiresAt: time.Now().Add(30 * 24 * time.Hour),
    }
    now := time.Now()
    err := invitation.Accept("user-123", now)
    assert.NoError(t, err)
    assert.Equal(t, "ACCEPTED", invitation.Status)
    assert.Equal(t, "user-123", *invitation.AcceptedUserID)
    assert.NotNil(t, invitation.RespondedAt)
}

func TestEventInvitation_Accept_ExpiredInvitation(t *testing.T) {
    invitation := &EventInvitation{
        Status:    "PENDING",
        ExpiresAt: time.Now().Add(-1 * time.Hour),
    }
    now := time.Now()
    err := invitation.Accept("user-123", now)
    assert.ErrorIs(t, err, ErrCannotRespondToInvitation)
}

// UseCase Test
func TestCreateEventUseCase_Success(t *testing.T) {
    mockEventRepo := new(MockEventRepository)
    mockEventRepo.On("Create", mock.Anything, mock.MatchedBy(func(e *Event) bool {
        return e.Title == "Summer Party" && e.Status == "DRAFT"
    })).Return(nil)
    
    mockCodeRepo := new(MockEventCodeRepository)
    mockCodeRepo.On("Create", mock.Anything, "SUMMER-PARTY-2026", mock.Anything, "org-123").Return(nil)
    
    mockParticipantRepo := new(MockEventParticipantRepository)
    mockParticipantRepo.On("Create", mock.Anything, mock.Anything).Return(nil)
    
    mockPublisher := new(MockEventPublisherPort)
    mockPublisher.On("PublishEventCreated", mock.Anything, mock.Anything, "user-123").Return(nil)
    
    mockPermission := new(MockPermissionPort)
    mockPermission.On("CanCreateEvent", mock.Anything, "org-123", "user-123").Return(true, nil)
    
    uc := NewCreateEventUseCase(
        mockEventRepo,
        mockCodeRepo,
        mockParticipantRepo,
        mockPublisher,
        mockPermission,
    )
    
    input := CreateEventInput{
        OrgID:     "org-123",
        Title:     "Summer Party",
        StartDate: time.Date(2026, 7, 15, 0, 0, 0, 0, time.UTC),
        EndDate:   time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC),
        CreatedBy: "user-123",
    }
    
    output, err := uc.Execute(context.Background(), input)
    assert.NoError(t, err)
    assert.Equal(t, "DRAFT", output.Status)
    assert.NotEmpty(t, output.EventID)
    assert.NotEmpty(t, output.EventCode)
}

func TestInviteMemberByEmailUseCase_AlreadyInvited(t *testing.T) {
    mockEventRepo := new(MockEventRepository)
    mockEventRepo.On("GetByID", mock.Anything, "event-123").Return(&Event{Status: "ACTIVE"}, nil)
    
    mockInvitationRepo := new(MockEventInvitationRepository)
    mockInvitationRepo.On("GetByEmailAndEvent", mock.Anything, "user@example.com", "event-123").
        Return(&EventInvitation{Status: "PENDING"}, nil)
    
    mockPermission := new(MockPermissionPort)
    mockPermission.On("CanInviteToEvent", mock.Anything, "org-123", "event-123", "admin-user").
        Return(true, nil)
    
    uc := NewInviteMemberByEmailUseCase(
        mockEventRepo,
        mockInvitationRepo,
        mockPermission,
        nil, // publisher
        nil, // notification
    )
    
    input := InviteMemberByEmailInput{
        EventID:   "event-123",
        OrgID:     "org-123",
        Email:     "user@example.com",
        InvitedBy: "admin-user",
    }
    
    _, err := uc.Execute(context.Background(), input)
    assert.ErrorIs(t, err, ErrAlreadyInvited)
}

// Integration Test
func TestEventRepository_Create_InsertAndRetrieve(t *testing.T) {
    if testing.Short() {
        t.Skip("Skipping integration test in short mode")
    }
    
    container, db := setupMySQLContainer(t)
    defer container.Terminate(context.Background())
    
    repo := NewMySQLEventRepository(db)
    
    event := &Event{
        ID:        ulid.Make().String(),
        OrgID:     "org-123",
        Title:     "Summer Party",
        StartDate: time.Date(2026, 7, 15, 0, 0, 0, 0, time.UTC),
        EndDate:   time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC),
        Status:    "DRAFT",
        CreatedBy: "user-123",
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }
    
    err := repo.Create(context.Background(), event)
    assert.NoError(t, err)
    
    retrieved, err := repo.GetByID(context.Background(), event.ID)
    assert.NoError(t, err)
    assert.Equal(t, event.Title, retrieved.Title)
    assert.Equal(t, event.Status, retrieved.Status)
}

func TestEventInvitationRepository_ListExpiredPending(t *testing.T) {
    if testing.Short() {
        t.Skip("Skipping integration test in short mode")
    }
    
    container, db := setupMySQLContainer(t)
    defer container.Terminate(context.Background())
    
    repo := NewMySQLEventInvitationRepository(db)
    
    now := time.Now()
    expiredInvitation := &EventInvitation{
        ID:        ulid.Make().String(),
        EventID:   "event-123",
        OrgID:     "org-123",
        Email:     "user@example.com",
        InvitedBy: "admin-123",
        Status:    "PENDING",
        ExpiresAt: now.Add(-1 * time.Hour), // expired
        InvitedAt: now.Add(-31 * 24 * time.Hour),
    }
    
    err := repo.Create(context.Background(), expiredInvitation)
    assert.NoError(t, err)
    
    results, err := repo.ListExpiredPending(context.Background(), now, 100)
    assert.NoError(t, err)
    assert.Len(t, results, 1)
    assert.Equal(t, expiredInvitation.Email, results[0].Email)
}
```

## 8. エラーハンドリング

### ドメインエラー

- **ErrEventTitleRequired**: イベント作成時に title が空
- **ErrInvalidDateRange**: start_date >= end_date
- **ErrInvalidEventStatus**: status が DRAFT/ACTIVE/ARCHIVED 以外
- **ErrEventNotFound**: リクエストされたイベントが存在しない
- **ErrCannotTransitionToDraft**: DRAFT状態以外からDRAFTへの遷移試行
- **ErrCannotTransitionToActive**: DRAFT状態以外からACTIVEへの遷移試行
- **ErrAlreadyArchived**: アーカイブ済みイベントを再度アーカイブ
- **ErrCannotInviteToArchivedEvent**: アーカイブ済みイベントへのメンバー招待試行
- **ErrInvalidEventCode**: event_code が存在しない、または形式不正
- **ErrInvalidEventCodeLength**: event_code が 1～30文字範囲外
- **ErrInvalidEventCodeFormat**: event_code に大文字英数字・ハイフン以外を含む
- **ErrInvalidEmail**: 招待メールアドレスがRFC 5321不準拠
- **ErrAlreadyInvited**: 同じメールアドレスへのPENDING招待が既に存在
- **ErrCannotRespondToInvitation**: 期限切れ・返答済み招待への返答試行
- **ErrAlreadyParticipant**: 既にイベント参加しているユーザーがコード参加試行
- **ErrUnauthorized**: 権限不足（CreateEvent・Invite等）
- **ErrInvitationNotFound**: 招待IDが存在しない
- **ErrEventCodeExists**: event_code が org内で既に使用されている

### エラー → HTTPステータスマッピング

| ドメインエラー                 | HTTPステータス  | レスポンス例                                                            |
| ------------------------------ | --------------- | ----------------------------------------------------------------------- |
| ErrEventTitleRequired          | 400 Bad Request | `{"error": "Event title is required"}`                                  |
| ErrInvalidDateRange            | 400 Bad Request | `{"error": "Start date must be before end date"}`                       |
| ErrEventNotFound               | 404 Not Found   | `{"error": "Event not found"}`                                          |
| ErrCannotInviteToArchivedEvent | 400 Bad Request | `{"error": "Cannot invite members to archived event"}`                  |
| ErrInvalidEmail                | 400 Bad Request | `{"error": "Invalid email address"}`                                    |
| ErrAlreadyInvited              | 409 Conflict    | `{"error": "User already invited to this event"}`                       |
| ErrCannotRespondToInvitation   | 400 Bad Request | `{"error": "Cannot respond to expired or already answered invitation"}` |
| ErrAlreadyParticipant          | 409 Conflict    | `{"error": "User is already a participant of this event"}`              |
| ErrUnauthorized                | 403 Forbidden   | `{"error": "You do not have permission to perform this action"}`        |
| ErrInvitationNotFound          | 404 Not Found   | `{"error": "Invitation not found"}`                                     |
| ErrInvalidEventCode            | 404 Not Found   | `{"error": "Invalid event code"}`                                       |

## 9. 未決事項

### 質問・決定事項

| #   | 質問                                                                                                                    | ステータス | 決定                                                                                            |
| --- | ----------------------------------------------------------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------- |
| 1   | イベント削除時、関連する招待・参加者レコードは物理削除か論理削除か                                                      | Open       | 論理削除（deleted_atフラグ）推奨。イベント履歴・監査を残すため                                  |
| 2   | EventCode再生成時、古いコードの無効化は即座か、一定期間有効を保つか                                                     | Open       | 即座に無効化推奨。セキュリティ観点から。ただしUI上「古いコードはまだ有効か」を確認必要          |
| 3   | メンバー削除時、EventParticipantのロール削除か、ステータス遷移（ACTIVE→REMOVED等）か                                    | Open       | EventParticipant物理削除推奨。権限チェックシンプル化のため                                      |
| 4   | 招待メール送信失敗時（Notification Service ダウン）の再試行戦略は何か                                                   | ✅ Decided  | QueuePort の DLQ（Beta: BullMQ failed queue / asynq archived queue、本番: OCI Queue DLQ）で最大 3 回再試行、その後 admin-console-svc から手動再送 |
| 5   | イベント開始日前のドラフトイベント一覧取得時、パフォーマンス低下対策（キャッシング等）は必要か                          | Open       | Redis キャッシング 5分TTL検討。ただし初期段階ではDB直クエリで様子見                             |
| 6   | 招待有効期限30日は固定か、イベントごとにカスタマイズ可能にするか                                                        | Open       | 初期は30日固定。将来的にorg管理画面で設定可能に拡張予定                                         |
| 7   | EventParticipantの role 変更（e.g. MEMBER → ADMIN）は可能か、それとも削除＋再招待か                                     | Open       | 削除＋再招待推奨。権限昇格・降格イベントは明示的・監査可能なフローとして                        |
| 8   | イベントコードの形式（現在 "SUMMER-PARTY-2026" ）でユーザーが覚えやすいか。より短い形式（e.g. "SPY26"）検討の余地あるか | Open       | ユーザーテスト後に決定。短すぎると衝突リスク高い。30文字制限内で柔軟性確保                      |
| 9   | ExpireOldInvitations バッチ処理の実行頻度は日1回（00:00 UTC）で十分か                                                   | Open       | 日1回で初期段階は十分。ユーザー数・イベント数増加後、複数回実行への変更検討                     |
| 10  | Album Service自動作成（EventCreated→Album生成）は ACTIVE化時か作成直後（DRAFT時）か                                     | Open       | ACTIVE化時推奨。ユーザーがイベント確定後にアルバムが有効化されるほうが自然                      |

---

最終更新: 2026-04-19 ポリシー適用
