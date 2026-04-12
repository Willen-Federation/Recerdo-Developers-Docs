---
title: "Messaging Module Design"
weight: 16
---

# Messaging Module (recuerdo-messaging-svc)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoのコアバリュー「旧友・旧グループとの再接続」を実現するリアルタイムコミュニケーション基盤のドメイン層設計書。DM・グループチャット・音声/ビデオ通話・位置情報共有・メディア送信のビジネスロジックをクリーンアーキテクチャで整理する。

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
| Channel | メッセージのやり取りが行われるチャンネル | id (ULID), type (DM/GROUP), org_id?, name?, creator_id, members[], status, created_at |
| Message | チャンネル内のメッセージ本体 | id (ULID), channel_id, sender_id, type, content, media_ids[], location?, reply_to_id?, reactions[], deleted_at, created_at |
| ChannelMember | チャンネルへの参加者 | id, channel_id, user_id, role (OWNER/MEMBER), last_read_at, joined_at |
| MessageReaction | メッセージへの絵文字リアクション | id, message_id, user_id, emoji, created_at |
| CallSession | 音声/ビデオ通話セッション | id (ULID), channel_id, initiator_id, type (VOICE/VIDEO), status, participant_ids[], started_at, ended_at |

### 値オブジェクト

| 値オブジェクト | 説明 | バリデーションルール |
| --- | --- | --- |
| MessageType | メッセージ種別 (TEXT/IMAGE/VIDEO/FILE/LOCATION/SYSTEM) | 列挙値のみ許可 |
| ChannelType | チャンネル種別 (DM/GROUP) | DMは参加者2名固定、GROUPはorg_id必須 |
| MessageContent | テキストメッセージ本文 | 最大4000文字。空文字不可（TEXT/SYSTEMタイプの場合） |
| Location | 位置情報 | lat: -90〜90, lng: -180〜180, accuracy > 0 |
| ChannelRole | チャンネル内ロール (OWNER/MEMBER) | OWNERが1名以上存在 |
| CallStatus | 通話状態 (RINGING/ACTIVE/ENDED/MISSED) | ENDED/MISSED以降は変更不可 |
| MediaReference | Storage ServiceのメディアID参照リスト | 各IDはULID形式。最大10件/メッセージ |

### ドメインルール / 不変条件

- DMチャンネルは参加者が正確に2名でなければならない
- GROUPチャンネルはorg_idが必須
- チャンネルには必ず1名以上のOWNERが存在しなければならない
- 削除済みメッセージ (deleted_at != null) のcontentは表示してはならない
- 送信者本人またはチャンネルOWNERのみメッセージを削除できる
- ENDED/MISSEDの通話セッションは状態変更できない
- 位置情報共有のshared_untilが過去の日時の場合、位置情報を返してはならない
- サスペンドされたユーザーはメッセージを送信できない
- 同一ユーザーによる同一メッセージへの同一絵文字リアクションは1つまで
- メッセージのclient_message_idが重複する場合は冪等に既存メッセージを返す

### エンティティ定義（コードスケッチ）

```go
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
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース | 入力DTO | 出力DTO | 説明 |
| --- | --- | --- | --- |
| SendMessage | SendMessageInput{channel_id, sender_id, type, content?, media_ids[]?, location?, reply_to_id?, client_msg_id} | SendMessageOutput{message_id, created_at} | メッセージ送信。client_msg_idで冪等 |
| GetMessageHistory | GetMessageHistoryInput{channel_id, user_id, cursor?, limit} | GetMessageHistoryOutput{messages[], next_cursor, has_more} | カーソルページネーション |
| DeleteMessage | DeleteMessageInput{message_id, requestor_id} | DeleteMessageOutput{success} | メッセージ削除 |
| AddReaction | AddReactionInput{message_id, user_id, emoji} | AddReactionOutput{reaction_id} | リアクション追加 |
| CreateChannel | CreateChannelInput{type, creator_id, target_user_id?, org_id?, name?} | CreateChannelOutput{channel_id} | チャンネル作成 |
| ListChannels | ListChannelsInput{user_id, cursor?, limit} | ListChannelsOutput{channels[], next_cursor} | 参加チャンネル一覧 |
| MarkAsRead | MarkAsReadInput{channel_id, user_id, last_read_message_id} | MarkAsReadOutput{success} | 既読更新 |
| StartCall | StartCallInput{channel_id, initiator_id, type} | StartCallOutput{call_id, signal_token} | 通話開始 |
| EndCall | EndCallInput{call_id, user_id} | EndCallOutput{duration_seconds} | 通話終了 |
| SearchMessages | SearchMessageInput{user_id, query, channel_id?, limit} | SearchMessageOutput{messages[], total} | 全文検索 |

### SendMessage — 主要ユースケース詳細

**トリガー**: WebSocketフレーム受信またはREST POST

**フロー**:

1. Input validation
2. 冪等性チェック: FindByClientMsgID — 既存あり → 既存を返す
3. PermissionPort.CheckPermission — DENIED → エラー
4. ChannelMemberRepo.FindMembership — 非メンバー → エラー
5. タイプ別エンティティ生成 (TEXT/LOCATION/IMAGE等)
6. MessageRepository.Save
7. EventPublisherPort.Publish (非同期プッシュ通知)
8. RealtimePort.Broadcast (Redis Pub/Sub)
9. SearchIndexPort.Index (非同期Elasticsearch同期)

**目標**: 手順1〜6まで100ms以内

### リポジトリ・サービスポート

```go
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
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ | ルート/トリガー | ユースケース |
| --- | --- | --- |
| WebSocketHandler | WS /ws/chat — message_send | SendMessageUseCase |
| WebSocketHandler | WS /ws/chat — mark_read | MarkAsReadUseCase |
| WebSocketHandler | WS /ws/call/signal — call_start | StartCallUseCase |
| ChannelHTTPHandler | POST /v1/channels | CreateChannelUseCase |
| ChannelHTTPHandler | GET /v1/channels | ListChannelsUseCase |
| MessageHTTPHandler | GET /v1/channels/{channel_id}/messages | GetMessageHistoryUseCase |
| MessageHTTPHandler | POST /v1/channels/{channel_id}/messages | SendMessageUseCase |
| MessageHTTPHandler | DELETE /v1/channels/{channel_id}/messages/{id} | DeleteMessageUseCase |
| SearchHTTPHandler | GET /v1/messages/search | SearchMessagesUseCase |

### リポジトリ実装

| ポートインターフェース | 実装クラス | データストア |
| --- | --- | --- |
| MessageRepository | MySQLMessageRepository | MySQL 8.0 |
| ChannelRepository | MySQLChannelRepository | MySQL 8.0 |
| SearchIndexPort | ElasticsearchMessageIndex | AWS OpenSearch |
| RealtimePort | RedisPubSubRealtime | Redis 7.x Pub/Sub |

## 5. インフラストラクチャ層

Go 1.22 + gorilla/websocket + net/http。MySQL 8.0 + Redis 7.x + AWS OpenSearch 2.x。

### 主要ライブラリ

| ライブラリ | 目的 | レイヤー |
| --- | --- | --- |
| gorilla/websocket | WebSocketサーバー | Infrastructure |
| go-redis/v9 | Redis Pub/Sub | Infrastructure |
| go-sql-driver/mysql | MySQLドライバ | Infrastructure |
| opensearch-go | 検索クライアント | Infrastructure |
| google.golang.org/grpc | Permission/Storage gRPC | Infrastructure |
| oklog/ulid/v2 | ULID生成 | Domain |
| uber-go/fx | 依存性注入 | Infrastructure |
| go.opentelemetry.io/otel | 分散トレーシング | Infrastructure |

## 6. ディレクトリ構成

```
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
│   │   ├── event/domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── send_message.go
│   │   ├── get_message_history.go
│   │   ├── delete_message.go
│   │   ├── create_channel.go
│   │   ├── list_channels.go
│   │   ├── mark_as_read.go
│   │   ├── start_call.go
│   │   └── end_call.go
│   ├── adapter/
│   │   ├── websocket/
│   │   ├── http/
│   │   └── queue/
│   └── infrastructure/
│       ├── mysql/
│       ├── redis/
│       ├── opensearch/
│       ├── grpc/
│       └── sqs/
├── proto/
├── migrations/
└── config/
```

## 7. テスト戦略

| レイヤー | テスト種別 | モック戦略 |
| --- | --- | --- |
| Domain | Unit test | 外部依存なし |
| UseCase | Unit test | mockeryでモック |
| Adapter (WebSocket) | Integration test | gorilla/websocket テストクライアント |
| Adapter (HTTP) | Integration test | httptest.NewRecorder |
| Infrastructure | Integration test | testcontainers-go |
| E2E | E2E test | WebSocket接続→送受信→既読の完全シナリオ |

### テストコード例

```go
func TestMessage_Delete_BySender(t *testing.T) {
    msg := &Message{ID: "01J...", SenderID: "user-a", Content: "Hello"}
    err := msg.Delete("user-a", ChannelRoleMember)
    assert.NoError(t, err)
    assert.NotNil(t, msg.DeletedAt)
    assert.Empty(t, msg.Content)
}

func TestNewDMChannel_CannotDMSelf(t *testing.T) {
    _, err := NewDMChannel("user-a", "user-a")
    assert.ErrorIs(t, err, ErrCannotDMSelf)
}

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
}
```

## 8. エラーハンドリング

| ドメインエラー | HTTPステータス | ユーザーメッセージ |
| --- | --- | --- |
| ErrInvalidMessageContent | 400 | Message content must be between 1 and 4000 characters |
| ErrMessageAlreadyDeleted | 409 | Message has already been deleted |
| ErrNotAuthorizedToDelete | 403 | You are not authorized to delete this message |
| ErrReactionAlreadyExists | 409 | You have already reacted with this emoji |
| ErrCannotDMSelf | 400 | You cannot create a DM with yourself |
| ErrNotChannelMember | 403 | You are not a member of this channel |
| ErrChannelNotFound | 404 | Channel not found |
| ErrMessageNotFound | 404 | Message not found |
| ErrCallAlreadyEnded | 409 | Call session has already ended |
| ErrMediaValidationFailed | 422 | One or more media files could not be accessed |

## 9. 未決事項

| # | 質問 | ステータス |
| --- | --- | --- |
| 1 | 位置情報リアルタイム共有の更新間隔 | Open |
| 2 | グループ通話の最大参加者数上限 | Open |
| 3 | 初期検索エンジン（MySQL FTS vs Elasticsearch） | Open |
| 4 | E2E暗号化導入時のcontent保存フォーマット | Open |
| 5 | WebSocketハートビート間隔 | Open |
