# 通知サービス (recerdo-notifications)

**作成者**: Claude (AI) · **作成日**: 2026-04-15 · **ステータス**: 提案 (Proposal)

---

## 1. 概要

### 目的

Recuerdoアプリケーションのプッシュ通知・アプリ内通知・メール通知を一元管理するマイクロサービス。Messaging Service、Events Service、Album Service からのイベントを **QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）** 経由で受け取り、ユーザーの通知設定に基づいて **FCM（Firebase Cloud Messaging）を主軸としたプッシュ通知** を配信する。メール通知は **CoreServerV2 上の Postfix + Dovecot + Rspamd（SPF / DKIM / DMARC 構成済み）** を `MailPort`（実装 `PostfixSMTPAdapter`）経由で利用し、セキュリティ要件・FCMトークン未登録ユーザー・法的通知など特定条件下でのみ送信する（詳細は [メール通知条件](#mail-notification-conditions) を参照）。**AWS SES / SQS / SNS / CloudWatch / Lambda / ECS / ElastiCache / Secrets Manager は使用しない。利用する AWS サービスは Cognito のみ**（[基本的方針](../core/policy.md) 参照）。デバイストークン管理、通知履歴追跡、配信状態管理、重複排除をサポートする。

### ビジネスコンテキスト

解決する問題:
- 複数のマイクロサービスが通知ロジックを分散して管理しており、ユーザー通知設定の一貫性が保証されない
- プッシュ通知・メール通知を統一的に管理するサービスがなく、デバイストークン更新・失効処理が手作業
- 通知の配信状態を追跡できず、再試行・失敗時のリカバリが不十分
- 大量の通知でコストが増加しており、低コスト配信方法の検討が必要
- ユーザーがオフラインで受け取ることができない通知があり、ユーザー体験が低下

Key User Stories:
- iOSアプリユーザーとして、グループの思い出が追加されたときにプッシュ通知を受け取りたい
- ユーザーとして、メール通知の頻度（毎日・毎週・なし）を設定したい
- Messaging Serviceとして、メッセージ送信時に相手ユーザーにプッシュ通知を送信したいが、自分で通知ロジックを持ちたくない
- 通知設定管理者として、ユーザーのデバイストークンが失効したときに自動的に削除し、配信エラーを最小化したい
- オフラインユーザーとして、再度ログインしたときに、オフライン中に受け取るべきだった通知をアプリ内で見たい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ           | 説明                           | 主要属性                                                                                                                                                                                          |
| ---------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Notification           | 送信された通知レコード         | notification_id (UUID), user_id, title, body, notification_type, delivery_channels (PUSH/EMAIL/IN_APP), priority (HIGH/NORMAL/LOW), status (PENDING/SENT/FAILED), created_at, sent_at, expires_at |
| DeviceToken            | ユーザーのデバイス登録トークン | device_token_id (UUID), user_id, device_id, platform (iOS/Android), token_value, is_valid, last_used_at, registered_at, expires_at                                                                |
| NotificationPreference | ユーザーの通知設定             | preference_id (UUID), user_id, notification_type, email_frequency (DAILY/WEEKLY/NEVER), push_enabled (bool), in_app_enabled (bool), quiet_hours_start, quiet_hours_end, updated_at                |
| NotificationLog        | 通知配信ログ                   | log_id (UUID), notification_id, channel (PUSH/EMAIL/IN_APP), delivery_status (SENT/FAILED/BOUNCED), response_code, error_message, delivered_at, retry_count                                       |
| NotificationTemplate   | 通知テンプレート               | template_id (UUID), template_key, title_template, body_template, variables[], created_at                                                                                                          |

### 値オブジェクト

| 値オブジェクト       | 説明                          | バリデーションルール                                                                                               |
| -------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| NotificationType     | 通知の種別                    | MESSAGE_RECEIVED, GROUP_CREATED, MEMORY_SHARED, MEMORY_LIKED, COMMENT_ADDED, FRIEND_ADDED, USER_MENTIONED (列挙型) |
| DeliveryChannel      | 配信チャネル                  | PUSH (FCM), EMAIL (Postfix + Dovecot + Rspamd on CoreServerV2), IN_APP (アプリ内メッセージ) (複数選択可)           |
| NotificationPriority | 通知の優先度                  | HIGH (即座配信), NORMAL (通常), LOW (まとめて配信)                                                                 |
| DevicePlatform       | デバイスプラットフォーム      | iOS, Android, Web (値オブジェクト)                                                                                 |
| FCMMessage           | FCMに送信するペイロード       | title, body, custom_data, priority, ttl                                                                            |
| SMTPEmail            | Postfix SMTP に送信するメール | to_address, subject, html_body, text_body, dkim_selector（DKIM 署名は Postfix + OpenDKIM / Rspamd が付与）         |
| QuietHours           | ユーザーの通知OFF時間帯       | start_hour (0-23), end_hour (0-23)、タイムゾーン対応                                                               |

### ドメインルール / 不変条件

- ユーザーが通知を受け取りたくない場合（preference_id で PUSH_ENABLED=false等）、そのチャネルで配信してはならない
- DeviceTokenの有効期限が切れた場合、そのトークンへの配信を試みてはならない
- プッシュ通知は同一ユーザーへの同一内容の重複配信を24時間以内で禁止しなければならない（重複排除）
- 通知が PENDING の場合、QueuePort（Beta: BullMQ failed queue / asynq archived queue、本番: OCI Queue DLQ）で再試行する。最大 3 回失敗したら FAILED 状態に遷移する
- 通知設定が「NEVER」の場合、そのユーザーへのメール・プッシュ配信を一切行わない
- 静穏時間帯（quiet_hours_start～end）内の通知は、メールは送信可能だが、プッシュ通知は送信してはならない
- オフラインユーザー向けの通知は自動的にIN_APP チャネルに保存し、再度ログイン時に通知インボックスで表示する必要がある
- デバイストークンは有効期限（最大1年）を持ち、期限切れトークンは自動削除の対象

### ドメインイベント

| イベント              | トリガー                     | 主要ペイロード                                                        |
| --------------------- | ---------------------------- | --------------------------------------------------------------------- |
| NotificationCreated   | 通知作成時                   | notification_id, user_id, notification_type, channels, priority       |
| NotificationSent      | 配信成功時                   | notification_id, channel, sent_at                                     |
| NotificationFailed    | 配信失敗時                   | notification_id, channel, error_code, retry_count                     |
| DeviceTokenRegistered | デバイストークン登録時       | device_token_id, user_id, platform, registered_at                     |
| DeviceTokenRevoked    | デバイストークン失効時       | device_token_id, user_id, reason (INVALID/EXPIRED/USER_UNREGISTERED)  |
| PreferencesUpdated    | 通知設定変更時               | user_id, notification_type, email_frequency, push_enabled, updated_at |
| NotificationDelivered | ユーザーが通知を受け取った時 | notification_id, user_id, channel, delivered_at                       |

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース             | 入力DTO                                                                                        | 出力DTO                                                    | 説明                               |
| ------------------------ | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ---------------------------------- |
| SendNotification         | SendNotificationInput{user_id, notification_type, title, body, data, priority}                 | SendNotificationOutput{notification_id, channels_queued[]} | QueuePort メッセージから通知を送信 |
| RegisterDeviceToken      | RegisterDeviceTokenInput{user_id, device_id, platform, token_value}                            | RegisterDeviceTokenOutput{device_token_id, expires_at}     | デバイストークン登録               |
| UpdatePreferences        | UpdatePreferencesInput{user_id, notification_type, email_frequency, push_enabled, quiet_hours} | UpdatePreferencesOutput{preference_id, updated_at}         | 通知設定更新                       |
| MarkAsRead               | MarkAsReadInput{user_id, notification_id}                                                      | MarkAsReadOutput{read_count}                               | 通知を既読に                       |
| GetUnreadCount           | GetUnreadCountInput{user_id}                                                                   | GetUnreadCountOutput{count}                                | 未読通知数取得                     |
| RevokeDeviceToken        | RevokeDeviceTokenInput{device_token_id, reason}                                                | RevokeDeviceTokenOutput{revoked}                           | トークン無効化                     |
| ListNotifications        | ListNotificationsInput{user_id, limit, offset}                                                 | ListNotificationsOutput{notifications[], total_count}      | ユーザーの通知一覧取得             |
| RetryFailedNotifications | RetryFailedNotificationsInput{notification_id?, max_retries}                                   | RetryFailedNotificationsOutput{retried_count}              | 失敗通知の再試行                   |

### ユースケース詳細（主要ユースケース）

#### SendNotification — 主要ユースケース詳細

**トリガー**: Messaging Service、Events Service、Album Service から通知イベントを QueuePort 経由で受信（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）

**フロー**:
1. QueuePort からメッセージを Consume
2. NotificationType に基づいて、ユーザーの NotificationPreference を検索
3. 有効な配信チャネル（PUSH/EMAIL/IN_APP）を特定
4. 重複排除ロジック（Redis）で24時間以内の同一内容通知をチェック
5. 各チャネルに対して配信タスクをキュー
6. FCM（プッシュ通知）: DeviceToken が有効な全 iOS/Android デバイスに送信
7. Postfix SMTP（メール通知）: `MailPort.SendMail` 経由で CoreServerV2 Postfix に投函。DKIM 署名は OpenDKIM / Rspamd が付与、SPF / DMARC は DNS 側で設定済み
8. IN_APP 通知: アプリ内通知テーブルに記録
9. 配信ログ記録
10. 失敗時は QueuePort の DLQ（Beta: BullMQ failed queue / asynq archived queue、本番: OCI Queue DLQ）に移動し、3 回まで自動再試行

**制約**:
- 静穏時間帯内のプッシュ通知は送信しない
- preference.push_enabled = false の場合、プッシュ通知を送信しない
- preference.email_frequency = NEVER の場合、メール通知を送信しない

#### RegisterDeviceToken

**トリガー**: iOSアプリでユーザーが初回ログイン時、またはFCMトークン更新時

**フロー**:
1. device_token_valueが既存かチェック
2. 既存：is_valid=true に更新、last_used_at更新
3. 新規：新しいdevice_token_idで登録、有効期限を1年後に設定
4. DeviceTokenRegisteredイベント発火

#### UpdatePreferences

**トリガー**: ユーザーが通知設定ページで設定を変更

**フロー**:
1. NotificationPreferenceを更新
2. email_frequency、push_enabled、quiet_hoursを新値に設定
3. PreferencesUpdatedイベント発火

## 4. インフラ層

### 外部サービス連携

#### Firebase Cloud Messaging (FCM)
- **用途**: プッシュ通知（iOS/Android）
- **コスト**: 無料、無制限
- **実装**: google-cloud-go ライブラリ
- **特徴**: 
  - クロスプラットフォーム対応（iOS/Android）
  - TTL（Time To Live）設定でオフライン時も配信可能
  - 配信成功率の自動トラッキング

#### Postfix + Dovecot + Rspamd（CoreServerV2 上で運用）
- **用途**: メール通知（条件付き利用 — 後述の [メール通知条件](#mail-notification-conditions) を参照）
- **コスト**: CoreServerV2 CORE+X（6GB）契約に含まれる（追加コスト $0）
- **実装**: `MailPort` → `PostfixSMTPAdapter`（Go: `net/smtp` + `mail` パッケージ、TLS STARTTLS 必須）
- **構成**:
  - **Postfix**: SMTP リレー / 配送 MTA（25 / 587 / submission）
  - **Dovecot**: IMAP / POP3 / LMTP（受信・バウンス取り込み用）
  - **Rspamd**: スパム検知・DKIM 署名（OpenDKIM との二重化も可）
- **認証・なりすまし対策**:
  - **SPF**: `v=spf1 mx a:mail.recuerdo.example ~all` を送信元ドメイン DNS に設定
  - **DKIM**: Rspamd の `dkim_signing` モジュールで 2048bit 鍵署名（セレクタ `recuerdo._domainkey`）
  - **DMARC**: `v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@recuerdo.example`
- **特徴**:
  - テンプレート管理はアプリ側（Go `text/template` + `html/template`）で実装
  - バウンス処理: Rspamd + Dovecot LMTP が受信した DSN を `BounceHandler` ワーカーが QueuePort 経由で消費し、`DeviceTokenRevoked` / `EmailInvalidated` をパブリッシュ
  - 配送状態は Postfix `maillog` → Loki へ転送し Grafana で可視化

#### メール通知条件 {#mail-notification-conditions}

FCM を主軸とした設計とし、メール（Postfix）送信は以下の条件に該当する場合にのみ利用する。

| 条件                                     | 説明                                                             | 判断基準                                                                                           |
| ---------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **1. セキュリティ・認証関連通知**        | パスワードリセット、メールアドレス確認、不審なログイン検知など   | FCMデバイスが使えない状況でも確実な通達が必要。セキュリティ上、プッシュのみでは不十分              |
| **2. FCMトークン未登録ユーザー**         | モバイルアプリ未インストール、またはOS通知権限を拒否したユーザー | DeviceToken レコードが存在しない、もしくは全て is_valid=false の場合                               |
| **3. FCM配信連続失敗時のフォールバック** | FCMによるプッシュ配信が3回連続失敗した重要通知                   | NotificationLog.retry_count >= 3 かつ priority = HIGH の場合。通常・低優先通知には適用しない       |
| **4. 法的・規約変更通知**                | 利用規約変更、プライバシーポリシー改定、アカウント強制停止通知   | 法令遵守・証跡確保のため、記録可能な通達手段が必須。メールは監査ログと連動                         |
| **5. 週次・月次ダイジェストメール**      | ユーザーが「まとめメール受信」を明示的に設定した場合のみ         | NotificationPreference.email_frequency = DAILY または WEEKLY、かつユーザーが明示的にオプトイン済み |

> **設計方針**: 上記 5 条件に該当しない通常の活動通知（メッセージ受信、思い出シェア、コメント等）は FCM プッシュ + IN_APP のみで配信する。Postfix メール送信を「デフォルト通知チャネル」として扱わないことで、運用コストとスパムリスク、およびレピュテーション低下リスクを最小化する。

#### QueuePort（Beta: Redis + BullMQ / asynq、本番: OCI Queue Service）
- **用途**: イベント駆動の非同期通知キューイング
- **Beta コスト**: Redis（XServer VPS 共用）運用費のみ
- **本番コスト**: OCI Queue Service 従量課金（リクエスト + データ量）
- **実装**: `QueuePort` → `RedisBullMQAdapter` / `AsynqAdapter`（Beta）/ `OCIQueueAdapter`（本番）、`infra/queue/*_adapter.go`
- **特徴**:
  - DLQ（BullMQ failed queue / asynq archived queue / OCI Queue DLQ）による失敗通知管理
  - 可視性タイムアウト（デフォルト 300 秒）で再試行制御
  - 複数のイベントソース（Messaging、Events、Album、Auth、admin-console-svc）対応
  - AWS SQS / SNS は [基本的方針](../core/policy.md) により不使用

#### MySQL 8.0 / MariaDB 10.11
- **Beta**: XServer VPS 上の MySQL 8.0 / MariaDB 10.11（go-sql-driver/mysql、互換性を CI でテスト）
- **本番**: OCI MySQL HeatWave
- **用途**: Notification、DeviceToken、NotificationPreference、NotificationLog永続化
- **テーブル**:
  - notifications (id, user_id, type, title, body, priority, status, created_at)
  - device_tokens (id, user_id, device_id, platform, token_value, is_valid, expires_at)
  - notification_preferences (id, user_id, notification_type, email_frequency, push_enabled, in_app_enabled, quiet_hours_start, quiet_hours_end)
  - notification_logs (id, notification_id, channel, status, error_message, retry_count, delivered_at)

#### Redis 7.x
- **Beta**: XServer VPS 共用
- **本番**: OCI Cache with Redis
- **用途**: 
  - 重複排除キャッシュ（24時間TTL）
  - デバイストークン有効性キャッシュ
  - レート制限（ユーザーあたり通知数上限）
- **キー設計**:
  - `notification:dedup:{user_id}:{notification_type}` → 最後の送信時刻
  - `device_token:valid:{token_value}` → キャッシュ（1時間TTL）

### インターフェース層

#### REST API Endpoints

| エンドポイント                                         | 方法   | 説明                   |
| ------------------------------------------------------ | ------ | ---------------------- |
| POST /api/notifications/register-device                | POST   | デバイストークン登録   |
| PUT /api/notifications/preferences/{notification_type} | PUT    | 通知設定更新           |
| GET /api/notifications/preferences                     | GET    | 全通知設定取得         |
| GET /api/notifications                                 | GET    | 通知一覧取得           |
| PUT /api/notifications/{notification_id}/read          | PUT    | 通知を既読に           |
| DELETE /api/notifications/device/{device_token_id}     | DELETE | デバイストークン削除   |
| GET /api/notifications/unread-count                    | GET    | 未読通知数取得         |
| POST /api/notifications/{notification_id}/retry        | POST   | 配信再試行（管理者用） |

## 5. QueuePort イベント処理

### 消費するイベント（他サービスから、QueuePort トピック）

| イベントタイプ    | 送信元            | ペイロード例                                           | 通知タイプ       |
| ----------------- | ----------------- | ------------------------------------------------------ | ---------------- |
| message.created   | Messaging Service | {from_user_id, to_user_id, message_content}            | MESSAGE_RECEIVED |
| group.created     | Events Service    | {group_id, creator_id, group_name}                     | GROUP_CREATED    |
| memory.shared     | Album Service     | {memory_id, shared_by_id, shared_to_user_ids[]}        | MEMORY_SHARED    |
| memory.liked      | Album Service     | {memory_id, liked_by_id, memory_owner_id}              | MEMORY_LIKED     |
| comment.added     | Album Service     | {comment_id, commenter_id, memory_id, memory_owner_id} | COMMENT_ADDED    |
| user.friend_added | Events Service    | {user_id, friend_id}                                   | FRIEND_ADDED     |
| user.mentioned    | Events Service    | {mentioned_user_id, context_type, context_id}          | USER_MENTIONED   |

### 発行するイベント（他サービス向け）

| イベントタイプ       | 消費者         | ペイロード例                        | 用途                       |
| -------------------- | -------------- | ----------------------------------- | -------------------------- |
| notification.sent    | Events Service | {notification_id, user_id, sent_at} | ユーザーアクティビティログ |
| device_token.revoked | Auth Service   | {user_id, device_id, token_value}   | デバイス管理同期           |

## 6. コスト分析

### 各サービスの比較表（採用候補のみ）

| 項目                                  | Firebase Cloud Messaging   | Postfix + Dovecot + Rspamd (CoreServerV2) | OneSignal                         | Pusher Beams |
| ------------------------------------- | -------------------------- | ----------------------------------------- | --------------------------------- | ------------ |
| プッシュ通知コスト                    | **無料**                   | N/A                                       | Free: 10K subscribers, $99+/month | $99+/month   |
| メール送信コスト                      | N/A                        | **$0（CoreServerV2 契約に含む）**         | Included                          | Included     |
| iOS/Android対応                       | ✓ (クロスプラットフォーム) | ✗                                         | ✓                                 | ✓            |
| セキュリティ                          | Google (高)                | 自己運用（SPF/DKIM/DMARC 設定済）         | 独立                              | Pusher       |
| TTL/遅延配信                          | ✓ (最大4週間)              | ✗                                         | ✓                                 | ✓            |
| コンソール管理                        | ✓                          | Grafana + Loki（maillog 可視化）          | ✓                                 | ✓            |
| 月額固定費                            | $0                         | $0（契約に包含）                          | $99+                              | $99+         |
| 想定月間通知数（100K users × 10通知） | $0                         | $0                                        | $99                               | $99          |

### 推奨構成: FCM-primary（FCM 中心、Postfix メール条件付き）

通常の活動通知は FCM で完結し、メール送信は [メール通知条件](#mail-notification-conditions) に合致する場合のみ Postfix 経由で使用する。

**月間 100K ユーザー、1 ユーザーあたり平均 10 通知/月の場合**:
- **プッシュ通知**: FCM 無料 = **$0**
- **メール通知（条件付き）**: Postfix on CoreServerV2 = CORE+X 契約費用に含まれる = **$0**
- **QueuePort**: Beta は Redis（XServer VPS 共用）、本番は OCI Queue Service 従量課金（月 100 万リクエスト想定で少額）
- **合計**: Beta **$0 相当**、本番 OCI Queue 料金のみ

OneSignal 等（月額 $99+）と比較すると **年間 $1,188 以上のコスト削減**。AWS SES / SNS を使わないことで従量課金も発生しない。

## 7. デプロイ・インフラ

- **実行環境**: Docker コンテナ（Beta: XServer VPS の Docker Compose / k3s、本番: OCI Container Instances）
- **ロードバランシング**: Beta は Nginx、本番は OCI Load Balancer
- **ログ**: Loki（Postfix maillog 含む）
- **モニタリング**: Prometheus + Grafana、アラート配送は Alertmanager → QueuePort → admin-console-svc
- **スケーリング**: Beta は手動（Docker Compose replicas）、本番は OCI Container Instances のスケール設定

## 8. セキュリティ考慮事項

- FCM サービスアカウント秘密鍵は **Beta: XServer VPS の暗号化ボリューム + age 暗号化**、**本番: OCI Vault** に保管（AWS Secrets Manager は不使用）
- デバイストークンは暗号化して MySQL / MariaDB に保存
- API 認証: JWT（Authentication Service / Cognito 発行の RS256 を検証）
- レート制限: Redis ベースの user_id / IP アドレスレート制限
- データ保護: 通知内容は最小限（個人情報含まない設計）
- メール認証: SPF / DKIM（2048bit）/ DMARC（p=quarantine 以上）必須
- **SMTP 送信の最低要件（PR #6 レビュー反映）**: STARTTLS 拡張の広告を確認 → TLS 1.2+ に昇格 → AUTH 拡張確認後のみ認証実行。平文での AUTH / 配送を禁止。

## 9. 横断標準の適用（追加設計プラン反映）

[基本的方針（Policy）§8](../core/policy.md#8-大規模類似サービス参照反復版) および [microservice/index.md 横断標準](index.md#横断標準cross-cutting-standards) の適用状況を明示する。

| 標準                                  | 本サービスでの反映                                                                                                                                                                                                                              |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Idempotency Key**                   | `POST /api/notifications/register-device`、`PUT /api/notifications/preferences/*`、`POST /api/notifications/{id}/retry` は `Idempotency-Key` を受理（推奨、24h 保持）。キー未指定時も通常処理するが警告ログを記録し、GA で必須化予定（[policy.md §8.3](../core/policy.md#8-大規模類似サービス参照反復版)）。QueuePort Consumer 側でも `notification_id` を冪等キーとして重複配信を防止。 |
| **Transactional Outbox**              | `NotificationSent` / `NotificationFailed` / `DeviceTokenRevoked` を `outbox_events` に書き込み、Publisher が QueuePort に転送。FCM 呼び出しの成否は **Outbox へ記録した後** に確定させる（DB と副作用の整合）。                                 |
| **Saga (Choreography)**               | `memory.shared` / `comment.added` 等を受信 → 配信タスク実行 → `notification.sent` を Outbox へ。配信失敗時は `notification.failed` を Outbox 経由で発行し、管理コンソールの運用タスクに連携。                                                   |
| **Circuit Breaker + Backoff**         | FCM API、Postfix SMTP への呼び出しに `gobreaker` を適用。失敗率 50% / 20 件で Open、30 秒で Half-Open。再送は base 200ms × factor 2 に jitter（±25%）を付与（max 3 回）。                                                                       |
| **OpenTelemetry + W3C Trace Context** | HTTP / QueuePort の入出境界で `traceparent` を伝播。`notification_id` と `trace_id` の相関をログで保持（本文は出さない）。                                                                                                                      |
| **SLI/SLO**                           | `NotificationCreated → FCM Sent` 95%tile < 60s、`PostfixSMTP 送信` 95%tile < 10s、配信成功率 >= 99.0% を SLO として監視。エラーバジェット枯渇時は `circuit.breaker.fcm.disabled=true` Kill Switch で一時停止可能。                              |
| **レート制限**                        | デバイスあたり FCM 送信は 1 分間に 10 件まで（優先度 HIGH は例外）。ユーザーごとの通知合計は 1 日 200 件まで、それ以上は IN_APP に退避。                                                                                                        |
| **SMTP 最低要件**                     | §8 と `PostfixSMTPAdapter` 実装で STARTTLS / TLS1.2+ / AUTH 拡張確認を必須化（[クリーンアーキテクチャ](../clean-architecture/notifications-svc.md#postfixsmtpadapter-mailport-実装) 参照）。                                                    |

## 10. レビュー指摘の反映記録

| 日付       | 出所                                        | 指摘                                                                | 反映                                                                                                                                  |
| ---------- | ------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-04-19 | PR #6 Copilot Autofix（コミット `56a90bc`） | Postfix SMTP アダプタで STARTTLS が明示的に要求されていない         | `PostfixSMTPAdapter.SendEmail` で STARTTLS 広告確認 → TLS1.2+ 昇格 → AUTH 拡張確認 を必須化。重複コードを整理。                       |
| 2026-04-19 | 横断レビュー（コミット `464267` マージ後）  | メール通知条件が MS / CA で分散し、改訂時の差異が発生しやすい       | MS 側は `{ #メール通知条件 }` / CA 側は `{ #postfixsmtp-利用条件 }` の **明示 ID** を見出しに付与して安定化。両方から policy.md §2.3 / §8 を参照する構成に統一。 |
| 2026-04-19 | 追加設計プラン反復                          | 冪等性 / Outbox / Saga / Circuit Breaker / SLO が文書ごとにバラバラ | 本 §9 の横断標準表を新設し、policy.md §8 と同期。                                                                                     |

## 9. 追加設計プラン（大規模類似サービス参照）

| 観点 | 参照モデル | Recuerdo 反映方針 |
| --- | --- | --- |
| 通知チャネル優先順位 | Instagram/Meta 系の Push-first 運用 | FCM を既定経路に固定し、メールは 5 条件のみ許可 |
| 通知疲労の抑制 | Slack の quiet hours / preference 運用 | `NotificationPreference` と quiet hours を全通知種別で必須評価 |
| 配信失敗ハンドリング | 大規模メッセージング基盤の DLQ 運用 | QueuePort の再試行 3 回 + DLQ 監査を標準化 |
| 監査/証跡 | GitHub 等の法的通知ログ管理 | 法的・セキュリティ通知は Email 送信証跡を保持 |

### 課題・他者レビュー反映

- **課題**: SMTP 実装例で STARTTLS が暗黙化されると平文送信リスクが残る。
- **レビュー反映**: STARTTLS を必須要件として明記し、非対応サーバーでは送信失敗とする。
- **継続レビュー項目**: MailPort 実装サンプルと運用手順の整合を四半期ごとにレビューする。

---

最終更新: 2026-04-19 ポリシー適用（追加設計プラン反映）
