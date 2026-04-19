# Authentication Service (recerdo-auth)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

Recuerdoアプリケーションの全ユーザー認証・認可・セッション管理・デバイス登録追跡を一元管理するマイクロサービス。AWS Cognitoのユーザー認証をラッパーし、JWT（RS256）の発行・更新・無効化・JWKS管理を行う（本プロジェクトで採用する AWS サービスは Cognito のみ）。ログイン時にCognitoのユーザー状態をローカルDB（MySQL 8.0 / MariaDB 10.11 互換）に同期し、API Gateway等の下流サービスへJWKSを提供して分散型トークン検証を実現する。トークン無効化・デバイス登録イベントは `QueuePort` 経由（Beta: Redis + BullMQ/asynq、本番: OCI Queue Service）で API Gateway・Permission Service に通知する。セッション・デバイス・ブロック済みトークンのライフサイクル管理により、ユーザーの認証状態を一貫性を持つ形で制御する。

### ビジネスコンテキスト

解決する問題:
- 複数のマイクロサービス間でJWT検証ロジックが重複し、鍵ローテーション・トークン無効化の一貫性が保証されない
- デバイス登録・セッション追跡機能がなく、ユーザーが複数デバイスからの同時アクセス・不正アクセスを検知できない
- ログアウト時のトークン無効化がAPI Gateway等で個別に管理されており、スケーリング困難
- 人事システムからユーザーサスペンド情報がリアルタイムに反映されず、不正アクセス防止ができない

Key User Stories:
- iOSアプリユーザーとして、電話番号・パスワードでログインし、JWTを取得してAPIを呼び出したい
- バックエンド開発者として、API Gatewayから共有されるJWKSエンドポイント経由でJWT署名を検証し、毎回Authentication Serviceを呼ばずに済みたい
- セキュリティ担当として、ユーザーがログアウトした瞬間に全デバイスのセッションを無効化し、Permission Serviceに通知したい
- 運用担当として、ユーザーがサスペンドされた場合、既存のセッション・トークンを即座に無効化したい
- iOSアプリ開発者として、複数デバイスからのログインを許可し、各デバイスの登録・セッション情報を確認したい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ      | 説明                                                             | 主要属性                                                                                                                                                         |
| ----------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| User              | 認証済みユーザー。Cognitoと同期                                  | user_id (UUID), email, phone_number, cognito_sub, status (ACTIVE/SUSPENDED), created_at, updated_at, sync_version                                                |
| Session           | ユーザーのログインセッション。デバイス・トークン・有効期限を管理 | session_id (UUID), user_id, device_id, access_token_jti, refresh_token_jti, issued_at, access_expires_at, refresh_expires_at, ip_address, user_agent, is_revoked |
| Device            | ユーザーが使用するデバイス（iOS/Web）の登録情報                  | device_id (UUID), user_id, device_name, device_type, os_version, app_version, fingerprint, last_seen_at, created_at, is_archived                                 |
| BlockedToken      | 無効化されたJWT (ログアウト・強制切断)                           | jti (UUID), user_id, token_type (ACCESS/REFRESH), revocation_reason (LOGOUT/USER_SUSPENDED/DEVICE_ARCHIVED), expires_at, blocked_at                              |
| RefreshTokenGrant | RefreshToken更新時の監査ログ                                     | grant_id (UUID), user_id, old_jti, new_jti, device_id, requested_at, granted_at, client_ip                                                                       |

### 値オブジェクト

| 値オブジェクト        | 説明                                                                         | バリデーションルール                                                                                                          |
| --------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| JWTClaims             | Cognitoから取得したJWTペイロード                                             | sub (Cognito user UUID), email, phone_number, exp, iat, jti (JWT ID), iss (Cognito User Pool URL), aud, token_use (access/id) |
| AccessToken           | 署名済みAccess Token (有効期限1時間)                                         | RS256署名, RS256またはRS384キー。JTI・user_id・device_id・permissions_version・timestamp含有                                  |
| RefreshToken          | Refresh Token (有効期限30日)。セキュアHttpOnly Cookie またはレスポンスボディ | RS256署名, JTI・user_id・device_id・grant_generation含有。DBのrefresh_token_grantで追跡可能                                   |
| DeviceFingerprint     | デバイスの一意識別子                                                         | SHA256(device_type + os_version + app_version)。偽装防止用に定期更新可能                                                      |
| CognitoUserID         | Cognito User Pool内の一意識別子                                              | UUID形式。user_idの外部キー                                                                                                   |
| TokenRevocationReason | トークン無効化の理由                                                         | LOGOUT (ユーザー明示的), USER_SUSPENDED (人事システム同期), DEVICE_ARCHIVED (デバイス削除), PERMISSION_REVOKED (権限剥奪)     |

### ドメインルール / 不変条件

- ユーザーがACTIVEでない場合、新規ログインもセッション継続も許可してはならない
- JWTは必ずRS256署名で、Cognitoの現在の公開鍵で検証しなければならない
- BlockedTokensに存在するJTIのセッションは即座に無効とみなさなければならない
- Refresh Token実行時、古いJTIを必ずBlockedTokensに追加しなければならない
- セッション・デバイス情報の更新は必ずsync_versionを自動採番して監査可能にしなければならない
- 人事システムからのユーザーサスペンド通知受信時、ユーザーに紐づく全セッション・JTIをBlockedTokensに追加しなければならない
- デバイスアーカイブ時、デバイスに紐づく全Sessionの終了・JTI無効化が必要である
- ログアウト時、ユーザーの全セッション（全デバイス）を無効化するか、指定デバイスのセッションのみ無効化するか、明示的に指定されなければ全セッション無効化が既定動作である
- AccessToken有効期限は1時間、RefreshToken有効期限は30日を超えてはならない
- JWKS （JSON Web Key Set）はCognitoから定期的に取得し、Redisに5分のTTLで保持しなければならない

### ドメインイベント

| イベント          | トリガー                                      | 主要ペイロード                                                    |
| ----------------- | --------------------------------------------- | ----------------------------------------------------------------- |
| UserLoggedIn      | ログイン成功時                                | user_id, session_id, device_id, issued_at, client_ip, device_name |
| UserLoggedOut     | ログアウト成功時                              | user_id, session_id, device_id, logout_time, revoked_tokens_count |
| TokenRefreshed    | RefreshToken実行成功時                        | user_id, old_jti, new_jti, device_id, timestamp                   |
| TokenRevoked      | JWTが無効化された時                           | jti, user_id, token_type, reason, revoked_at, expires_at          |
| DeviceRegistered  | デバイスが初めてログインした時                | user_id, device_id, device_name, device_type, fingerprint         |
| DeviceArchived    | デバイスが削除/アーカイブされた時             | user_id, device_id, archived_at, session_count_revoked            |
| UserSuspended     | 人事システムからのサスペンド通知受信時        | user_id, suspended_at, sessions_count, reason                     |
| CognitoUserSynced | Cognitoユーザー情報がローカルDBに同期された時 | user_id, cognito_sub, email, phone, status, sync_version          |
| JWKSRotated       | Cognitoが公開鍵をローテーションした時         | kid_list, rotated_at, previous_kid_list                           |

### エンティティ定義（コードスケッチ）

```go
// User エンティティ
type User struct {
    UserID      string    // UUID
    Email       string
    PhoneNumber string
    CognitoSub  string    // Cognito User Pool内の一意識別子
    Status      string    // ACTIVE, SUSPENDED
    CreatedAt   time.Time
    UpdatedAt   time.Time
    SyncVersion int64     // 楽観的ロック・監査用
}

func (u *User) IsSuspended() bool {
    return u.Status == "SUSPENDED"
}

func (u *User) CanLogin() bool {
    return u.Status == "ACTIVE" && u.CognitoSub != ""
}

// Session エンティティ
type Session struct {
    SessionID        string
    UserID          string
    DeviceID        string
    AccessTokenJTI  string
    RefreshTokenJTI string
    IssuedAt        time.Time
    AccessExpiresAt time.Time
    RefreshExpiresAt time.Time
    IPAddress       string
    UserAgent       string
    IsRevoked       bool
}

func (s *Session) IsAccessTokenExpired(now time.Time) bool {
    return now.After(s.AccessExpiresAt)
}

func (s *Session) IsRefreshTokenExpired(now time.Time) bool {
    return now.After(s.RefreshExpiresAt)
}

func (s *Session) IsValid(now time.Time, isTokenBlocked bool) bool {
    return !s.IsRevoked && !isTokenBlocked && !s.IsAccessTokenExpired(now)
}

// Device エンティティ
type Device struct {
    DeviceID     string
    UserID      string
    DeviceName  string
    DeviceType  string    // iOS, Web, Android
    OSVersion   string
    AppVersion  string
    Fingerprint string    // SHA256(type+os+app)
    LastSeenAt  time.Time
    CreatedAt   time.Time
    IsArchived  bool
}

func (d *Device) MatchesFingerprint(calculated string) bool {
    return d.Fingerprint == calculated
}

func (d *Device) UpdateLastSeen(now time.Time) {
    d.LastSeenAt = now
}

// BlockedToken エンティティ
type BlockedToken struct {
    JTI               string    // JWT ID
    UserID           string
    TokenType        string    // ACCESS, REFRESH
    RevocationReason string    // LOGOUT, USER_SUSPENDED, DEVICE_ARCHIVED
    ExpiresAt        time.Time // トークン本来の有効期限
    BlockedAt        time.Time
}

func (b *BlockedToken) IsExpired(now time.Time) bool {
    return now.After(b.ExpiresAt)
}

// RefreshTokenGrant エンティティ (監査ログ)
type RefreshTokenGrant struct {
    GrantID   string
    UserID   string
    OldJTI   string
    NewJTI   string
    DeviceID string
    RequestedAt time.Time
    GrantedAt   time.Time
    ClientIP    string
}
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース     | 入力DTO                                                            | 出力DTO                                                       | 説明                                                                              |
| ---------------- | ------------------------------------------------------------------ | ------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Login            | LoginInput{phone_number, password, device_name, device_type}       | LoginOutput{access_token, refresh_token, session_id, user_id} | Cognitoに対して認証を実行し、セッション・デバイス登録を行う。最重要ユースケース   |
| RefreshToken     | RefreshTokenInput{refresh_token, device_id}                        | RefreshTokenOutput{new_access_token, session_id}              | RefreshTokenから新AccessTokenを発行。古いJTIをブロック                            |
| Logout           | LogoutInput{user_id, session_id?, revoke_all}                      | LogoutOutput{revoked_count}                                   | セッションを無効化。revoke_all=trueで全セッション終了                             |
| GetJWKS          | GetJWKSInput{}                                                     | GetJWKSOutput{jwks_json}                                      | API Gatewayへ向けてCognitoのJWKSを返す。Redisキャッシュ利用                       |
| SyncCognitoUser  | SyncCognitoUserInput{cognito_event, user_id}                       | SyncCognitoUserOutput{user, sync_version}                     | Cognitoログイン時にユーザー情報を同期。StatusチェックためPermission Serviceと連動 |
| RegisterDevice   | RegisterDeviceInput{user_id, device_name, device_type, os_version} | RegisterDeviceOutput{device_id, created}                      | デバイスを登録。初回ログイン時に自動実行                                          |
| ArchiveDevice    | ArchiveDeviceInput{user_id, device_id}                             | ArchiveDeviceOutput{archived, revoked_session_count}          | デバイスをアーカイブし、紐づく全Sessionを無効化                                   |
| RevokeUserTokens | RevokeUserTokensInput{user_id, reason, skip_device_id?}            | RevokeUserTokensOutput{revoked_count}                         | ユーザーの全JTIをブロック。特定デバイドをスキップ可能。人事システム同期用         |
| ValidateToken    | ValidateTokenInput{token_string}                                   | ValidateTokenOutput{claims, is_valid, reason}                 | トークンがまだ有効か確認。BlockedTokensチェック含む                               |
| GetSession       | GetSessionInput{session_id}                                        | GetSessionOutput{session, user, device}                       | セッション情報を取得。ユーザーのセッション一覧表示用                              |
| ListSessions     | ListSessionsInput{user_id}                                         | ListSessionsOutput{sessions[]}                                | ユーザーの全セッション（全デバイス）を一覧表示                                    |

### ユースケース詳細（主要ユースケース）

## Login — 主要ユースケース詳細

### トリガー
iOSアプリ・WebアプリからのPOST /api/auth/login リクエスト

### フロー
1. リクエストバリデーション
   - phone_number形式チェック (E.164)
   - password 存在チェック (5文字以上)
   - device_nameは1～100文字
2. CognitoAuthPort.Authenticate(phone_number, password)
   a. Cognito InitiateAuth (USER_PASSWORD_AUTH フロー)
   b. 認証失敗 → ErrInvalidCredentials
   c. JWTトークン・ID Token取得
3. CognitoJWTClaims を取得 (sub, email, phone_number, jti)
4. SyncCognitoUserUseCase.Execute(JWTClaims)
   a. ローカルUserが存在しなければ新規作成
   b. 既存なら email・phone_number を更新
   c. Status = ACTIVE を確認。SUSPENDED → ErrUserSuspended
   d. Statusをローカルに記録
5. UserRepository.GetUser(cognito_sub) → user_id
6. DeviceRepository.FindOrCreate(user_id, device_fingerprint)
   a. 初回デバイスならDevice作成 → DeviceRegistered イベント発行
   b. 既知デバイスなら last_seen_at を更新
7. SessionRepository.Create(user_id, device_id, access_token_jti, refresh_token_jti)
   a. access_expires_at = now + 1h
   b. refresh_expires_at = now + 30days
   c. session_id は新規UUID生成
8. デバイスフィンガープリント (SHA256(device_type + os_version + app_version)) をDeviceに保存
9. QueuePort.Publish(UserLoggedIn イベント) → API Gateway・Messaging Service に通知
10. レスポンス:
    ```json
    {
      "access_token": "eyJ...",
      "refresh_token": "eyJ...",
      "session_id": "uuid",
      "user_id": "uuid",
      "expires_in": 3600,
      "token_type": "Bearer"
    }
    ```

### 注意事項
- アクセストークンはRs256署名で、JTI・user_id・device_id・permissions_version含有
- RefreshTokenはHTTPOnly Cookieとしても返可（Web向け）
- デバイスフィンガープリント照合により、同一セッションの権限昇格攻撃を防止
- アクセストークン生成時はRedis内のJWKS (最新鍵リスト) を使用
- 権限チェックはPermission Serviceで実施（このサービスでは認証のみ）
- クライアントIP・User-Agentはセッション監査用に記録
- Cognito認証失敗は5分間のレート制限により Brute Force 防止

## RefreshToken — 詳細

### トリガー
POST /api/auth/refresh リクエスト (Authorization: Bearer refresh_token)

### フロー
1. RefreshToken 文字列をバリデーション・署名検証
2. JTIClaims.jti・user_id・device_id を抽出
3. BlockedTokenRepository.Exists(old_jti) 確認 → 存在 → ErrTokenRevoked
4. SessionRepository.GetByAccessTokenJTI(old_jti) → sessionを取得
5. session.IsRefreshTokenExpired(now) チェック → 期限切れ → ErrRefreshTokenExpired
6. session.device_id と RefreshTokenのdevice_idが一致することを確認
7. 新AccessToken生成:
   a. 新JTI生成
   b. permissions_version はPermission Serviceから最新値を取得
   c. RS256署名
8. 古いJTIを BlockedTokenRepository に追加 (TokenRevoked イベント)
9. SessionRepository.Update(session_id, access_token_jti=new_jti)
10. RefreshTokenGrant監査ログを記録
11. QueuePort.Publish(TokenRefreshed イベント)
12. レスポンス: 新AccessTokenのみ返す

### 注意事項
- RefreshToken自体は署名検証のみで、DBには保存しない（署名がそのまま認証）
- Refresh実行時は古いAccessToken JTIをブロック（同一DeviceでRefresh連鎖攻撃防止）
- RefreshToken本体の有効期限は30日だが、Sessionが無効化されると RefreshToken も使用不可

### リポジトリ・サービスポート（インターフェース）

```go
// Repository Ports
type UserRepository interface {
    GetUser(ctx context.Context, userID string) (*User, error)
    GetByCognitoSub(ctx context.Context, cognitoSub string) (*User, error)
    CreateOrUpdate(ctx context.Context, user *User) error
    ListByCognitoSubs(ctx context.Context, subs []string) ([]*User, error)
}

type SessionRepository interface {
    Create(ctx context.Context, session *Session) error
    GetBySessionID(ctx context.Context, sessionID string) (*Session, error)
    GetByAccessTokenJTI(ctx context.Context, jti string) (*Session, error)
    GetByRefreshTokenJTI(ctx context.Context, jti string) (*Session, error)
    ListByUserID(ctx context.Context, userID string) ([]*Session, error)
    Update(ctx context.Context, session *Session) error
    RevokeByUserID(ctx context.Context, userID string, skipDeviceID *string) (int64, error)
    RevokeByDeviceID(ctx context.Context, deviceID string) (int64, error)
    DeleteExpired(ctx context.Context, beforeTime time.Time) (int64, error)
}

type DeviceRepository interface {
    Create(ctx context.Context, device *Device) error
    GetByDeviceID(ctx context.Context, deviceID string) (*Device, error)
    ListByUserID(ctx context.Context, userID string) ([]*Device, error)
    FindOrCreateByFingerprint(ctx context.Context, userID, fingerprint string, name, dtype string) (*Device, error)
    Archive(ctx context.Context, deviceID string) error
    UpdateLastSeen(ctx context.Context, deviceID string, now time.Time) error
}

type BlockedTokenRepository interface {
    Add(ctx context.Context, token *BlockedToken) error
    Exists(ctx context.Context, jti string) (bool, error)
    DeleteExpired(ctx context.Context, beforeTime time.Time) (int64, error)
    ListByUserID(ctx context.Context, userID string) ([]*BlockedToken, error)
}

type RefreshTokenGrantRepository interface {
    Record(ctx context.Context, grant *RefreshTokenGrant) error
    ListByUserID(ctx context.Context, userID string, limit int) ([]*RefreshTokenGrant, error)
}

type JWKSRepository interface {
    GetCached(ctx context.Context) (map[string]interface{}, error)
    Set(ctx context.Context, jwks map[string]interface{}, ttl time.Duration) error
    Invalidate(ctx context.Context) error
}

// Service Ports
type CognitoAuthPort interface {
    Authenticate(ctx context.Context, phoneNumber, password string) (*CognitoAuthResult, error)
    // CognitoAuthResult { AccessToken, IDToken, RefreshToken (Cognito側), ExpiresIn }
    FetchJWKS(ctx context.Context) (map[string]interface{}, error)
    GetUserAttributes(ctx context.Context, accessToken string) (map[string]string, error)
}

type JWTSignerPort interface {
    SignAccessToken(ctx context.Context, claims JWTClaims) (string, error)
    SignRefreshToken(ctx context.Context, claims JWTClaims) (string, error)
    VerifyToken(ctx context.Context, tokenString string) (*JWTClaims, error)
}

type PermissionPort interface {
    GetUserPermissionsVersion(ctx context.Context, userID string) (int64, error)
    CheckUserStatus(ctx context.Context, userID string) (string, error) // ACTIVE, SUSPENDED
}

type EventPublisherPort interface {
    PublishUserLoggedIn(ctx context.Context, event *UserLoggedInEvent) error
    PublishUserLoggedOut(ctx context.Context, event *UserLoggedOutEvent) error
    PublishTokenRefreshed(ctx context.Context, event *TokenRefreshedEvent) error
    PublishTokenRevoked(ctx context.Context, event *TokenRevokedEvent) error
    PublishDeviceRegistered(ctx context.Context, event *DeviceRegisteredEvent) error
    PublishUserSuspended(ctx context.Context, event *UserSuspendedEvent) error
    PublishCognitoUserSynced(ctx context.Context, event *CognitoUserSyncedEvent) error
}

type RateLimitPort interface {
    CheckLogin(ctx context.Context, phoneNumber string) (bool, error) // phone_number単位で1分に5回制限
    CheckRefresh(ctx context.Context, userID string) (bool, error)    // user_id単位で1時間に100回制限
}
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ    | ルート/トリガー                            | ユースケース                |
| --------------- | ------------------------------------------ | --------------------------- |
| AuthHTTPHandler | POST /api/auth/login                       | LoginUseCase                |
| AuthHTTPHandler | POST /api/auth/refresh                     | RefreshTokenUseCase         |
| AuthHTTPHandler | POST /api/auth/logout                      | LogoutUseCase               |
| AuthHTTPHandler | GET /api/auth/sessions                     | ListSessionsUseCase         |
| AuthHTTPHandler | DELETE /api/auth/sessions/{session_id}     | RevokeSessionUseCase        |
| AuthHTTPHandler | POST /api/auth/devices/{device_id}/archive | ArchiveDeviceUseCase        |
| JWKSHTTPHandler | GET /.well-known/jwks.json                 | GetJWKSUseCase              |
| HealthHandler   | GET /health                                | ヘルスチェック              |
| MetricsHandler  | GET /metrics                               | Prometheusメトリクス        |
| QueueConsumer   | Topic: `recuerdo.user.suspended`           | RevokeUserTokensUseCase     |
| QueueConsumer   | Topic: `recuerdo.device.revocation_requested` | RevokeDeviceSessionsUseCase |

### リポジトリ実装

| ポートインターフェース      | 実装クラス                       | データストア                               |
| --------------------------- | -------------------------------- | ------------------------------------------ |
| UserRepository              | MySQLUserRepository              | MySQL 8.0 / MariaDB 10.11 (users テーブル)     |
| SessionRepository           | MySQLSessionRepository           | MySQL 8.0 / MariaDB 10.11 (sessions テーブル)  |
| DeviceRepository            | MySQLDeviceRepository            | MySQL 8.0 / MariaDB 10.11 (devices テーブル)   |
| BlockedTokenRepository      | RedisBlockedTokenRepository      | Redis 7.x (blocked_tokens:{jti} → TTL付き)     |
| RefreshTokenGrantRepository | MySQLRefreshTokenGrantRepository | MySQL 8.0 / MariaDB 10.11 (refresh_token_grants テーブル) |
| JWKSRepository              | RedisJWKSRepository              | Redis 7.x (auth:jwks → TTL 5分)                |

### 外部サービスアダプタ

| ポートインターフェース | アダプタクラス               | 外部システム                                            |
| ---------------------- | ---------------------------- | ------------------------------------------------------- |
| CognitoAuthPort        | AWSCognitoAdapter            | AWS Cognito (InitiateAuth, GetUser)                     |
| JWTSignerPort          | RSA256JWTSigner              | ローカルRSA秘密鍵（Cognito公開鍵で検証）                |
| PermissionPort         | PermissionServiceGRPCAdapter | recerdo-permission (gRPC)                          |
| EventPublisherPort     | QueueEventPublisher          | QueuePort（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）Topic: `recuerdo.auth.*`, `recuerdo.gateway.*` |
| QueuePort              | **Beta:** `RedisBullMQAdapter` / `AsynqAdapter` / **本番:** `OCIQueueAdapter` | Redis 7.x + BullMQ/asynq / OCI Queue Service |
| RateLimitPort          | RedisRateLimitAdapter        | Redis 7.x (rate_limit:login:{phone}:{minute} 等)        |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + net/http (HTTPサーバー) + chi (ルーティング) + middleware (CORS, logging)

### データベース

MySQL 8.0 / MariaDB 10.11（互換性テストは CI で必須）(users, sessions, devices, refresh_token_grants テーブル。トランザクション・監査ログ)。Beta は XServer VPS 上に自己運用、本番は OCI MySQL HeatWave。
Redis 7.x (blocked_tokens, jwks キャッシュ、レート制限 sliding window)。Beta は XServer VPS 共用、本番は OCI Cache with Redis。

### 主要ライブラリ・SDK

| ライブラリ                        | 目的                                               | レイヤー       |
| --------------------------------- | -------------------------------------------------- | -------------- |
| golang-jwt/jwt/v5                 | JWT署名・検証                                      | Adapter        |
| aws-sdk-go-v2/service/cognito-idp | Cognito InitiateAuth・GetUser（Cognito のみ AWS を利用） | Infrastructure |
| lestrrat-go/jwx/v2                | JWKS取得・解析                                     | Infrastructure |
| go-redis/v9                       | BlockedTokens・JWKS・レート制限管理                | Infrastructure |
| go-sql-driver/mysql               | MySQL 8.0 / MariaDB 10.11 ドライバ                 | Infrastructure |
| pressly/goose または golang-migrate/migrate | DB マイグレーション                      | Infrastructure |
| google.golang.org/grpc            | Permission Service gRPCクライアント                | Infrastructure |
| hibiken/asynq（Beta Go）または BullMQ（Beta Node）/ OCI Queue SDK（本番） | QueuePort 実装（BlockedTokens・セッション無効化通知） | Infrastructure |
| uber-go/fx                        | 依存性注入                                         | Infrastructure |
| uber-go/zap                       | 構造化ログ                                         | Infrastructure |
| go.opentelemetry.io/otel          | 分散トレーシング                                   | Infrastructure |
| prometheus/client_golang          | メトリクス収集                                     | Infrastructure |
| golang.org/x/crypto               | パスワード ハッシング (bcrypt は不要。Cognito委譲) | Infrastructure |

### 依存性注入

uber-go/fx を使用。MySQL・Redis接続プール、gRPC接続を共有。

```go
fx.Provide(
    NewMySQLConnection,           // MySQL pool
    NewRedisClient,                  // Redis connection
    NewCognitoClient,                // AWS SDK Cognito（Cognito のみ AWS 利用）
    NewQueueClient,                  // QueuePort クライアント（Feature Flag で Beta: Redis+BullMQ/asynq, 本番: OCI Queue）
    NewGRPCPermissionClient,         // gRPC Permission Service
    
    // Repositories
    NewMySQLUserRepository,     // → UserRepository
    NewMySQLSessionRepository,  // → SessionRepository
    NewMySQLDeviceRepository,   // → DeviceRepository
    NewRedisBlockedTokenRepository,  // → BlockedTokenRepository
    NewMySQLRefreshTokenGrantRepository,
    NewRedisJWKSRepository,          // → JWKSRepository
    
    // Service Adapters
    NewAWSCognitoAdapter,            // → CognitoAuthPort
    NewRSA256JWTSigner,              // → JWTSignerPort
    NewPermissionServiceGRPCAdapter, // → PermissionPort
    NewQueueEventPublisher,          // → EventPublisherPort（QueuePort 委譲）
    NewRedisRateLimitAdapter,        // → RateLimitPort
    
    // Use Cases
    NewLoginUseCase,
    NewRefreshTokenUseCase,
    NewLogoutUseCase,
    NewGetJWKSUseCase,
    NewSyncCognitoUserUseCase,
    NewRegisterDeviceUseCase,
    NewArchiveDeviceUseCase,
    NewRevokeUserTokensUseCase,
    NewListSessionsUseCase,
    
    // Handlers
    NewAuthHTTPHandler,
    NewJWKSHTTPHandler,
    NewHealthHandler,
)
```

## 6. ディレクトリ構成

### ディレクトリツリー

```
recerdo-auth/
├── cmd/server/main.go
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── user.go
│   │   │   ├── session.go
│   │   │   ├── device.go
│   │   │   ├── blocked_token.go
│   │   │   └── refresh_token_grant.go
│   │   ├── valueobject/
│   │   │   ├── jwt_claims.go
│   │   │   ├── access_token.go
│   │   │   ├── refresh_token.go
│   │   │   ├── device_fingerprint.go
│   │   │   ├── cognito_user_id.go
│   │   │   └── token_revocation_reason.go
│   │   ├── event/
│   │   │   └── domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── login.go             # 最重要
│   │   ├── refresh_token.go
│   │   ├── logout.go
│   │   ├── get_jwks.go
│   │   ├── sync_cognito_user.go
│   │   ├── register_device.go
│   │   ├── archive_device.go
│   │   ├── revoke_user_tokens.go
│   │   ├── validate_token.go
│   │   ├── list_sessions.go
│   │   └── port/
│   │       ├── repository.go
│   │       └── service.go
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── auth_handler.go       # POST /login, /refresh, /logout, /sessions
│   │   │   ├── jwks_handler.go       # GET /.well-known/jwks.json
│   │   │   └── health_handler.go
│   │   ├── queue/
│   │   │   └── sqs_consumer.go       # user.suspended 購読
│   │   └── middleware/
│   │       ├── logging.go
│   │       └── rate_limit.go
│   └── infrastructure/
│       ├── MySQL/
│       │   ├── user_repo.go
│       │   ├── session_repo.go
│       │   ├── device_repo.go
│       │   ├── refresh_token_grant_repo.go
│       │   └── migrations/
│       │       ├── 001_create_users.sql
│       │       ├── 002_create_sessions.sql
│       │       ├── 003_create_devices.sql
│       │       └── 004_create_refresh_token_grants.sql
│       ├── redis/
│       │   ├── blocked_token_repo.go
│       │   ├── jwks_repo.go
│       │   └── rate_limit.go
│       ├── cognito/
│       │   └── cognito_adapter.go    # AWS SDK wrapper
│       ├── jwt/
│       │   └── jwt_signer.go         # RS256署名
│       ├── grpc/
│       │   └── permission_adapter.go
│       ├── sqs/
│       │   └── event_publisher.go
│       └── config/
│           └── config.go              # 環境変数読み込み
├── migrations/
│   └── *.sql
├── config/
│   └── config.yaml
└── k8s/
    ├── deployment.yaml
    ├── service.yaml
    └── configmap.yaml
```

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー                    | テスト種別       | モック戦略                                                                            |
| --------------------------- | ---------------- | ------------------------------------------------------------------------------------- |
| Domain (entity/valueobject) | Unit test        | 外部依存なし。User.CanLogin()・Session.IsValid()等                                    |
| UseCase                     | Unit test        | mockeryで全ポート（CognitoAuthPort/PermissionPort/EventPublisherPort等）をモック      |
| Adapter (HTTP)              | Integration test | httptest.Server で上流をモック。Login・Refresh・Logoutの完全フロー                    |
| Infrastructure (MySQL)      | Integration test | testcontainers-go でMySQL 15コンテナを起動。本物の table・transaction・lock動作を検証 |
| Infrastructure (Redis)      | Integration test | testcontainers-go でRedis 7コンテナを起動。BlockedTokens・JWKS 検証                   |
| E2E                         | E2E test         | Cognito sandbox環境。ログイン→トークン生成→リフレッシュ→ログアウトの実シナリオ        |
| Security test               | Penetration test | OWASP ZAP自動スキャン。JWT改ざん・device_fingerprint偽装・Cognito token reuse攻撃     |

### テストコード例

```go
// Entity Test
func TestUser_CanLogin_ActiveUser(t *testing.T) {
    user := &User{
        UserID:     "user-123",
        CognitoSub: "cognito-456",
        Status:     "ACTIVE",
    }
    assert.True(t, user.CanLogin())
}

func TestUser_CanLogin_SuspendedUser(t *testing.T) {
    user := &User{
        UserID:     "user-123",
        CognitoSub: "cognito-456",
        Status:     "SUSPENDED",
    }
    assert.False(t, user.CanLogin())
}

func TestSession_IsValid_AllChecks(t *testing.T) {
    session := &Session{
        IsRevoked:        false,
        AccessExpiresAt:  time.Now().Add(30 * time.Minute),
    }
    now := time.Now()
    assert.True(t, session.IsValid(now, false)) // not revoked, not blocked, not expired
    assert.False(t, session.IsValid(now, true))  // blocked
}

func TestDevice_MatchesFingerprint(t *testing.T) {
    device := &Device{
        Fingerprint: "sha256_value_123",
    }
    assert.True(t, device.MatchesFingerprint("sha256_value_123"))
    assert.False(t, device.MatchesFingerprint("different_value"))
}

// UseCase Test
func TestLoginUseCase_InvalidCredentials_ReturnsError(t *testing.T) {
    mockCognito := new(MockCognitoAuthPort)
    mockCognito.On("Authenticate", "01234567890", "password").Return(nil, ErrInvalidCredentials)
    
    uc := NewLoginUseCase(mockCognito, nil, nil, nil, nil)
    _, err := uc.Execute(ctx, LoginInput{PhoneNumber: "01234567890", Password: "password"})
    
    assert.ErrorIs(t, err, ErrInvalidCredentials)
}

func TestLoginUseCase_UserSuspended_ReturnsError(t *testing.T) {
    mockCognito := new(MockCognitoAuthPort)
    mockCognito.On("Authenticate", mock.Anything, mock.Anything).Return(
        &CognitoAuthResult{AccessToken: "token", IDToken: "id_token"},
        nil,
    )
    
    mockUser := new(MockUserRepository)
    mockUser.On("GetByCognitoSub", "cognito-sub-123").Return(
        &User{UserID: "user-1", Status: "SUSPENDED"},
        nil,
    )
    
    uc := NewLoginUseCase(mockCognito, mockUser, nil, nil, nil)
    _, err := uc.Execute(ctx, LoginInput{PhoneNumber: "0123...", Password: "pass"})
    
    assert.ErrorIs(t, err, ErrUserSuspended)
}

func TestRefreshTokenUseCase_TokenBlocked_ReturnsError(t *testing.T) {
    mockBlocked := new(MockBlockedTokenRepository)
    mockBlocked.On("Exists", "old_jti_123").Return(true, nil)
    
    uc := NewRefreshTokenUseCase(nil, mockBlocked, nil, nil)
    _, err := uc.Execute(ctx, RefreshTokenInput{RefreshToken: "..."})
    
    assert.ErrorIs(t, err, ErrTokenRevoked)
}

// Integration Test (MySQL)
func TestSessionRepository_RevokeByUserID(t *testing.T) {
    db := setupTestDB()
    defer db.Close()
    
    repo := NewMySQLSessionRepository(db)
    
    // Insert test sessions
    session1 := &Session{SessionID: "s1", UserID: "user-1", DeviceID: "d1", IsRevoked: false}
    session2 := &Session{SessionID: "s2", UserID: "user-1", DeviceID: "d2", IsRevoked: false}
    
    repo.Create(ctx, session1)
    repo.Create(ctx, session2)
    
    // Revoke all
    count, err := repo.RevokeByUserID(ctx, "user-1", nil)
    
    assert.NoError(t, err)
    assert.Equal(t, int64(2), count)
    
    // Verify both are revoked
    s1, _ := repo.GetBySessionID(ctx, "s1")
    assert.True(t, s1.IsRevoked)
}

// Integration Test (Redis)
func TestBlockedTokenRepository_ExpirationCleanup(t *testing.T) {
    redis := setupTestRedis()
    defer redis.Close()
    
    repo := NewRedisBlockedTokenRepository(redis)
    
    expiredToken := &BlockedToken{
        JTI:       "jti-expired",
        ExpiresAt: time.Now().Add(-1 * time.Hour), // 過去
        BlockedAt: time.Now().Add(-2 * time.Hour),
    }
    
    repo.Add(ctx, expiredToken)
    
    // Cleanup
    count, _ := repo.DeleteExpired(ctx, time.Now())
    assert.Equal(t, int64(1), count)
    
    // Verify deleted
    exists, _ := repo.Exists(ctx, "jti-expired")
    assert.False(t, exists)
}
```

## 8. エラーハンドリング

### ドメインエラー

- ErrInvalidPhoneNumber: 電話番号フォーマット不正
- ErrInvalidPassword: パスワード形式不正 (5文字未満)
- ErrInvalidCredentials: Cognito認証失敗（電話番号またはパスワード不正）
- ErrUserNotFound: ユーザーがローカルDBに存在しない
- ErrUserSuspended: ユーザーステータスがSUSPENDED
- ErrAccessTokenExpired: AccessToken有効期限切れ
- ErrRefreshTokenExpired: RefreshToken有効期限切れ
- ErrTokenRevoked: JTIがBlockedTokensに存在する
- ErrInvalidToken: JWTの署名・形式・issuer検証失敗
- ErrTokenBlacklisted: トークンが無効化リストに存在（ログアウト・ユーザーサスペンド後）
- ErrDeviceNotFound: デバイスレコードが存在しない
- ErrSessionNotFound: セッションレコードが存在しない
- ErrDeviceFingerprintMismatch: デバイスフィンガープリント不一致（Device偽装検知）
- ErrSessionInvalid: セッションが無効化・期限切れ
- ErrRateLimitExceeded: ログイン試行回数が制限を超過（電話番号単位 1分5回）
- ErrCognitoUnavailable: Cognito接続失敗
- ErrPermissionServiceUnavailable: Permission Service gRPC接続失敗
- ErrDatabaseError: MySQL操作エラー
- ErrRedisError: Redis操作エラー

### エラー → HTTPステータスマッピング

| ドメインエラー                  | HTTPステータス            | ユーザーメッセージ                                         |
| ------------------------------- | ------------------------- | ---------------------------------------------------------- |
| ErrInvalidPhoneNumber           | 400 Bad Request           | Phone number format is invalid. Please use E.164 format.   |
| ErrInvalidPassword              | 400 Bad Request           | Password must be at least 5 characters.                    |
| ErrInvalidCredentials           | 401 Unauthorized          | Invalid phone number or password.                          |
| ErrUserNotFound                 | 404 Not Found             | User not found.                                            |
| ErrUserSuspended                | 403 Forbidden             | Your account has been suspended.                           |
| ErrAccessTokenExpired           | 401 Unauthorized          | Access token has expired. Please refresh.                  |
| ErrRefreshTokenExpired          | 401 Unauthorized          | Refresh token has expired. Please log in again.            |
| ErrTokenRevoked                 | 401 Unauthorized          | Token has been revoked. Please log in again.               |
| ErrInvalidToken                 | 401 Unauthorized          | Invalid or malformed authentication token.                 |
| ErrDeviceNotFound               | 404 Not Found             | Device not found.                                          |
| ErrSessionNotFound              | 404 Not Found             | Session not found.                                         |
| ErrDeviceFingerprintMismatch    | 403 Forbidden             | Device fingerprint mismatch. Possible unauthorized access. |
| ErrSessionInvalid               | 401 Unauthorized          | Session is invalid or expired.                             |
| ErrRateLimitExceeded            | 429 Too Many Requests     | Too many login attempts. Please try again in 1 minute.     |
| ErrCognitoUnavailable           | 503 Service Unavailable   | Authentication service temporarily unavailable.            |
| ErrPermissionServiceUnavailable | 503 Service Unavailable   | Permission service temporarily unavailable.                |
| ErrDatabaseError                | 500 Internal Server Error | An internal error occurred. Please try again later.        |
| ErrRedisError                   | 500 Internal Server Error | An internal error occurred. Please try again later.        |

## 9. SQL スキーマ例

### users テーブル

```sql
CREATE TABLE users (
    user_id UUID PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone_number VARCHAR(20) UNIQUE NOT NULL,
    cognito_sub VARCHAR(255) UNIQUE NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE', -- ACTIVE, SUSPENDED
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sync_version BIGINT NOT NULL DEFAULT 0,
    
    INDEX idx_cognito_sub (cognito_sub),
    INDEX idx_phone_number (phone_number),
    INDEX idx_status (status)
);
```

### sessions テーブル

```sql
CREATE TABLE sessions (
    session_id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    access_token_jti UUID NOT NULL,
    refresh_token_jti UUID NOT NULL,
    issued_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    access_expires_at TIMESTAMP NOT NULL,
    refresh_expires_at TIMESTAMP NOT NULL,
    ip_address VARCHAR(45),
    user_agent TEXT,
    is_revoked BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_user_id (user_id),
    INDEX idx_device_id (device_id),
    INDEX idx_access_token_jti (access_token_jti),
    INDEX idx_refresh_token_jti (refresh_token_jti),
    INDEX idx_is_revoked (is_revoked),
    INDEX idx_access_expires_at (access_expires_at)
);
```

### devices テーブル

```sql
CREATE TABLE devices (
    device_id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_name VARCHAR(255) NOT NULL,
    device_type VARCHAR(50) NOT NULL, -- iOS, Web, Android
    os_version VARCHAR(50),
    app_version VARCHAR(50),
    fingerprint VARCHAR(64) NOT NULL, -- SHA256
    last_seen_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_archived BOOLEAN NOT NULL DEFAULT FALSE,
    
    INDEX idx_user_id (user_id),
    INDEX idx_fingerprint (fingerprint),
    INDEX idx_is_archived (is_archived),
    UNIQUE idx_user_fingerprint (user_id, fingerprint)
);
```

### refresh_token_grants テーブル

```sql
CREATE TABLE refresh_token_grants (
    grant_id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    old_jti UUID NOT NULL,
    new_jti UUID NOT NULL,
    device_id UUID NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    requested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    granted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_ip VARCHAR(45),
    
    INDEX idx_user_id (user_id),
    INDEX idx_device_id (device_id),
    INDEX idx_old_jti (old_jti),
    INDEX idx_new_jti (new_jti),
    INDEX idx_granted_at (granted_at)
);
```

## 10. 未決事項

### 質問・決定事項

| #   | 質問                                                                                                         | ステータス | 決定                                                                                                                           |
| --- | ------------------------------------------------------------------------------------------------------------ | ---------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 1   | AccessToken有効期限は1時間固定か、ユーザー/デバイス単位で調整可能にするか                                    | Open       | 初期は1時間固定。将来的にセキュリティポリシーで設定可能にする方針で検討中                                                      |
| 2   | RefreshToken 30日の有効期限中に新デバイスからRefreshされた場合の扱い。新セッション扱いか継続扱いか           | Open       | 新セッション扱い。device_idが異なれば新登録とする。Fraud detectionは権限チェックでカバー                                       |
| 3   | ユーザーがサスペンドされた際、既存トークンの無効化は QueuePort 経由か直接DBか                               | Resolved   | QueuePort 経由（Beta: Redis+BullMQ、本番: OCI Queue）で即座に BlockedTokens に追加。API Gateway・Permission Service への通知は 1～5 秒以内 |
| 4   | Device Fingerprintの計算方法が確定しているか。Device Idempotencyをどう保証するか                             | Open       | 初期案：SHA256(device_type + os_version + app_version)。客户端で再計算可能なので改ざん困難。ただし偽装検知後の対応フロー要検討 |
| 5   | Cognitoへの認証時に MFA （多要素認証） 対応が必要か。将来の拡張性確保すべきか                                | Open       | 初期は電話番号+パスワードのみ。MFA対応はロードマップに記載し、future-proofな設計を維持                                         |
| 6   | MySQLがダウンした場合の Read-Only レプリカへのフェイルオーバーフロー                                         | Open       | 未決定。接続プーリング・リトライロジック・監視アラート設定後に確定                                                             |
| 7   | RedisがダウンしたときBlockedTokensチェックの Fail-Open vs Fail-Closed                                        | Open       | 初期は Fail-Closed (全ユーザーログイン拒否)。セキュリティとユーザー体験のバランス後に再評価予定                                |
| 8   | ログアウト時に該当セッションのIPアドレス・User-Agent をクライアントに返すべきか（Suspicious activity警告用） | Resolved   | 返す。ただしセッション一覧 API (`GET /api/auth/sessions`) に限定し、現在リクエスト中のセッションのみ IP と User-Agent を詳細化。アクセスログ自体は Audit Service に蓄積し、クライアントには最小情報のみ |

---

最終更新: 2026-04-19 ポリシー適用

