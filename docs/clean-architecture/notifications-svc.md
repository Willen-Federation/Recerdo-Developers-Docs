# クリーンアーキテクチャ設計書

| 項目                      | 値                                                |
| ------------------------- | ------------------------------------------------- |
| **モジュール/サービス名** | Notification Service (recuerdo-notifications-svc) |
| **作成者**                | Claude (AI)                                       |
| **作成日**                | 2026-04-15                                        |
| **ステータス**            | 提案 (Proposal)                                   |
| **バージョン**            | 1.0                                               |

---

## 1. 概要

### 1.1 目的
Notification Service は Recuerdo プラットフォーム全体のプッシュ通知・アプリ内通知・メール通知を一元管理する。Messaging Service、Events Service、Album Service からのイベントを **QueuePort (Beta: Redis+BullMQ/asynq, Prod: OCI Queue)** 経由で受け取り、**FCM（Firebase Cloud Messaging）を主軸としたプッシュ通知**を配信する。メール通知は **オンプレミス SMTP（Postfix+Dovecot+Rspamd / Beta は XServer VPS、Prod は CoreServerV2 ホスティング）** を使用し、セキュリティ要件・FCMトークン未登録ユーザー・法的通知など特定条件下のみで利用する（条件詳細は「5.3 PostfixSMTP 利用条件」を参照）。AWS SES は使用しない（ポリシー: AWS = Cognito のみ）。ユーザー設定に基づいた通知ルーティング、デバイストークン管理、配信状態トラッキング、重複排除を提供し、低コストかつスケーラブルな通知基盤を実現する。

### 1.2 ビジネスコンテキスト
Recuerdo では、ユーザーが思い出共有、メッセージ受信、グループ作成などのイベントを通知で認知する必要がある。複数マイクロサービスから通知ニーズが生じるため、一元管理サービスが必須。**FCMを主軸**（無料、無制限）とし、オンプレミスサーバーによるメール通知はセキュリティ通知・ダイジェスト等の限定条件でのみ使用することで、OneSignal 等の SaaS と比較して 年間$1,000以上のコスト削減を実現。デバイストークン失効、ユーザー設定変更、オフライン対応など複雑な要件を満たす。

### 1.3 アーキテクチャ原則
- **単一責任の原則**: 通知配信に専念し、ビジネスロジック実装は依存しない
- **依存性の逆転**: リポジトリ・外部サービスはインターフェース（ポート）経由で依存
- **層間の厳密な分離**: Entity → UseCase → Adapter → Framework の一方向依存
- **テスト可能性**: すべてのユースケースはインターフェース依存、モック容易
- **スケーラビリティ**: QueuePort 非同期処理（Beta: Redis+BullMQ/asynq, Prod: OCI Queue）、Redis キャッシュ、DB インデックス設計
- **コスト効率**: FCM（無料）+ オンプレミス SMTP（Postfix+Dovecot+Rspamd / CoreServerV2）の組み合わせ
- **AWS 非依存**: AWS SES/SQS/SNS は使用しない（Cognito のみ）

---

## 2. レイヤーアーキテクチャ

### 2.1 アーキテクチャ図
```
┌──────────────────────────────────────────────────────────┐
│  Frameworks & Drivers (フレームワーク＆ドライバ)          │
│  Gin, MySQL(MariaDB互換), Redis, FCM,                    │
│  Postfix+Dovecot+Rspamd (SMTP), QueuePort                │
└──────────────────────────────────────────────────────────┘
                          ▲
                          │ (依存)
┌──────────────────────────────────────────────────────────┐
│  Interface Adapters (インターフェースアダプタ)            │
│  HTTP Controllers, Repository Impl,                      │
│  FCMPushAdapter, PostfixSMTPAdapter,                     │
│  QueueConsumer (RedisBullMQ / OCI Queue)                 │
└──────────────────────────────────────────────────────────┘
                          ▲
                          │ (依存)
┌──────────────────────────────────────────────────────────┐
│  Application Business Rules (アプリケーション)           │
│  Use Cases, DTOs, Port Interfaces                        │
│  (SendNotification, RegisterDevice, UpdatePrefs)         │
└──────────────────────────────────────────────────────────┘
                          ▲
                          │ (依存)
┌──────────────────────────────────────────────────────────┐
│  Enterprise Business Rules (エンティティ/ドメイン)       │
│  Domain Models (Notification, DeviceToken, Pref),       │
│  Value Objects (NotificationType, DeliveryChannel)       │
└──────────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール
外側のレイヤーは内側に依存し、内側は外側に依存しない。データフロー: 入力アダプタ（REST / QueuePort Consumer）→ ユースケース → 出力アダプタ（DB / FCMPushAdapter / PostfixSMTPAdapter）。外側のレイヤー間通信はポート（インターフェース）経由のみ。ドメイン層は業務ロジック、フレームワーク非依存。

---

## 3. エンティティ層（ドメイン）

### 3.1 ドメインモデル

| エンティティ名         | 説明                           | 主要フィールド                                                                                                                                                         |
| ---------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Notification           | 配信対象の通知レコード         | notificationId (UUID), userId, title, body, notificationType, deliveryChannels[], priority, status (PENDING/SENT/FAILED), createdAt, expiresAt                         |
| DeviceToken            | ユーザーのプッシュ通知トークン | deviceTokenId (UUID), userId, deviceId, platform (iOS/Android), tokenValue, isValid, lastUsedAt, registeredAt, expiresAt                                               |
| NotificationPreference | ユーザーの通知設定             | preferenceId (UUID), userId, notificationType, emailFrequency (DAILY/WEEKLY/NEVER), pushEnabled (bool), inAppEnabled (bool), quietHoursStart, quietHoursEnd, updatedAt |
| NotificationLog        | 配信ログ                       | logId (UUID), notificationId, channel (PUSH/EMAIL/IN_APP), deliveryStatus (SENT/FAILED/BOUNCED), responseCode, errorMessage, retryCount, deliveredAt                   |

### 3.2 値オブジェクト

| 値オブジェクト       | 説明                   | 不変性                                                                                                   |
| -------------------- | ---------------------- | -------------------------------------------------------------------------------------------------------- |
| NotificationType     | 通知種別（列挙）       | Yes, MESSAGE_RECEIVED/GROUP_CREATED/MEMORY_SHARED/MEMORY_LIKED/COMMENT_ADDED/FRIEND_ADDED/USER_MENTIONED |
| DeliveryChannel      | 配信チャネル（複数可） | Yes, PUSH/EMAIL/IN_APP                                                                                   |
| NotificationPriority | 優先度                 | Yes, HIGH/NORMAL/LOW                                                                                     |
| DevicePlatform       | デバイス OS            | Yes, iOS/Android/Web                                                                                     |
| FCMMessage           | FCM ペイロード         | Yes, title/body/customData/priority/ttl                                                                  |
| Email                | メール                 | Yes, toAddress/subject/htmlBody/textBody                                                                 |
| QuietHours           | 通知OFF時間帯          | Yes, startHour/endHour/timezone                                                                          |

### 3.3 ドメインルール / 不変条件

- NotificationPreference.pushEnabled = false の場合、当該ユーザーへのプッシュ配信を禁止
- NotificationPreference.emailFrequency = NEVER の場合、当該ユーザーへのメール配信を禁止
- DeviceToken.isValid = false の場合、そのトークンへの配信を試みない
- 同一ユーザー・同一 notificationType への24時間以内の重複通知は禁止（Redis で検証）
- QuietHours内でのプッシュ通知配信は禁止。ただしメール配信は可能
- Notification.status = PENDING の場合、配信待ち。失敗3回目で FAILED に遷移
- DeviceToken は最長1年の有効期限を持つ。期限切れトークンは自動削除対象
- 配信失敗時は自動的に QueuePort DLQ（Beta: asynq retry + DLQ / Prod: OCI Queue DLQ）に移動、最大3回の再試行

### 3.4 ドメインイベント

| イベント名              | 発火条件               | ペイロード                                                              |
| ----------------------- | ---------------------- | ----------------------------------------------------------------------- |
| notification.created    | 通知作成成功           | notificationId, userId, notificationType, channels, priority, createdAt |
| notification.sent       | 配信成功               | notificationId, channel, sentAt                                         |
| notification.failed     | 配信失敗               | notificationId, channel, errorCode, retryCount                          |
| device_token.registered | デバイストークン登録   | deviceTokenId, userId, platform, registeredAt                           |
| device_token.revoked    | デバイストークン無効化 | deviceTokenId, userId, reason (INVALID/EXPIRED/USER_UNREGISTERED)       |
| preferences.updated     | 通知設定更新           | userId, notificationType, emailFrequency, pushEnabled, updatedAt        |
| notification.delivered  | ユーザーが受信         | notificationId, userId, deliveredAt                                     |

### 3.5 エンティティ定義

```go
// Domain Entities
package domain

import "time"

// Notification represents a notification to be sent
type Notification struct {
	NotificationID   string                // UUID
	UserID           string                // User to receive notification
	Title            string
	Body             string
	NotificationType NotificationType      // MESSAGE_RECEIVED, GROUP_CREATED, etc.
	DeliveryChannels []DeliveryChannel     // [PUSH, EMAIL, IN_APP]
	Priority         NotificationPriority  // HIGH, NORMAL, LOW
	Status           string                // PENDING, SENT, FAILED
	CreatedAt        time.Time
	ExpiresAt        time.Time
	Data             map[string]string     // Extra context
}

// DeviceToken represents a device push notification token
type DeviceToken struct {
	DeviceTokenID string       // UUID
	UserID        string
	DeviceID      string
	Platform      DevicePlatform
	TokenValue    string       // FCM token
	IsValid       bool
	LastUsedAt    time.Time
	RegisteredAt  time.Time
	ExpiresAt     time.Time
}

func (dt *DeviceToken) IsExpired(now time.Time) bool {
	return now.After(dt.ExpiresAt)
}

// NotificationPreference represents user's notification settings
type NotificationPreference struct {
	PreferenceID       string             // UUID
	UserID             string
	NotificationType   NotificationType
	EmailFrequency     string             // DAILY, WEEKLY, NEVER
	PushEnabled        bool
	InAppEnabled       bool
	QuietHoursStart    int                // 0-23
	QuietHoursEnd      int                // 0-23
	UpdatedAt          time.Time
}

func (np *NotificationPreference) CanSendPush() bool {
	return np.PushEnabled
}

func (np *NotificationPreference) CanSendEmail() bool {
	return np.EmailFrequency != "NEVER"
}

// NotificationLog represents a single delivery attempt
type NotificationLog struct {
	LogID            string    // UUID
	NotificationID   string
	Channel          DeliveryChannel
	DeliveryStatus   string    // SENT, FAILED, BOUNCED
	ResponseCode     int
	ErrorMessage     string
	RetryCount       int
	DeliveredAt      *time.Time
}

// Value Objects

type NotificationType string

const (
	MessageReceived NotificationType = "MESSAGE_RECEIVED"
	GroupCreated    NotificationType = "GROUP_CREATED"
	MemoryShared    NotificationType = "MEMORY_SHARED"
	MemoryLiked     NotificationType = "MEMORY_LIKED"
	CommentAdded    NotificationType = "COMMENT_ADDED"
	FriendAdded     NotificationType = "FRIEND_ADDED"
	UserMentioned   NotificationType = "USER_MENTIONED"
)

type DeliveryChannel string

const (
	ChannelPush   DeliveryChannel = "PUSH"
	ChannelEmail  DeliveryChannel = "EMAIL"
	ChannelInApp  DeliveryChannel = "IN_APP"
)

type NotificationPriority string

const (
	PriorityHigh   NotificationPriority = "HIGH"
	PriorityNormal NotificationPriority = "NORMAL"
	PriorityLow    NotificationPriority = "LOW"
)

type DevicePlatform string

const (
	PlatformiOS     DevicePlatform = "iOS"
	PlatformAndroid DevicePlatform = "Android"
	PlatformWeb     DevicePlatform = "Web"
)

type QuietHours struct {
	StartHour int    // 0-23
	EndHour   int    // 0-23
	Timezone  string
}

func (qh *QuietHours) IsInQuietHours(now time.Time) bool {
	hour := now.Hour()
	if qh.StartHour < qh.EndHour {
		return hour >= qh.StartHour && hour < qh.EndHour
	}
	// Spans midnight
	return hour >= qh.StartHour || hour < qh.EndHour
}
```

---

## 4. ユースケース層（アプリケーション）

### 4.1 ユースケース一覧

| ユースケース                 | アクター           | 説明                                                                          | 優先度 |
| ---------------------------- | ------------------ | ----------------------------------------------------------------------------- | ------ |
| SendNotification             | System (QueuePort) | QueuePort (Beta: Redis+BullMQ / Prod: OCI Queue) イベントから通知を作成・配信 | HIGH   |
| RegisterDeviceToken          | Mobile App         | デバイストークンを登録/更新                                                   | HIGH   |
| UpdateNotificationPreference | User               | 通知設定を変更                                                                | HIGH   |
| MarkAsRead                   | User               | 通知を既読に                                                                  | MEDIUM |
| GetUnreadCount               | User               | 未読通知数を取得                                                              | MEDIUM |
| RevokeDeviceToken            | System             | デバイストークンを無効化                                                      | MEDIUM |
| ListNotifications            | User               | 通知一覧を取得                                                                | MEDIUM |
| RetryFailedNotifications     | Admin              | 失敗通知を再試行                                                              | LOW    |

### 4.2 ユースケース定義（コードスケッチ）

```go
// Application layer - Use Cases

package usecase

type SendNotificationInput struct {
	UserID               string
	NotificationType     NotificationType
	Title                string
	Body                 string
	Data                 map[string]string
	Priority             NotificationPriority
}

type SendNotificationOutput struct {
	NotificationID       string
	ChannelsQueued       []DeliveryChannel
}

type SendNotificationUseCase struct {
	notificationRepo     NotificationRepository
	deviceTokenRepo      DeviceTokenRepository
	preferenceRepo       PreferenceRepository
	pushGateway          PushGateway        // FCMPushAdapter
	emailGateway         MailPort           // PostfixSMTPAdapter (Postfix + Dovecot + Rspamd)
	dedupeCache          Cache              // Redis (CachePort)
	eventPublisher       EventPublisher
}

func (uc *SendNotificationUseCase) Execute(ctx context.Context, in SendNotificationInput) (*SendNotificationOutput, error) {
	// 1. 重複排除チェック (Redis)
	dedupeKey := fmt.Sprintf("notif:dedup:%s:%s", in.UserID, in.NotificationType)
	if uc.dedupeCache.Get(dedupeKey) != nil {
		return nil, errors.New("duplicate notification within 24h")
	}

	// 2. ユーザーの通知設定を取得
	pref, err := uc.preferenceRepo.FindByUserAndType(ctx, in.UserID, in.NotificationType)
	if err != nil {
		return nil, err
	}

	// 3. 配信チャネルを決定
	channels := uc.determineChannels(pref)
	if len(channels) == 0 {
		return nil, errors.New("user has disabled all notification channels")
	}

	// 4. Notification エンティティを作成
	notification := &Notification{
		NotificationID:   uuid.New().String(),
		UserID:           in.UserID,
		Title:            in.Title,
		Body:             in.Body,
		NotificationType: in.NotificationType,
		DeliveryChannels: channels,
		Priority:         in.Priority,
		Status:           "PENDING",
		CreatedAt:        time.Now(),
		ExpiresAt:        time.Now().AddDate(0, 0, 7), // 7 days
		Data:             in.Data,
	}

	// 5. DB に保存
	if err := uc.notificationRepo.Save(ctx, notification); err != nil {
		return nil, err
	}

	// 6. 各チャネルで配信処理を開始
	for _, ch := range channels {
		switch ch {
		case "PUSH":
			go uc.sendPush(ctx, notification)
		case "EMAIL":
			go uc.sendEmail(ctx, notification)
		case "IN_APP":
			go uc.saveInApp(ctx, notification)
		}
	}

	// 7. 重複排除キャッシュに記録
	uc.dedupeCache.Set(dedupeKey, "1", 24*time.Hour)

	// 8. イベント発行
	uc.eventPublisher.PublishNotificationCreated(notification)

	return &SendNotificationOutput{
		NotificationID: notification.NotificationID,
		ChannelsQueued: channels,
	}, nil
}

type RegisterDeviceTokenInput struct {
	UserID   string
	DeviceID string
	Platform DevicePlatform
	Token    string
}

type RegisterDeviceTokenOutput struct {
	DeviceTokenID string
	ExpiresAt     time.Time
}

type RegisterDeviceTokenUseCase struct {
	deviceTokenRepo DeviceTokenRepository
	cache           Cache
	eventPublisher  EventPublisher
}

func (uc *RegisterDeviceTokenUseCase) Execute(ctx context.Context, in RegisterDeviceTokenInput) (*RegisterDeviceTokenOutput, error) {
	// 1. 既存トークンを検索
	existing, err := uc.deviceTokenRepo.FindByToken(ctx, in.Token)
	if err == nil && existing != nil {
		// 既存: is_valid を true に、last_used_at を更新
		existing.IsValid = true
		existing.LastUsedAt = time.Now()
		if err := uc.deviceTokenRepo.Update(ctx, existing); err != nil {
			return nil, err
		}
		return &RegisterDeviceTokenOutput{
			DeviceTokenID: existing.DeviceTokenID,
			ExpiresAt:     existing.ExpiresAt,
		}, nil
	}

	// 2. 新規登録
	expiresAt := time.Now().AddDate(1, 0, 0) // 1年有効
	dt := &DeviceToken{
		DeviceTokenID: uuid.New().String(),
		UserID:        in.UserID,
		DeviceID:      in.DeviceID,
		Platform:      in.Platform,
		TokenValue:    in.Token,
		IsValid:       true,
		RegisteredAt:  time.Now(),
		ExpiresAt:     expiresAt,
	}
	if err := uc.deviceTokenRepo.Save(ctx, dt); err != nil {
		return nil, err
	}

	// 3. キャッシュに記録
	uc.cache.Set(fmt.Sprintf("device_token:%s", in.Token), "1", 1*time.Hour)

	// 4. イベント発行
	uc.eventPublisher.PublishDeviceTokenRegistered(dt)

	return &RegisterDeviceTokenOutput{
		DeviceTokenID: dt.DeviceTokenID,
		ExpiresAt:     dt.ExpiresAt,
	}, nil
}
```

---

## 5. ポート・アダプタ設計

### 5.1 ポート定義（インターフェース）

```go
// Ports (Application layer interfaces)

// OutboundPorts (データ出力)

type NotificationRepository interface {
	Save(ctx context.Context, notif *Notification) error
	FindByID(ctx context.Context, id string) (*Notification, error)
	UpdateStatus(ctx context.Context, id string, status string) error
	ListByUser(ctx context.Context, userID string, limit int, offset int) ([]*Notification, int, error)
}

type DeviceTokenRepository interface {
	Save(ctx context.Context, dt *DeviceToken) error
	Update(ctx context.Context, dt *DeviceToken) error
	FindByToken(ctx context.Context, token string) (*DeviceToken, error)
	FindByUserAndPlatform(ctx context.Context, userID string, platform DevicePlatform) ([]*DeviceToken, error)
	Delete(ctx context.Context, id string) error
	ListValidByUser(ctx context.Context, userID string) ([]*DeviceToken, error)
}

type PreferenceRepository interface {
	Save(ctx context.Context, pref *NotificationPreference) error
	Update(ctx context.Context, pref *NotificationPreference) error
	FindByUserAndType(ctx context.Context, userID string, notifType NotificationType) (*NotificationPreference, error)
	FindByUser(ctx context.Context, userID string) ([]*NotificationPreference, error)
}

type NotificationLogRepository interface {
	Save(ctx context.Context, log *NotificationLog) error
	FindByNotificationID(ctx context.Context, notifID string) ([]*NotificationLog, error)
}

// Gateway interfaces for external services

type PushGateway interface {
	SendPush(ctx context.Context, notification *Notification, deviceTokens []*DeviceToken) ([]string, error) // Returns token IDs sent
}

// MailPort (Postfix SMTP adapter を実装)
type MailPort interface {
	SendEmail(ctx context.Context, notification *Notification, toAddress string) error
}

type EventConsumer interface {
	ConsumeMessage(ctx context.Context, message interface{}) error
}

type EventPublisher interface {
	PublishNotificationCreated(notif *Notification) error
	PublishNotificationSent(notif *Notification, channel DeliveryChannel) error
	PublishNotificationFailed(notif *Notification, channel DeliveryChannel, reason string) error
	PublishDeviceTokenRevoked(dt *DeviceToken, reason string) error
	PublishPreferencesUpdated(pref *NotificationPreference) error
}

type Cache interface {
	Get(key string) (interface{}, error)
	Set(key string, value interface{}, ttl time.Duration) error
	Delete(key string) error
}
```

### 5.2 アダプタ実装

#### FCMPushAdapter (PushGateway 実装)

```go
// Adapters - External Services

package adapter

import (
	"context"
	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
)

type FCMPushAdapter struct {
	client *messaging.Client
}

func NewFCMPushAdapter(ctx context.Context, credentialsPath string) (*FCMPushAdapter, error) {
	opt := option.WithCredentialsFile(credentialsPath)
	app, err := firebase.NewApp(ctx, nil, opt)
	if err != nil {
		return nil, err
	}
	client, err := app.Messaging(ctx)
	if err != nil {
		return nil, err
	}
	return &FCMPushAdapter{client: client}, nil
}

func (fa *FCMPushAdapter) SendPush(ctx context.Context, notification *domain.Notification, deviceTokens []*domain.DeviceToken) ([]string, error) {
	var sentTokens []string
	for _, dt := range deviceTokens {
		if !dt.IsValid {
			continue
		}
		msg := &messaging.Message{
			Notification: &messaging.Notification{
				Title: notification.Title,
				Body:  notification.Body,
			},
			Data: notification.Data,
			Token: dt.TokenValue,
		}
		resp, err := fa.client.Send(ctx, msg)
		if err != nil {
			// Log failure, may add to retry queue
			continue
		}
		sentTokens = append(sentTokens, resp)
	}
	return sentTokens, nil
}
```

#### PostfixSMTPAdapter (MailPort 実装) { #postfixsmtpadapter-mailport-実装 }

メール送信はオンプレミス SMTP (Postfix + Dovecot + Rspamd) を使用する。Beta は XServer VPS、Prod は CoreServerV2 でホストする。AWS SES は **使用しない**。

```go
package adapter

import (
	"context"
	"crypto/tls"
	"fmt"
	"net/smtp"
	"strings"
)

type PostfixSMTPAdapter struct {
	host     string // e.g. "smtp.example.internal"
	port     int    // 587 (submission, STARTTLS)
	username string
	password string
	from     string // e.g. "no-reply@recerdo.example"
}

func NewPostfixSMTPAdapter(cfg SMTPConfig) *PostfixSMTPAdapter {
	return &PostfixSMTPAdapter{
		host: cfg.Host, port: cfg.Port,
		username: cfg.Username, password: cfg.Password, from: cfg.From,
	}
}

func (a *PostfixSMTPAdapter) SendEmail(ctx context.Context, notif *domain.Notification, toAddress string) error {
	_ = ctx

	addr := fmt.Sprintf("%s:%d", a.host, a.port)
	msg := []byte(
		"From: " + a.from + "\r\n" +
		"To: " + toAddress + "\r\n" +
		"Subject: " + notif.Title + "\r\n" +
		"Content-Type: text/plain; charset=UTF-8\r\n\r\n" +
		notif.Body + "\r\n",
	)

	c, err := smtp.Dial(addr)
	if err != nil {
		return err
	}
	defer c.Close()

	ok, _ := c.Extension("STARTTLS")
	if !ok {
		return fmt.Errorf("smtp server %s does not support STARTTLS", addr)
	}

	tlsConfig := &tls.Config{ServerName: a.host}
	if err := c.StartTLS(tlsConfig); err != nil {
		return err
	}

	if a.username != "" || a.password != "" {
		auth := smtp.PlainAuth("", a.username, a.password, a.host)
		if ok, _ := c.Extension("AUTH"); ok {
			if err := c.Auth(auth); err != nil {
				return err
			}
		}
	}

	if err := c.Mail(a.from); err != nil {
		return err
	}
	if err := c.Rcpt(toAddress); err != nil {
		return err
	}

	w, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(msg); err != nil {
		w.Close()
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}

	if err := c.Quit(); err != nil && !strings.Contains(err.Error(), "use of closed network connection") {
		return err
	}

	return nil
	}
	defer c.Close()

	if ok, _ := c.Extension("STARTTLS"); !ok {
		return fmt.Errorf("smtp server %s does not advertise STARTTLS", addr)
	}
	if err := c.StartTLS(&tls.Config{
		ServerName: a.host,
		MinVersion: tls.VersionTLS12,
	}); err != nil {
		return err
	}

	auth := smtp.PlainAuth("", a.username, a.password, a.host)
	if err := c.Auth(auth); err != nil {
		return err
	}
	if err := c.Mail(a.from); err != nil {
		return err
	}
	if err := c.Rcpt(toAddress); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(msg); err != nil {
		_ = w.Close()
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}
```

- SPF / DKIM / DMARC は DNS 側で設定（Postfix + Rspamd で署名）
- 送信ログは Postfix の mail.log / Rspamd の統計を Loki / Promtail で集約
- バウンス処理は Dovecot + ローカル bounce メールキューで監視

### 5.3 PostfixSMTP 利用条件

FCM-primary 設計に基づき、PostfixSMTP（メール通知）を使用するのは以下の条件に該当する場合のみとする。通常の活動通知（メッセージ、コメント、思い出シェア等）は FCM + IN_APP チャネルで完結させる。

| 条件                                        | 説明                                                       | 実装上の判断基準                                                                                            |
| ------------------------------------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **1. セキュリティ・認証通知**               | パスワードリセット、メールアドレス確認、不審なログイン通知 | NotificationType = SECURITY_ALERT / ACCOUNT_VERIFICATION のみ。FCM到達の有無に関わらず送信                  |
| **2. FCMトークン未登録ユーザー**            | モバイルアプリ未インストールまたはOS通知権限拒否のユーザー | `device_tokens` テーブルに `is_valid=true` のレコードが存在しない場合                                       |
| **3. FCM配信連続失敗のフォールバック**      | HIGH priority 通知がFCMで3回連続失敗                       | `NotificationLog.retry_count >= 3` かつ `priority = HIGH` かつ `channel = PUSH`。NORMAL/LOW には適用しない  |
| **4. 法的・規約変更通知**                   | 利用規約変更、プライバシーポリシー改定、アカウント強制停止 | NotificationType = LEGAL_NOTICE / ACCOUNT_SUSPENDED。証跡として Postfix 送信ログ / メールサーバーログを利用 |
| **5. ユーザー明示オプトインのダイジェスト** | 週次・月次まとめメールをユーザーが明示設定した場合のみ     | `NotificationPreference.email_frequency = DAILY \| WEEKLY` かつ `email_opt_in = true`（デフォルト false）   |

> **設計原則**: PostfixSMTP はデフォルト通知チャネルではなく「例外チャネル」として扱う。`SendNotificationUseCase` はチャネル決定時に上記 5 条件をチェックし、該当しない場合は EMAIL チャネルをスキップする。AWS SES / SendGrid などのクラウドメール送信サービスは利用しない。

#### QueueEventConsumerAdapter (QueuePort Consumer)

QueuePort の Consumer 実装。Beta は Redis + BullMQ / asynq、Prod は OCI Queue。AWS SQS は **使用しない**。

```go
package adapter

import (
	"context"
	"encoding/json"

	"github.com/hibiken/asynq"
	ociqueue "github.com/oracle/oci-go-sdk/v65/queue"
)

// ---- Beta: Redis + asynq 実装 ----
type RedisQueueConsumerAdapter struct {
	server           *asynq.Server
	sendNotification usecase.SendNotificationUseCase
}

func NewRedisQueueConsumerAdapter(redisAddr string, uc usecase.SendNotificationUseCase) *RedisQueueConsumerAdapter {
	srv := asynq.NewServer(
		asynq.RedisClientOpt{Addr: redisAddr},
		asynq.Config{Concurrency: 10, Queues: map[string]int{"notifications": 10}},
	)
	return &RedisQueueConsumerAdapter{server: srv, sendNotification: uc}
}

func (a *RedisQueueConsumerAdapter) Start(ctx context.Context) error {
	mux := asynq.NewServeMux()
	mux.HandleFunc("notification:send", func(ctx context.Context, t *asynq.Task) error {
		var in usecase.SendNotificationInput
		if err := json.Unmarshal(t.Payload(), &in); err != nil {
			return err
		}
		_, err := a.sendNotification.Execute(ctx, in)
		return err
	})
	return a.server.Run(mux)
}

// ---- Prod: OCI Queue 実装 ----
type OCIQueueConsumerAdapter struct {
	client           ociqueue.QueueClient
	queueID          string
	sendNotification usecase.SendNotificationUseCase
}

func (a *OCIQueueConsumerAdapter) ConsumeMessages(ctx context.Context) {
	for {
		resp, err := a.client.GetMessages(ctx, ociqueue.GetMessagesRequest{
			QueueId: &a.queueID,
		})
		if err != nil {
			continue
		}
		for _, msg := range resp.Messages {
			var in usecase.SendNotificationInput
			if err := json.Unmarshal([]byte(*msg.Content), &in); err != nil {
				continue
			}
			if _, err := a.sendNotification.Execute(ctx, in); err != nil {
				continue // DLQ に自動移動される
			}
			_, _ = a.client.DeleteMessage(ctx, ociqueue.DeleteMessageRequest{
				QueueId:   &a.queueID,
				MessageReceipt: msg.Receipt,
			})
		}
	}
}
```

> **削除済み**: `SQSEventConsumerAdapter`（AWS SQS）は本サービスから除外。AWS SDK (`aws-sdk-go-v2/service/sqs`) への依存は排除する。

#### MySQLNotificationRepository

```go
package adapter

import (
	"context"
	"database/sql"
	"encoding/json"

	_ "github.com/go-sql-driver/mysql"
)

// MySQL 8.x / MariaDB 10.6+ 互換
type MySQLNotificationRepository struct {
	db *sql.DB
}

func (repo *MySQLNotificationRepository) Save(ctx context.Context, notif *domain.Notification) error {
	query := `INSERT INTO notifications (notification_id, user_id, title, body, notification_type, delivery_channels, priority, status, created_at, expires_at, data)
	          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	channelsJSON, _ := json.Marshal(notif.DeliveryChannels) // JSON 型カラム
	dataJSON, _ := json.Marshal(notif.Data)
	_, err := repo.db.ExecContext(ctx, query,
		notif.NotificationID, notif.UserID, notif.Title, notif.Body, notif.NotificationType,
		channelsJSON, notif.Priority, notif.Status, notif.CreatedAt, notif.ExpiresAt, dataJSON,
	)
	return err
}
```

---

## 6. テスト戦略

### 6.1 単体テスト (ユースケース層)

各ユースケースは、リポジトリ・ゲートウェイをモック化してテスト。

```go
// Unit test example: SendNotificationUseCase

func TestSendNotification_WithPushEnabled(t *testing.T) {
	// Arrange
	mockNotificationRepo := &MockNotificationRepository{}
	mockDeviceTokenRepo := &MockDeviceTokenRepository{}
	mockPushGateway := &MockPushGateway{}
	mockCache := &MockCache{}
	
	uc := &SendNotificationUseCase{
		notificationRepo: mockNotificationRepo,
		deviceTokenRepo: mockDeviceTokenRepo,
		pushGateway: mockPushGateway,
		dedupeCache: mockCache,
	}

	in := SendNotificationInput{
		UserID: "user123",
		NotificationType: "MESSAGE_RECEIVED",
		Title: "New message",
		Body: "Hello from Alice",
	}

	// Act
	out, err := uc.Execute(context.Background(), in)

	// Assert
	assert.NoError(t, err)
	assert.NotNil(t, out)
	assert.Equal(t, out.NotificationID, mockNotificationRepo.LastSaved.NotificationID)
	mockPushGateway.AssertSendPushCalled()
}
```

### 6.2 統合テスト

REST API、QueuePort 消費（Redis / OCI Queue）、MySQL (MariaDB 互換) DB、外部サービス（モック）を統合テスト。

### 6.3 E2E テスト

実際の FCM、PostfixSMTP（ローカル MailHog / Postfix コンテナ）、QueuePort（ローカル Redis / OCI Queue）を使用した端-端テスト。

---

## 7. デプロイ・運用

- **コンテナ化**: Docker イメージ、Beta は XServer VPS + docker-compose、Prod は OCI Container Instances / OKE にデプロイ
- **スケーリング**: Beta は手動スケール、Prod は OCI のメトリクスベース Auto Scaling
- **モニタリング**: Prometheus + Grafana（Beta）、OCI Monitoring + Grafana（Prod）。ログは Loki / Promtail
- **ローリングデプロイ**: Traefik (Beta) / OCI Load Balancer (Prod)、ヘルスチェック（/health エンドポイント）
- **Database Migrations**: goose (MySQL / MariaDB 対応)

## 8. 将来の拡張

- SMS 通知チャネルの追加（Postfix と同様にオンプレ SMS ゲートウェイ経由）
- Webhook トリガー（ユーザー定義フロー）
- A/B テスト（通知テンプレート最適化）
- 最適配信時間の統計的最適化（ルールベース、ML は使用しない）

## 9. 横断標準の適用（追加設計プラン反映）

[基本的方針（Policy）§8](../core/policy.md#8-大規模類似サービス参照反復版) および [clean-architecture/index.md 横断パターン](index.md#横断パターン) の適用状況を明示する。

| 標準                     | 本サービスでの反映                                                                                                                                                                                  |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Idempotency Key**      | `IdempotencyMiddleware` が `Idempotency-Key` を読み、`IdempotencyStore`（Redis）で 24h 保持。`SendNotificationUseCase` は冪等性を意識せず、副作用は Outbox で整合。                                 |
| **Transactional Outbox** | `SendNotificationUseCase` は `NotificationRepository.Save` と `EventPublisherPort.Publish(NotificationSent\|Failed)` を同一トランザクションで実行。QueuePort への転送は別プロセスのポーラーが担当。 |
| **Saga (Choreography)**  | `memory.shared` / `comment.added` 受信 → UseCase 実行 → `notification.sent` を Outbox に書く。失敗時は `notification.failed` を発行し、admin-console-svc が取り扱う。                               |
| **Circuit Breaker**      | `FCMPushAdapter` と `PostfixSMTPAdapter` を `gobreaker.CircuitBreaker` でラップ。Open 中は Port から `ErrCircuitOpen` を返し、UseCase は一時的失敗として扱う。                                      |
| **OpenTelemetry**        | `context.Context` にスパン伝播。Port 境界（`PushPort.Send`、`MailPort.SendEmail`、`EventPublisherPort.Publish`）でスパンを作成し `traceparent` を付与。本文・PII はスパン属性に含めない。           |
| **SLO**                  | Notification 作成 → FCM Sent の 95%tile < 60s、PostfixSMTP 送信 95%tile < 10s、配信成功率 >= 99.0%（30 日ローリング）。                                                                             |
| **SMTP 最低要件**        | `PostfixSMTPAdapter` は STARTTLS 広告確認 → TLS 1.2+ 昇格 → AUTH 拡張確認後のみ `PlainAuth`。未広告時はエラーを返す（平文 AUTH / 平文配送を禁止）。                                                 |

### 反映のための設計原則

1. **横断標準は Port のインタフェース定義として残す**。UseCase / Entity は実装詳細を知らない。
2. **Adapter 層で横断標準の実装を提供**。Beta / Prod の差異は Adapter 切替で吸収する。
3. **Framework 層のラッパでメトリクス・トレース・リトライを注入**。UseCase のコードを汚さない。
4. **失敗時の責務は UseCase が明示**。`*Failed` ドメインイベントと補償処理は UseCase に記述する。

## 14. 変更履歴・レビュー記録（追加設計プラン反映）

### 14.1 適用した横断標準（[clean-architecture/index.md 横断パターン](index.md#横断パターン) 参照）

| パターン                 | 本サービスにおける実装ポイント                                                                                                                                                                            |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Idempotency Key**      | Controller 前段の `IdempotencyMiddleware` が `Idempotency-Key` ヘッダを読み、`IdempotencyStore`（Redis）に問合せ。`SendNotificationUseCase` は冪等性を意識せず、副作用は Outbox 経由で整合を担保。        |
| **Transactional Outbox** | `SendNotificationUseCase` は `NotificationRepository.Save` と `EventPublisherPort.Publish(NotificationSent\|Failed)` を **同一トランザクション** で実行。QueuePort への転送は Publisher（ポーラ）が担う。 |
| **Saga (Choreography)**  | `memory.shared` / `comment.added` 等を受信 → ユースケース実行 → `notification.sent` を Outbox に書く。配信失敗時は `notification.failed` を発行し、admin-console-svc が取り扱う。                         |
| **Circuit Breaker**      | `FCMPushAdapter` と `PostfixSMTPAdapter` を `gobreaker.CircuitBreaker` でラップ。Open 中は Port から `ErrCircuitOpen` を返し、UseCase は一時的失敗として扱う。                                            |
| **OpenTelemetry**        | `context.Context` にスパン伝播。Port 境界（`PushPort.Send`、`MailPort.SendEmail`、`EventPublisherPort.Publish`）でスパンを作成し `traceparent` を付与。本文・PII はスパン属性に含めない。                 |
| **SLO**                  | Notification 作成 → FCM Sent の 95%tile < 60s、PostfixSMTP 送信 95%tile < 10s、配信成功率 >= 99.0%（30 日ローリング）。                                                                                   |
| **SMTP 最低要件**        | `PostfixSMTPAdapter` は STARTTLS 広告確認 → TLS 1.2+ 昇格 → AUTH 拡張確認後のみ `PlainAuth`。未広告時はエラーを返す（平文 AUTH / 平文配送を禁止）。                                                       |

### 14.2 レビュー指摘の反映履歴

| 日付       | 出所                               | 指摘                                                       | 反映                                                                                                                                                                                   |
| ---------- | ---------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-04-19 | PR #6 Copilot Autofix（`56a90bc`） | Postfix SMTP で STARTTLS が明示要求されていない            | §5.2 `PostfixSMTPAdapter` に STARTTLS 広告確認 + TLS 1.2+ 昇格 + AUTH 拡張確認を実装                                                                                                   |
| 2026-04-19 | 上記の Autofix 継続                | Autofix 適用時にコード重複（2 つの実装が並存）が残存       | 本反復で重複を除去し、単一の安全実装に統一                                                                                                                                             |
| 2026-04-19 | 横断レビュー（`464267` マージ後）  | PostfixSMTP 利用条件が MS / CA で表現が異なる              | `5.3 PostfixSMTP 利用条件` と [microservice/notifications-svc.md のメール通知条件](../microservice/notifications-svc.md#メール通知条件) の表を 5 条件で揃え、policy.md §8.1 へもリンク |
| 2026-04-19 | 追加設計プラン反復                 | 横断標準（Idempotency / Outbox / Saga / CB / SLO）が未反映 | 本 §14 と [clean-architecture/index.md 横断パターン](index.md#横断パターン) を追加                                                                                                     |

### 14.3 残課題

- 将来的な **E2E 暗号化** 導入時に CAS / 重複排除が無効化されるため、storage-svc と併せて Flag 設計を詰める必要がある。
- `PostfixSMTPAdapter` の `net/smtp` は `context` 非対応のため、長時間ブロックを避けるためのデッドライン制御（`net.Dialer.DialContext` でのソケット層タイムアウト）を別途実装する。

---

最終更新: 2026-04-19 ポリシー適用（追加設計プラン反映）
