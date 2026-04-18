# 通知サービス (recuerdo-notifications-svc)

**作成者**: Claude (AI) · **作成日**: 2026-04-15 · **ステータス**: 提案 (Proposal)

---

## 1. 概要

### 目的

Recuerdoアプリケーションのプッシュ通知・アプリ内通知・メール通知を一元管理するマイクロサービス。Messaging Service、Events Service、Album ServiceからのイベントをSQS経由で受け取り、ユーザーの通知設定に基づいて**FCM（Firebase Cloud Messaging）を主軸としたプッシュ通知**を配信する。SES（Amazon Simple Email Service）によるメール通知は、セキュリティ要件・FCMトークン未登録ユーザー・法的通知など特定条件下でのみ利用する（詳細は [SES利用条件](#ses利用条件) を参照）。デバイストークン管理、通知履歴追跡、配信状態管理、重複排除をサポートする。コスト最適化のため、FCMを中心とした無料チャネルを最大限活用し、大規模ユーザーベースでもスケーラブルな設計を実現する。

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

| 値オブジェクト       | 説明                     | バリデーションルール                                                                                               |
| -------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| NotificationType     | 通知の種別               | MESSAGE_RECEIVED, GROUP_CREATED, MEMORY_SHARED, MEMORY_LIKED, COMMENT_ADDED, FRIEND_ADDED, USER_MENTIONED (列挙型) |
| DeliveryChannel      | 配信チャネル             | PUSH (FCM/APNs), EMAIL (SES), IN_APP (アプリ内メッセージ) (複数選択可)                                             |
| NotificationPriority | 通知の優先度             | HIGH (即座配信), NORMAL (通常), LOW (まとめて配信)                                                                 |
| DevicePlatform       | デバイスプラットフォーム | iOS, Android, Web (値オブジェクト)                                                                                 |
| FCMMessage           | FCMに送信するペイロード  | title, body, custom_data, priority, ttl                                                                            |
| SESEmail             | SESに送信するメール      | to_address, subject, html_body, text_body                                                                          |
| QuietHours           | ユーザーの通知OFF時間帯  | start_hour (0-23), end_hour (0-23)、タイムゾーン対応                                                               |

### ドメインルール / 不変条件

- ユーザーが通知を受け取りたくない場合（preference_id で PUSH_ENABLED=false等）、そのチャネルで配信してはならない
- DeviceTokenの有効期限が切れた場合、そのトークンへの配信を試みてはならない
- プッシュ通知は同一ユーザーへの同一内容の重複配信を24時間以内で禁止しなければならない（重複排除）
- 通知がPENDINGの場合、SQS再試行を行うこと。3回失敗したらFAILED状態に遷移する
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

| ユースケース             | 入力DTO                                                                                        | 出力DTO                                                    | 説明                      |
| ------------------------ | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------- |
| SendNotification         | SendNotificationInput{user_id, notification_type, title, body, data, priority}                 | SendNotificationOutput{notification_id, channels_queued[]} | SQSイベントから通知を送信 |
| RegisterDeviceToken      | RegisterDeviceTokenInput{user_id, device_id, platform, token_value}                            | RegisterDeviceTokenOutput{device_token_id, expires_at}     | デバイストークン登録      |
| UpdatePreferences        | UpdatePreferencesInput{user_id, notification_type, email_frequency, push_enabled, quiet_hours} | UpdatePreferencesOutput{preference_id, updated_at}         | 通知設定更新              |
| MarkAsRead               | MarkAsReadInput{user_id, notification_id}                                                      | MarkAsReadOutput{read_count}                               | 通知を既読に              |
| GetUnreadCount           | GetUnreadCountInput{user_id}                                                                   | GetUnreadCountOutput{count}                                | 未読通知数取得            |
| RevokeDeviceToken        | RevokeDeviceTokenInput{device_token_id, reason}                                                | RevokeDeviceTokenOutput{revoked}                           | トークン無効化            |
| ListNotifications        | ListNotificationsInput{user_id, limit, offset}                                                 | ListNotificationsOutput{notifications[], total_count}      | ユーザーの通知一覧取得    |
| RetryFailedNotifications | RetryFailedNotificationsInput{notification_id?, max_retries}                                   | RetryFailedNotificationsOutput{retried_count}              | 失敗通知の再試行          |

### ユースケース詳細（主要ユースケース）

#### SendNotification — 主要ユースケース詳細

**トリガー**: Messaging Service、Events Service、Album Serviceから通知イベントをSQS経由で受信

**フロー**:
1. SQSメッセージを受信
2. NotificationTypeに基づいて、ユーザーのNotificationPreferenceを検索
3. 有効な配信チャネル（PUSH/EMAIL/IN_APP）を特定
4. 重複排除ロジック（Redis）で24時間以内の同一内容通知をチェック
5. 各チャネルに対して配信タスクをキュー
6. FCM（プッシュ通知）: DeviceTokenが有効な全iOSデバイスに送信
7. SES（メール通知）: ユーザーのメール設定に基づいて送信キューに追加
8. IN_APP通知: アプリ内通知テーブルに記録
9. 配信ログ記録
10. 失敗時は SQS DLQ（Dead Letter Queue）に移動し、3回まで自動再試行

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

#### Amazon SES (Simple Email Service)
- **用途**: メール通知（条件付き利用 — 後述のSES利用条件を参照）
- **コスト**: $0.10 / 1,000メール
- **実装**: aws-sdk-go-v2
- **特徴**:
  - テンプレート管理（SES Email Templates）
  - バウンス処理（自動UNSUBSCRIBE）
  - SQS連携で配信状態トラッキング

#### SES利用条件

FCMを主軸とした設計に移行するにあたり、SESは以下の条件に該当する場合にのみ利用する。

| 条件                                     | 説明                                                             | 判断基準                                                                                           |
| ---------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **1. セキュリティ・認証関連通知**        | パスワードリセット、メールアドレス確認、不審なログイン検知など   | FCMデバイスが使えない状況でも確実な通達が必要。セキュリティ上、プッシュのみでは不十分              |
| **2. FCMトークン未登録ユーザー**         | モバイルアプリ未インストール、またはOS通知権限を拒否したユーザー | DeviceToken レコードが存在しない、もしくは全て is_valid=false の場合                               |
| **3. FCM配信連続失敗時のフォールバック** | FCMによるプッシュ配信が3回連続失敗した重要通知                   | NotificationLog.retry_count >= 3 かつ priority = HIGH の場合。通常・低優先通知には適用しない       |
| **4. 法的・規約変更通知**                | 利用規約変更、プライバシーポリシー改定、アカウント強制停止通知   | 法令遵守・証跡確保のため、記録可能な通達手段が必須。メールは監査ログと連動                         |
| **5. 週次・月次ダイジェストメール**      | ユーザーが「まとめメール受信」を明示的に設定した場合のみ         | NotificationPreference.email_frequency = DAILY または WEEKLY、かつユーザーが明示的にオプトイン済み |

> **設計方針**: 上記5条件に該当しない通常の活動通知（メッセージ受信、思い出シェア、コメント等）はFCMプッシュ + IN_APPのみで配信する。SESを「デフォルト通知チャネル」として扱わないことで、メールコストとスパムリスクを最小化する。

#### AWS SQS
- **用途**: イベント駆動の非同期通知キューイング
- **コスト**: $0.40 / 100万リクエスト
- **実装**: Consumer が 通知-svc に統合
- **特徴**:
  - DLQ（Dead Letter Queue）による失敗通知管理
  - メッセージ可視性タイムアウト設定で再試行制御
  - 複数のイベントソース（Messaging、Events、Album Services）対応

#### MySQL
- **用途**: Notification、DeviceToken、NotificationPreference、NotificationLog永続化
- **テーブル**:
  - notifications (id, user_id, type, title, body, priority, status, created_at)
  - device_tokens (id, user_id, device_id, platform, token_value, is_valid, expires_at)
  - notification_preferences (id, user_id, notification_type, email_frequency, push_enabled, in_app_enabled, quiet_hours_start, quiet_hours_end)
  - notification_logs (id, notification_id, channel, status, error_message, retry_count, delivered_at)

#### Redis
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

## 5. SQSイベント処理

### 消費するイベント（他サービスから）

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

### 各サービスの比較表

| 項目                                  | Firebase Cloud Messaging   | Amazon SNS  | Amazon SES      | OneSignal                         | Pusher Beams |
| ------------------------------------- | -------------------------- | ----------- | --------------- | --------------------------------- | ------------ |
| プッシュ通知コスト                    | **無料**                   | $0.50/100万 | N/A             | Free: 10K subscribers, $99+/month | $99+/month   |
| メール送信コスト                      | N/A                        | $2.00/100万 | **$0.10/1,000** | Included                          | Included     |
| iOS/Android対応                       | ✓ (クロスプラットフォーム) | ✓           | ✗               | ✓                                 | ✓            |
| セキュリティ                          | Google (高)                | AWS         | AWS             | 独立                              | Pusher       |
| TTL/遅延配信                          | ✓ (最大4週間)              | ✗           | ✗               | ✓                                 | ✓            |
| コンソール管理                        | ✓                          | ✓           | ✓               | ✓                                 | ✓            |
| 月額固定費                            | $0                         | $0          | $0              | $99+                              | $99+         |
| 想定月間通知数（100K users × 10通知） | $0                         | $5          | $1              | $99                               | $99          |

### 推奨構成: FCM-primary（FCM中心、SES条件付き）

通常の活動通知はFCMで完結し、SESは [SES利用条件](#ses利用条件) に合致する場合のみ使用する。

**月間100K ユーザー、1ユーザーあたり平均10通知/月の場合**:
- **プッシュ通知**: FCM無料 = **$0**
- **メール通知（条件付き）**: SES = 条件対象通知のみ。セキュリティ通知・ダイジェスト等を推定5% と仮定: 100K × 10 × 0.05 / 1000 × $0.10 = **約$0.005/月**（通常通知はFCMで代替するため従来比約97%削減）
- **SQS**: $0.40/100万 × (100K × 10) / 100万 ≈ **$0.004/月**
- **合計**: **約$0.01/月**

FCM+SES全送信（全通知をメール配信した場合の$0.15/月）と比較して月間コストは最小化。OneSignal等（月額$99+）と比較すると、**年間$1,188以上のコスト削減**が実現。

## 7. デプロイ・インフラ

- **実行環境**: Docker コンテナ、AWS ECS Fargate
- **ロードバランシング**: ALB
- **ログ**: CloudWatch Logs
- **モニタリング**: CloudWatch Metrics、SNS アラート
- **スケーリング**: ECS Auto Scaling (CPU/メモリベース)

## 8. セキュリティ考慮事項

- FCMサービスアカウント秘密鍵は AWS Secrets Manager に保管
- デバイストークンは暗号化してMySQLに保存
- API認証: JWT (Authentication Service から発行)
- レート制限: Redis ベースの user_id/IP アドレスレート制限
- データ保護: 通知内容は最小限（個人情報含まない設計）
