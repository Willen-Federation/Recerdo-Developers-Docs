# Messaging Module (recuerdo-messaging-svc)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoのコアバリュー「旧友・旧グループとの再接続」を実現するリアルタイムコミュニケーション基盤のドメイン層設計書。DM・グループチャット・音声/ビデオ通話・位置情報共有・メディア送信のビジネスロジックをクリーンアーキテクチャで整理する。Permission Serviceとの権限チェック連携、Storage ServiceへのメディアID参照、Notification Serviceへのイベント発行を外部依存として明確に分離する。

### ビジネスコンテキスト

recuerdoは旧友・旧グループとの再接続と思い出の保存を核とするソーシャルメモリアプリ。メッセージ機能はユーザーの日常的な利用（DAU）を促進し、将来の課金モデル（Premiumプランの通話機能）の基盤となる。

Key User Stories:
- 旧友と2年ぶりに再接続し、グループチャットで思い出の写真を共有したい
- 卒業した仲間のグループチャットに過去のイベント写真を添付してメッセージしたい
- 離れて暮らす友人とビデオ通話でリアルタイムにつながりたい
- グループメンバーに今いる場所をリアルタイムで共有したい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ | 説明 | 主要属性 |
| --- | --- | --- |
| Channel | メッセージのやり取りが行われるチャンネル。DMとグループの2種類 | id (ULID), type (DM/GROUP), org_id?, name?, creator_id, members[], status, created_at |
| Message | チャンネル内のメッセージ本体。テキスト・メディア・位置情報・システムメッセージを包含 | id (ULID), channel_id, sender_id, type, content, media_ids[], location?, reply_to_id?, reactions[], deleted_at, created_at |
| ChannelMember | チャンネルへの参加者。既読管理を担う | id, channel_id, user_id, role (OWNER/MEMBER), last_read_at, joined_at |
| MessageReaction | メッセージへの絵文字リアクション | id, message_id, user_id, emoji, created_at |
| CallSession | 音声/ビデオ通話セッション。シグナリング状態を管理 | id (ULID), channel_id, initiator_id, type (VOICE/VIDEO), status (RINGING/ACTIVE/ENDED), participant_ids[], started_at, ended_at |

### 値オブジェクト

| 値オブジェクト | 説明 | バリデーションルール |
| --- | --- | --- |
| MessageType | メッセージ種別 (TEXT/IMAGE/VIDEO/FILE/LOCATION/SYSTEM) | 列挙値のみ許可 |
| ChannelType | チャンネル種別 (DM/GROUP) | 列挙値のみ。DMは参加者2名固定、GROUPはorg_id必須 |
| MessageContent | テキストメッセージ本文 | 最大4000文字。空文字不可（TEXT/SYSTEMタイプの場合） |
| Location | 位置情報 {lat, lng, accuracy, shared_until} | lat: -90〜90, lng: -180〜180, accuracy > 0, shared_until は未来の日時 |
| ChannelRole | チャンネル内ロール (OWNER/MEMBER) | 列挙値のみ。チャンネルに必ずOWNERが1名以上存在 |
| CallStatus | 通話セッション状態 (RINGING/ACTIVE/ENDED/MISSED) | 列挙値のみ。ENDED/MISSED以降は変更不可 |
| MediaReference | Storage ServiceのメディアID参照リスト | 各IDはULID形式 (26文字英数字)。最大10件/メッセージ |

### ドメインルール / 不変条件

- DMチャンネルは参加者が正確に2名でなければならない
- GROUPチャンネルはorg_idが必須であり、対応する組織が存在しなければならない
- チャンネルには必ず1名以上のOWNERが存在しなければならない
- 削除済みメッセージ (deleted_at != null) のcontentは表示してはならない
- 送信者本人またはチャンネルOWNERのみメッセージを削除できる
- ENDED/MISSEDの通話セッションは状態変更できない
- 位置情報共有のshared_untilが過去の日時の場合、位置情報を返してはならない
- サスペンドされたユーザー (Permission Service確認) はメッセージを送信できない
- 同一ユーザーによる同一メッセージへの同一絵文字リアクションは1つまで
- メッセージのclient_message_idが重複する場合は冪等に既存メッセージを返す

### ドメインイベント

| イベント | トリガー | 主要ペイロード |
| --- | --- | --- |
| MessageSent | メッセージ送信成功時 | message_id, channel_id, sender_id, type, preview_text, recipient_ids[], timestamp |
| MessageDeleted | メッセージ削除時 | message_id, channel_id, deleted_by, timestamp |
| MessageReactionAdded | リアクション追加時 | message_id, channel_id, user_id, emoji, timestamp |
| ChannelCreated | チャンネル作成時 | channel_id, type, org_id?, creator_id, member_ids[], timestamp |
| MemberJoined | メンバーがチャンネルに参加した時 | channel_id, user_id, role, timestamp |
| MemberLeft | メンバーがチャンネルから退出した時 | channel_id, user_id, timestamp |
| CallStarted | 通話セッション開始時 | call_id, channel_id, initiator_id, type, participant_ids[], timestamp |
| CallEnded | 通話セッション終了時 | call_id, duration_seconds, participant_ids[], timestamp |
| LocationShared | 位置情報共有メッセージ送信時 | message_id, channel_id, sender_id, location, shared_until, timestamp |

### エンティティ定義（コードスケッチ）

// Go-style pseudocode

type MessageType string
const (
    MessageTypeText     MessageType = "TEXT"
    MessageTypeImage    MessageType = "IMAGE"
    MessageTypeLocation MessageType = "LOCATION"
)

type Message struct {
    ID          string
    ChannelID   string
    SenderID    string
    Type        MessageType
    Content     string
    MediaIDs    []string
    Location    *Location
    ReplyToID   *string
    Reactions   []MessageReaction
    ClientMsgID string
    DeletedAt   *time.Time
    CreatedAt   time.Time
}

func NewTextMessage(channelID, senderID, content, clientMsgID string) (*Message, error) {
    if len(content) == 0 || len(content) > 4000 {
        return nil, ErrInvalidMessageContent
    }
    return &Message{
        ID: newULID(), ChannelID: channelID,
        SenderID: senderID, Type: MessageTypeText,
        Content: content, ClientMsgID: clientMsgID,
        CreatedAt: time.Now(),
    }, nil
}

func (m *Message) Delete(requestorID string, role ChannelRole) error {
    if m.DeletedAt != nil { return ErrMessageAlreadyDeleted }
    if m.SenderID != requestorID && role != ChannelRoleOwner {
        return ErrNotAuthorizedToDelete
    }
    now := time.Now()
    m.DeletedAt = &now
    m.Content = ""
    return nil
}

func (m *Message) AddReaction(userID, emoji string) error {
    for _, r := range m.Reactions {
        if r.UserID == userID && r.Emoji == emoji {
            return ErrReactionAlreadyExists
        }
    }
    m.Reactions = append(m.Reactions, MessageReaction{
        ID: newULID(), MessageID: m.ID,
        UserID: userID, Emoji: emoji, CreatedAt: time.Now(),
    })
    return nil
}

func NewDMChannel(creatorID, targetID string) (*Channel, error) {
    if creatorID == targetID { return nil, ErrCannotDMSelf }
    return &Channel{
        ID: newULID(), Type: ChannelTypeDM, CreatorID: creatorID,
        Members: []ChannelMember{
            {UserID: creatorID, Role: ChannelRoleOwner},
            {UserID: targetID, Role: ChannelRoleMember},
        },
        CreatedAt: time.Now(),
    }, nil
}

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース | 入力DTO | 出力DTO | 説明 |
| --- | --- | --- | --- |
| SendMessage | SendMessageInput{channel_id, sender_id, type, content?, media_ids[]?, location?, reply_to_id?, client_msg_id} | SendMessageOutput{message_id, created_at} | メッセージ送信の核心ユースケース。client_msg_idで重複送信を防ぐ |
| GetMessageHistory | GetMessageHistoryInput{channel_id, user_id, cursor?, limit} | GetMessageHistoryOutput{messages[], next_cursor, has_more} | カーソルページネーションでメッセージ履歴を取得 |
| DeleteMessage | DeleteMessageInput{message_id, requestor_id} | DeleteMessageOutput{success} | 送信者本人またはOWNERがメッセージを削除 |
| AddReaction | AddReactionInput{message_id, user_id, emoji} | AddReactionOutput{reaction_id} | メッセージにリアクションを追加 |
| CreateChannel | CreateChannelInput{type, creator_id, target_user_id?, org_id?, name?} | CreateChannelOutput{channel_id} | DMまたはGROUPチャンネルを作成 |
| ListChannels | ListChannelsInput{user_id, cursor?, limit} | ListChannelsOutput{channels[], next_cursor} | 参加チャンネル一覧を最終メッセージ順で取得 |
| MarkAsRead | MarkAsReadInput{channel_id, user_id, last_read_message_id} | MarkAsReadOutput{success} | チャンネルの既読位置を更新 |
| StartCall | StartCallInput{channel_id, initiator_id, type} | StartCallOutput{call_id, signal_token} | 音声/ビデオ通話セッションを開始 |
| EndCall | EndCallInput{call_id, user_id} | EndCallOutput{duration_seconds} | 通話セッションを終了 |
| SearchMessages | SearchMessageInput{user_id, query, channel_id?, limit} | SearchMessageOutput{messages[], total} | メッセージ全文検索 |

### ユースケース詳細（主要ユースケース）

## SendMessage — 主要ユースケース詳細

### トリガー
WebSocketフレーム受信またはREST POST /v1/channels/{channel_id}/messages

### フロー
1. Input validation: channel_id・sender_id・client_msg_idが空でないことを確認
2. 冪等性チェック: MessageRepo.FindByClientMsgID(channel_id, client_msg_id)
   - 既存メッセージが見つかった → 既存message_idを返す（DB保存なし）
3. PermissionPort.CheckPermission(sender_id, channel_id, send_message)
   - DENIED → ErrPermissionDenied
4. ChannelMemberRepo.FindMembership(channel_id, sender_id)
   - 非メンバー → ErrNotChannelMember
5. タイプ別エンティティ生成:
   - TEXT: NewTextMessage(channel_id, sender_id, content, client_msg_id)
   - LOCATION: NewLocationMessage(...) — Validate()で座標・shared_until検証
   - IMAGE/VIDEO/FILE: StoragePort.ValidateMediaIDs(media_ids)
6. MessageRepository.Save(message)
7. EventPublisherPort.Publish(MessageSent{...}) — 非同期でNotification Serviceがプッシュ通知
8. RealtimePort.Broadcast(channel_id, message) — Redis Pub/Sub経由でブロードキャスト
9. SearchIndexPort.Index(message) — 非同期でElasticsearch同期
10. SendMessageOutput{message_id, created_at} を返す

### 注意事項
- 手順6(DB保存)が成功してから7〜9を実行。DB失敗時はエラーを返す
- 目標: 手順1〜6まで100ms以内

### リポジトリ・サービスポート（インターフェース）

// Repository Ports
type MessageRepository interface {
    Save(ctx context.Context, msg *Message) error
    FindByID(ctx context.Context, id string) (*Message, error)
    FindByChannel(ctx context.Context, channelID, cursor string, limit int) ([]*Message, string, error)
    SoftDelete(ctx context.Context, id string, deletedAt time.Time) error
    FindByClientMsgID(ctx context.Context, channelID, clientMsgID string) (*Message, error)
}

type ChannelRepository interface {
    Save(ctx context.Context, ch *Channel) error
    FindByID(ctx context.Context, id string) (*Channel, error)
    FindByUserID(ctx context.Context, userID, cursor string, limit int) ([]*Channel, string, error)
    FindDMByUserPair(ctx context.Context, userA, userB string) (*Channel, error)
}

type ChannelMemberRepository interface {
    FindMembership(ctx context.Context, channelID, userID string) (*ChannelMember, error)
    Save(ctx context.Context, member *ChannelMember) error
    UpdateLastRead(ctx context.Context, channelID, userID string, lastReadAt time.Time) error
}

type CallSessionRepository interface {
    Save(ctx context.Context, call *CallSession) error
    FindByID(ctx context.Context, id string) (*CallSession, error)
    UpdateStatus(ctx context.Context, id string, status CallStatus, endedAt *time.Time) error
}

// Service Ports
type PermissionPort interface {
    CheckPermission(ctx context.Context, userID, resourceID, action string) (bool, error)
}

type RealtimePort interface {
    Broadcast(ctx context.Context, channelID string, msg *Message) error
    BroadcastCallEvent(ctx context.Context, channelID string, event CallEvent) error
}

type StoragePort interface {
    ValidateMediaIDs(ctx context.Context, mediaIDs []string) error
}

type SearchIndexPort interface {
    Index(ctx context.Context, msg *Message) error
    Search(ctx context.Context, userID, query string, channelID *string, limit int) ([]*Message, int, error)
}

type EventPublisherPort interface {
    Publish(ctx context.Context, event DomainEvent) error
}

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ | ルート/トリガー | ユースケース |
| --- | --- | --- |
| WebSocketHandler | WS /ws/chat — message_send フレーム | SendMessageUseCase |
| WebSocketHandler | WS /ws/chat — mark_read フレーム | MarkAsReadUseCase |
| WebSocketHandler | WS /ws/call/signal — call_start フレーム | StartCallUseCase |
| WebSocketHandler | WS /ws/call/signal — call_end フレーム | EndCallUseCase |
| ChannelHTTPHandler | POST /v1/channels | CreateChannelUseCase |
| ChannelHTTPHandler | GET /v1/channels | ListChannelsUseCase |
| MessageHTTPHandler | GET /v1/channels/{channel_id}/messages | GetMessageHistoryUseCase |
| MessageHTTPHandler | POST /v1/channels/{channel_id}/messages | SendMessageUseCase (REST fallback) |
| MessageHTTPHandler | DELETE /v1/channels/{channel_id}/messages/{message_id} | DeleteMessageUseCase |
| ReactionHTTPHandler | POST /v1/channels/{channel_id}/messages/{message_id}/reactions | AddReactionUseCase |
| SearchHTTPHandler | GET /v1/messages/search | SearchMessagesUseCase |
| SQSConsumer | Queue: core.org_member_removed | RemoveMemberFromChannelsUseCase |
| SQSConsumer | Queue: permission.user_suspended | DisconnectUserUseCase |

### リポジトリ実装

| ポートインターフェース | 実装クラス | データストア |
| --- | --- | --- |
| MessageRepository | MySQLMessageRepository | MySQL 8.0 (messages table) |
| ChannelRepository | MySQLChannelRepository | MySQL 8.0 (channels table) |
| ChannelMemberRepository | MySQLChannelMemberRepository | MySQL 8.0 (channel_members table) |
| CallSessionRepository | MySQLCallSessionRepository | MySQL 8.0 (call_sessions table) |
| SearchIndexPort | ElasticsearchMessageIndex | AWS OpenSearch Service |
| RealtimePort | RedisPubSubRealtime | Redis 7.x Pub/Sub |

### 外部サービスアダプタ

| ポートインターフェース | アダプタクラス | 外部システム |
| --- | --- | --- |
| PermissionPort | PermissionServiceGRPCAdapter | recuerdo-permission-svc (gRPC) |
| StoragePort | StorageServiceGRPCAdapter | recuerdo-storage-svc (gRPC) |
| EventPublisherPort | SQSEventPublisher | AWS SQS (recuerdo-messaging-events) |
| RealtimePort (dispatch) | RedisWebSocketBroker | Redis Pub/Sub (channel broadcast) |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + gorilla/websocket (WebSocketサーバー) + net/http (REST API)

### データベース

MySQL 8.0 (go-sql-driver/mysql, pool max 50). Redis 7.x (go-redis/v9). AWS OpenSearch Service 2.x (opensearch-go).

### 主要ライブラリ・SDK

| ライブラリ | 目的 | レイヤー |
| --- | --- | --- |
| gorilla/websocket | WebSocketサーバー実装 | Infrastructure |
| go-redis/v9 | Redis Pub/Sub・レート制限 | Infrastructure |
| go-sql-driver/mysql | MySQLドライバ | Infrastructure |
| opensearch-go | Elasticsearch互換検索クライアント | Infrastructure |
| google.golang.org/grpc | Permission/Storage Service gRPCクライアント | Infrastructure |
| aws-sdk-go-v2/service/sqs | SQSイベント発行・消費 | Infrastructure |
| oklog/ulid/v2 | ULID生成 (message_id, channel_id) | Domain |
| uber-go/fx | 依存性注入 | Infrastructure |
| uber-go/zap | 構造化ログ | Infrastructure |
| go.opentelemetry.io/otel | 分散トレーシング | Infrastructure |

### 依存性注入

uber-go/fx を使用。全ポートをインターフェースとして登録し、ユースケースへ注入。

fx.Provide(
    NewMySQLMessageRepository,
    NewMySQLChannelRepository,
    NewRedisPubSubRealtime,
    NewPermissionServiceGRPCAdapter,
    NewElasticsearchMessageIndex,
    NewSQSEventPublisher,
    NewSendMessageUseCase,
    NewWebSocketHandler,
    NewChannelHTTPHandler,
)

## 6. ディレクトリ構成

### ディレクトリツリー

recuerdo-messaging-svc/
├── cmd/server/main.go
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── message.go
│   │   │   ├── channel.go
│   │   │   ├── channel_member.go
│   │   │   ├── message_reaction.go
│   │   │   └── call_session.go
│   │   ├── valueobject/
│   │   │   ├── message_type.go
│   │   │   ├── channel_type.go
│   │   │   ├── location.go
│   │   │   └── call_status.go
│   │   ├── event/domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── send_message.go
│   │   ├── get_message_history.go
│   │   ├── delete_message.go
│   │   ├── add_reaction.go
│   │   ├── create_channel.go
│   │   ├── list_channels.go
│   │   ├── mark_as_read.go
│   │   ├── start_call.go
│   │   ├── end_call.go
│   │   ├── search_messages.go
│   │   └── port/
│   │       ├── repository.go
│   │       └── service.go
│   ├── adapter/
│   │   ├── websocket/
│   │   │   ├── handler.go
│   │   │   └── hub.go
│   │   ├── http/
│   │   │   ├── channel_handler.go
│   │   │   ├── message_handler.go
│   │   │   └── search_handler.go
│   │   └── queue/sqs_consumer.go
│   └── infrastructure/
│       ├── mysql/
│       │   ├── message_repo.go
│       │   ├── channel_repo.go
│       │   └── call_session_repo.go
│       ├── redis/pubsub_realtime.go
│       ├── opensearch/message_index.go
│       ├── grpc/
│       │   ├── permission_adapter.go
│       │   └── storage_adapter.go
│       └── sqs/event_publisher.go
├── proto/
├── migrations/
└── config/

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー | テスト種別 | モック戦略 |
| --- | --- | --- |
| Domain (entity/valueobject) | Unit test | 外部依存なし。純粋なGoテスト |
| UseCase | Unit test | mockeryでMessageRepository/PermissionPort等をモック |
| Adapter (WebSocket) | Integration test | gorilla/websocket テストクライアント + httptest.Server |
| Adapter (HTTP) | Integration test | httptest.NewRecorder でHTTPハンドラをテスト |
| Infrastructure (MySQL/Redis) | Integration test | testcontainers-go でMySQL8.0/Redis7コンテナを起動 |
| E2E | E2E test | WebSocket接続→メッセージ送受信→既読更新の完全シナリオ |

### テストコード例

// Entity Test
func TestMessage_Delete_BySender(t *testing.T) {
    msg := &Message{ID: "01J...", SenderID: "user-a", Content: "Hello"}
    err := msg.Delete("user-a", ChannelRoleMember)
    assert.NoError(t, err)
    assert.NotNil(t, msg.DeletedAt)
    assert.Empty(t, msg.Content)
}

func TestMessage_Delete_ByNonSenderNonOwner(t *testing.T) {
    msg := &Message{SenderID: "user-a"}
    err := msg.Delete("user-b", ChannelRoleMember)
    assert.ErrorIs(t, err, ErrNotAuthorizedToDelete)
}

func TestNewDMChannel_CannotDMSelf(t *testing.T) {
    _, err := NewDMChannel("user-a", "user-a")
    assert.ErrorIs(t, err, ErrCannotDMSelf)
}

// UseCase Test
func TestSendMessage_DuplicateClientMsgID(t *testing.T) {
    existing := &Message{ID: "msg-existing", ClientMsgID: "client-abc"}
    mockRepo := new(MockMessageRepository)
    mockRepo.On("FindByClientMsgID", "ch-1", "client-abc").Return(existing, nil)

    uc := NewSendMessageUseCase(mockRepo, nil, nil, nil, nil)
    out, err := uc.Execute(ctx, SendMessageInput{
        ChannelID: "ch-1", SenderID: "user-a",
        Type: MessageTypeText, Content: "Hello",
        ClientMsgID: "client-abc",
    })

    assert.NoError(t, err)
    assert.Equal(t, "msg-existing", out.MessageID)
    mockRepo.AssertNotCalled(t, "Save")
}

## 8. エラーハンドリング

### ドメインエラー

- ErrInvalidMessageContent: テキストcontentが空または4000文字超
- ErrInvalidClientMsgID: client_msg_idが空
- ErrMessageAlreadyDeleted: 既に削除済みのメッセージを削除しようとした
- ErrNotAuthorizedToDelete: 送信者本人でもOWNERでもないユーザーが削除しようとした
- ErrReactionAlreadyExists: 同一ユーザーが同一メッセージに同一絵文字を重複追加
- ErrCannotDMSelf: 自分自身にDMチャンネルを作成しようとした
- ErrChannelMustHaveOwner: OWNERが0名になる操作を行おうとした
- ErrNotChannelMember: チャンネル非メンバーが操作を行おうとした
- ErrChannelNotFound: 指定されたchannel_idが存在しない
- ErrMessageNotFound: 指定されたmessage_idが存在しない
- ErrPermissionDenied: Permission Serviceによる権限チェックで拒否
- ErrCallAlreadyEnded: 終了済みの通話セッションを操作しようとした
- ErrInvalidLocation: 位置情報の座標またはshared_untilが不正
- ErrMediaValidationFailed: Storage ServiceでmediaIDが存在しないまたはアクセス不可

### エラー → HTTPステータスマッピング

| ドメインエラー | HTTPステータス | ユーザーメッセージ |
| --- | --- | --- |
| ErrInvalidMessageContent | 400 Bad Request | Message content must be between 1 and 4000 characters |
| ErrInvalidClientMsgID | 400 Bad Request | client_message_id is required |
| ErrMessageAlreadyDeleted | 409 Conflict | Message has already been deleted |
| ErrNotAuthorizedToDelete | 403 Forbidden | You are not authorized to delete this message |
| ErrReactionAlreadyExists | 409 Conflict | You have already reacted with this emoji |
| ErrCannotDMSelf | 400 Bad Request | You cannot create a direct message with yourself |
| ErrChannelMustHaveOwner | 400 Bad Request | Channel must have at least one owner |
| ErrNotChannelMember | 403 Forbidden | You are not a member of this channel |
| ErrChannelNotFound | 404 Not Found | Channel not found |
| ErrMessageNotFound | 404 Not Found | Message not found |
| ErrPermissionDenied | 403 Forbidden | You do not have permission to perform this action |
| ErrCallAlreadyEnded | 409 Conflict | Call session has already ended |
| ErrInvalidLocation | 400 Bad Request | Invalid location data |
| ErrMediaValidationFailed | 422 Unprocessable Entity | One or more media files could not be accessed |

## 9. 未決事項

### 質問・決定事項

| # | 質問 | ステータス | 決定 |
| --- | --- | --- | --- |
| 1 | 位置情報リアルタイム共有の更新間隔はいくつか（バッテリー・通信量への影響） | Open | 未決定。初期5秒。バックグラウンド時は30秒に自動切り替え予定 |
| 2 | グループ通話の最大参加者数上限はドメインルールとして何名か | Open | 未決定。初期20名上限をCallSessionエンティティのbusiness ruleとして実装 |
| 3 | メッセージ検索はMySQL FTSで初期対応し、Elasticsearchを遅らせるか | Open | 未決定。SearchIndexPortの実装を差し替え可能な設計にしてMySQL FTSで初期実装 |
| 4 | E2E暗号化導入時、MessageエンティティのcontentはどのフォーマットでDBに保存するか | Open | フェーズ2で検討。現時点はplaintext+DB暗号化のみ |
| 5 | WebSocket接続のハートビート間隔はいくつが適切か | Open | 未決定。初期30秒pingフレーム。60秒応答なしで接続切断 |
