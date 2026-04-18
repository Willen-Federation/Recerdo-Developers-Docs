# クリーンアーキテクチャ設計書

| 項目                      | 値                                         |
| ------------------------- | ------------------------------------------ |
| **モジュール/サービス名** | Authentication Service (recuerdo-auth-svc) |
| **作成者**                | Akira                                      |
| **作成日**                | 2026-04-13                                 |
| **ステータス**            | ドラフト                                   |
| **バージョン**            | 1.0                                        |

---

## 1. 概要
### 1.1 目的
Authentication Service は Recuerdo プラットフォーム全体の認証・トークン管理を司る。AWS Cognito とローカルデータベースを統合し、ユーザーログイン、トークン更新、デバイス追跡、トークン無効化を提供する。マイクロサービス間の信頼基盤として、JWT (RS256) による安全なトークン発行と検証をサポートする。

### 1.2 ビジネスコンテキスト
Recuerdo では、ユーザー認証は基本的な要件。複数デバイス、セッション管理、アクセストークン/リフレッシュトークンの分離、ユーザー停止チェック等、複雑な認証フローが必要。AWS Cognito をアイデンティティプロバイダーとして使用し、ローカルDB で追加のメタデータ（デバイス、セッション）を管理する。

### 1.3 アーキテクチャ原則
- **単一責任の原則**: 認証・トークン管理に専念し、ビジネスロジック非依存
- **依存性の逆転**: リポジトリ・外部サービスはインターフェース経由で依存
- **層間の厳密な分離**: Entities → UseCases → Adapters → Frameworks の一方向依存
- **テスト可能性**: すべてのユースケースはインターフェース依存、モック可能
- **セキュリティ重視**: トークン署名検証、パスワードハッシング、デバイストラッキング

---

## 2. レイヤーアーキテクチャ
### 2.1 アーキテクチャ図
```
┌─────────────────────────────────────────────────────┐
│  Frameworks & Drivers (フレームワーク＆ドライバ)     │
│  Gin, MySQL, Redis, AWS Cognito, SQS          │
└─────────────────────────────────────────────────────┘
                         ▲
                         │ (依存)
┌─────────────────────────────────────────────────────┐
│  Interface Adapters (インターフェースアダプタ)       │
│  HTTP Controllers, Repository Impl, Presenters      │
└─────────────────────────────────────────────────────┘
                         ▲
                         │ (依存)
┌─────────────────────────────────────────────────────┐
│  Application Business Rules (アプリケーション)       │
│  Use Cases, DTOs, Port Interfaces                   │
└─────────────────────────────────────────────────────┘
                         ▲
                         │ (依存)
┌─────────────────────────────────────────────────────┐
│  Enterprise Business Rules (エンティティ/ドメイン)   │
│  Domain Models, Value Objects, Domain Events        │
└─────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール
外側のレイヤーは内側に依存し、内側は外側に依存しない。データ流は入力アダプタ → ユースケース → 出力アダプタ の一方向。外側のレイヤー間通信はポート（インターフェース）経由のみ。

---

## 3. エンティティ層（ドメイン）
### 3.1 ドメインモデル

| エンティティ名     | 説明                               | 主要フィールド                                           |
| ------------------ | ---------------------------------- | -------------------------------------------------------- |
| User               | ローカルユーザー キャッシュ        | userId, cognitoSub, email, createdAt, updatedAt          |
| UserSession        | ユーザーセッション                 | sessionId, userId, refreshTokenJti, createdAt, expiresAt |
| DeviceRegistration | ユーザーデバイス情報               | deviceId, userId, fingerprint, deviceName, lastSeenAt    |
| BlockedToken       | 無効化されたトークン               | tokenJti, userId, revokedAt, expiresAt                   |
| RefreshTokenGrant  | リフレッシュトークンの払い出し記録 | grantId, userId, jti, issuedAt, expiresAt, revokedAt     |

### 3.2 値オブジェクト

| 値オブジェクト        | 説明                                  | 不変性 |
| --------------------- | ------------------------------------- | ------ |
| AccessToken           | アクセストークン (1h TTL)             | Yes    |
| RefreshToken          | リフレッシュトークン (30d TTL)        | Yes    |
| DeviceFingerprint     | デバイス識別子 (User-Agent + IP hash) | Yes    |
| CognitoUserAttributes | AWS Cognito ユーザー属性              | Yes    |
| TokenClaims           | JWT クレーム (sub, exp, iat, aud)     | Yes    |

### 3.3 ドメインルール / 不変条件
- 各 User は一意の cognitoSub を保持し、複数登録は禁止
- AccessToken の TTL は常に 3600 秒
- RefreshToken の TTL は常に 2592000 秒 (30 日)
- BlockedToken に含まれるトークンはいかなる場合でも再使用不可
- ユーザーが SUSPENDED 状態の場合、ログイン不可
- DeviceRegistration の lastSeenAt は各リクエスト時に更新
- RefreshTokenGrant は revokedAt なしで一度だけ有効

### 3.4 ドメインイベント

| イベント名             | 発火条件             | ペイロード                               |
| ---------------------- | -------------------- | ---------------------------------------- |
| auth.user_login        | ログイン成功         | userId, sessionId, deviceId, timestamp   |
| auth.user_logout       | ログアウト成功       | userId, sessionId, timestamp             |
| auth.token_revoked     | トークン無効化       | jti, userId, revokedAt, expiresAt        |
| auth.device_registered | 新デバイス登録       | userId, deviceId, fingerprint, timestamp |
| auth.cognito_synced    | Cognito ユーザー同期 | userId, cognitoSub, email, timestamp     |

### 3.5 エンティティ定義

```go
// Domain Entities
package domain

import "time"

// User represents a locally cached user from Cognito
type User struct {
	UserID       string
	CognitoSub   string    // Cognito's user UUID
	Email        string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

// UserSession represents an active login session
type UserSession struct {
	SessionID       string
	UserID          string
	RefreshTokenJti string    // JWT ID of associated refresh token
	CreatedAt       time.Time
	ExpiresAt       time.Time
}

// DeviceRegistration tracks user devices
type DeviceRegistration struct {
	DeviceID      string
	UserID        string
	Fingerprint   string    // Hash of User-Agent + IP
	DeviceName    string    // e.g., "Chrome on MacOS"
	LastSeenAt    time.Time
	RegisteredAt  time.Time
}

// BlockedToken represents a revoked JWT
type BlockedToken struct {
	TokenJti  string
	UserID    string
	RevokedAt time.Time
	ExpiresAt time.Time
}

// RefreshTokenGrant tracks refresh token issuance
type RefreshTokenGrant struct {
	GrantID   string
	UserID    string
	JTI       string    // JWT ID
	IssuedAt  time.Time
	ExpiresAt time.Time
	RevokedAt *time.Time
}

// Value Objects
type AccessToken struct {
	Token     string
	Claims    TokenClaims
	ExpiresAt time.Time
}

type RefreshToken struct {
	Token     string
	JTI       string
	ExpiresAt time.Time
}

type TokenClaims struct {
	Sub      string                 // Cognito Sub
	Exp      int64                  // Expiration (unix)
	Iat      int64                  // Issued at (unix)
	Aud      string                 // Audience
	Custom   map[string]interface{} // Custom claims
}

type DeviceFingerprint struct {
	Value string
}

type CognitoUserAttributes struct {
	Sub       string
	Email     string
	EmailVerified bool
	Name      string
	UpdatedAt int64
}
```

---

## 4. ユースケース層（アプリケーション）
### 4.1 ユースケース一覧

| ユースケース       | アクター             | 説明                                           | 優先度 |
| ------------------ | -------------------- | ---------------------------------------------- | ------ |
| Login (main)       | User                 | メールとパスワードでログイン、トークン発行     | HIGH   |
| Logout             | User                 | セッション無効化、トークン無効化               | HIGH   |
| RefreshToken       | User                 | リフレッシュトークンからアクセストークン再発行 | HIGH   |
| RegisterDevice     | System               | 新デバイス登録またはlastSeenAt更新             | HIGH   |
| SyncCognito        | System               | Cognito ユーザーをローカルDBに同期             | MEDIUM |
| RevokeToken        | System               | トークンをブロックリストに追加                 | HIGH   |
| ValidateToken      | System (API Gateway) | トークン署名・有効性検証 (gRPC)                | HIGH   |
| ListActiveSessions | User                 | ユーザーのアクティブセッション一覧取得         | MEDIUM |

### 4.2 ユースケース詳細 - Login

**アクター**: User (Web/Mobile client)

**事前条件**:
- ユーザーが Cognito に登録済み
- Username/Password が有効
- User が SUSPENDED 状態ではない

**フロー**:
1. HostedUIにログイン要求 (InitiateAuth API)
2. AWS Cognito に認証要求 (InitiateAuth API)
3. Cognito から ID Token + Access Token + Refresh Token を受け取る
4. ID Token から Cognito User Attributes を抽出
5. ローカル DB で User が存在するか確認
6. User が存在しない場合、SyncCognito ユースケース実行 (新規作成)
7. Permission Service で User が SUSPENDED かチェック
8. SUSPENDED の場合、ユースケース終了、エラー返却
9. DeviceRegistration テーブルで deviceFingerprint をチェック
10. 既存デバイスの場合、lastSeenAt 更新; 新規デバイスの場合、RegisterDevice ユースケース実行
11. UserSession 新規作成
12. RefreshTokenGrant レコード作成（Refresh Token JTI を記録）
13. AccessToken・RefreshToken を Response DTO で返す
14. auth.user_login イベント発行（SQS）

**事後条件**:
- ユーザーがセッション取得
- トークン (AccessToken + RefreshToken) が返される
- デバイス登録完了

**エラーケース**:
- Cognito 認証失敗 → 401 Unauthorized
- User が SUSPENDED → 403 Forbidden
- デバイス登録失敗 → 500 Internal Server Error

### 4.3 入出力DTO

```go
// Application DTOs
package application

import "time"

// ===== Login Use Case =====
type LoginInput struct {
	Email      string
	Password   string
	DeviceID   string // Client-provided device identifier
	Fingerprint string // User-Agent + IP hash
}

type LoginOutput struct {
	UserID       string
	SessionID    string
	AccessToken  string
	RefreshToken string
	ExpiresIn    int // Access token TTL in seconds
	TokenType    string // "Bearer"
}

// ===== Logout Use Case =====
type LogoutInput struct {
	UserID     string
	SessionID  string
	RefreshTokenJti string
}

type LogoutOutput struct {
	Success   bool
	RevokedAt time.Time
}

// ===== RefreshToken Use Case =====
type RefreshTokenInput struct {
	RefreshToken string
}

type RefreshTokenOutput struct {
	AccessToken string
	ExpiresIn   int
	TokenType   string
}

// ===== RegisterDevice Use Case =====
type RegisterDeviceInput struct {
	UserID      string
	DeviceID    string
	Fingerprint string
	DeviceName  string
}

type RegisterDeviceOutput struct {
	DeviceID   string
	RegisteredAt time.Time
}

// ===== SyncCognito Use Case =====
type SyncCognitoInput struct {
	CognitoSub string
	Email      string
	Name       string
}

type SyncCognitoOutput struct {
	UserID      string
	CreatedAt   time.Time
	IsNewUser   bool
}

// ===== RevokeToken Use Case =====
type RevokeTokenInput struct {
	TokenJti  string
	UserID    string
	ExpiresAt time.Time
}

type RevokeTokenOutput struct {
	Success   bool
	RevokedAt time.Time
}
```

### 4.4 リポジトリインターフェース（ポート）

```go
// Application Ports - Repository Interfaces
package ports

import (
	"context"
	"time"
)

// UserRepository ユーザー管理
type UserRepository interface {
	FindByCognitoSub(ctx context.Context, cognitoSub string) (*User, error)
	FindByUserID(ctx context.Context, userID string) (*User, error)
	Save(ctx context.Context, user *User) error
	Update(ctx context.Context, user *User) error
}

// UserSessionRepository セッション管理
type UserSessionRepository interface {
	FindBySessionID(ctx context.Context, sessionID string) (*UserSession, error)
	FindActiveByUserID(ctx context.Context, userID string) ([]*UserSession, error)
	Save(ctx context.Context, session *UserSession) error
	Delete(ctx context.Context, sessionID string) error
}

// DeviceRegistrationRepository デバイス管理
type DeviceRegistrationRepository interface {
	FindByUserIDAndFingerprint(ctx context.Context, userID, fingerprint string) (*DeviceRegistration, error)
	FindByUserID(ctx context.Context, userID string) ([]*DeviceRegistration, error)
	Save(ctx context.Context, device *DeviceRegistration) error
	UpdateLastSeen(ctx context.Context, deviceID string) error
}

// BlockedTokenRepository トークンブロックリスト
type BlockedTokenRepository interface {
	IsBlocked(ctx context.Context, jti string) (bool, error)
	Add(ctx context.Context, jti string, expiresAt time.Time) error
	RemoveExpired(ctx context.Context) error
}

// RefreshTokenGrantRepository リフレッシュトークン払い出し記録
type RefreshTokenGrantRepository interface {
	FindByJTI(ctx context.Context, jti string) (*RefreshTokenGrant, error)
	Save(ctx context.Context, grant *RefreshTokenGrant) error
	RevokeByUserID(ctx context.Context, userID string) error
}

// EventPublisher イベント発行
type EventPublisher interface {
	Publish(ctx context.Context, eventType string, payload map[string]interface{}) error
}
```

### 4.5 外部サービスインターフェース（ポート）

```go
// Application Ports - External Service Interfaces
package ports

import "context"

// CognitoAuthProvider AWS Cognito 認証
type CognitoAuthProvider interface {
	InitiateAuth(ctx context.Context, email, password string) (*CognitoAuthResponse, error)
	GetUserAttributes(ctx context.Context, accessToken string) (*CognitoUserAttributes, error)
}

type CognitoAuthResponse struct {
	IDToken      string
	AccessToken  string
	RefreshToken string
	ExpiresIn    int
}

// PermissionServiceClient Permission Service (gRPC) 権限チェック
type PermissionServiceClient interface {
	CheckUserSuspended(ctx context.Context, userID string) (bool, error)
}

// TokenSigningProvider JWT トークン署名
type TokenSigningProvider interface {
	GenerateAccessToken(ctx context.Context, claims TokenClaims) (string, error)
	GenerateRefreshToken(ctx context.Context, userID, jti string) (string, error)
	VerifyAccessToken(ctx context.Context, token string) (*TokenClaims, error)
	VerifyRefreshToken(ctx context.Context, token string) (*TokenClaims, error)
}
```

---

## 5. インターフェースアダプタ層
### 5.1 コントローラ / ハンドラ

| コントローラ        | HTTPメソッド | エンドポイント     | 説明                                             |
| ------------------- | ------------ | ------------------ | ------------------------------------------------ |
| LoginHandler        | POST         | /api/auth/login    | HostedUIにリダイレクトでログイン                 |
| LogoutHandler       | POST         | /api/auth/logout   | ログアウト、トークン無効化                       |
| RefreshTokenHandler | POST         | /api/auth/refresh  | リフレッシュトークン使用、アクセストークン再発行 |
| SyncHandler         | POST         | /api/auth/sync     | Cognito user を同期（内部用）                    |
| SessionListHandler  | GET          | /api/auth/sessions | アクティブセッション一覧取得                     |
| HealthCheckHandler  | GET          | /health            | サービス稼働確認                                 |

### 5.2 プレゼンター / レスポンスマッパー

**プレゼンター役割**: アプリケーション層の Output DTO を HTTP レスポンスに変換。

**レスポンスマッパー例**:

```json
{
  "user_id": "user-123",
  "session_id": "sess-456",
  "access_token": "eyJhbGc...",
  "refresh_token": "eyJhbGc...",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

**エラーレスポンス**:
```json
{
  "error": "INVALID_CREDENTIALS",
  "message": "Email or password is incorrect",
  "timestamp": "2026-04-13T10:30:45Z"
}
```

### 5.3 リポジトリ実装（アダプタ）

| リポジトリ実装                    | 技術スタック        | 説明                             |
| --------------------------------- | ------------------- | -------------------------------- |
| MySQLUserRepository               | Database/sql + sqlc | ユーザーレコード CRUD            |
| MySQLUserSessionRepository        | Database/sql + sqlc | セッションレコード CRUD          |
| MySQLDeviceRegistrationRepository | Database/sql + sqlc | デバイスレコード CRUD            |
| RedisBlockedTokenRepository       | Redis (go-redis/v9) | トークンブロックリスト           |
| MySQLRefreshTokenGrantRepository  | Database/sql + sqlc | リフレッシュトークン払い出し記録 |
| SQSEventPublisher                 | AWS SDK             | イベント発行                     |

### 5.4 外部サービスアダプタ

| アダプタ                     | 外部サービス              | 説明                                  |
| ---------------------------- | ------------------------- | ------------------------------------- |
| AWSCognitoAuthAdapter        | AWS Cognito               | AWS SDK で InitiateAuth, GetUser 実行 |
| GRPCPermissionServiceAdapter | gRPC (Permission Service) | CheckUserSuspended gRPC 呼び出し      |
| RSATokenSigningAdapter       | RS256 署名                | JWKS 秘密鍵で JWT 署名、検証          |

### 5.5 マッパー

```go
// Mappers - Domain ↔ DTO conversion
package adapters

import "domain"
import "application"

// MapLoginInputToDomain HTTP request → Domain login context
func MapLoginInputToDomain(input *LoginInput) *domain.LoginContext {
	return &domain.LoginContext{
		Email:       input.Email,
		DeviceID:    input.DeviceID,
		Fingerprint: input.Fingerprint,
	}
}

// MapCognitoResponseToUser Cognito response → Domain User entity
func MapCognitoResponseToUser(cognitoAttrs *domain.CognitoUserAttributes) *domain.User {
	return &domain.User{
		CognitoSub: cognitoAttrs.Sub,
		Email:      cognitoAttrs.Email,
		CreatedAt:  time.Now(),
		UpdatedAt:  time.Now(),
	}
}

// MapUserSessionToOutput Domain session → HTTP response DTO
func MapUserSessionToOutput(session *domain.UserSession, accessToken, refreshToken string) *LoginOutput {
	return &LoginOutput{
		SessionID:    session.SessionID,
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    3600,
		TokenType:    "Bearer",
	}
}
```

---

## 6. フレームワーク＆ドライバ層（インフラストラクチャ）
### 6.1 Webフレームワーク
- **Framework**: Gin Web Framework (github.com/gin-gonic/gin)
- **Port**: 8080 (HTTP)
- **TLS**: 本番環境では mTLS (Kubernetes ServiceAccount)
- **Health Check**: /health エンドポイント (Kubernetes liveness probe)
- **Request Logging**: 構造化ログ (JSON format, OpenTelemetry)

### 6.2 データベース
**Primary Database**: MySQL 15.x

**MySQL テーブル スキーマ**:

```sql
-- Users table
CREATE TABLE users (
  user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cognito_sub VARCHAR(255) UNIQUE NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_cognito_sub (cognito_sub),
  INDEX idx_email (email)
);

-- User Sessions table
CREATE TABLE user_sessions (
  session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  refresh_token_jti VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL,
  INDEX idx_user_id (user_id),
  INDEX idx_refresh_token_jti (refresh_token_jti),
  INDEX idx_expires_at (expires_at)
);

-- Device Registrations table
CREATE TABLE device_registrations (
  device_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  fingerprint VARCHAR(255) NOT NULL,
  device_name VARCHAR(255),
  last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  registered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(user_id, fingerprint),
  INDEX idx_user_id (user_id),
  INDEX idx_last_seen_at (last_seen_at)
);

-- Refresh Token Grants table
CREATE TABLE refresh_token_grants (
  grant_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  jti VARCHAR(255) UNIQUE NOT NULL,
  issued_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL,
  revoked_at TIMESTAMP,
  INDEX idx_user_id (user_id),
  INDEX idx_jti (jti),
  INDEX idx_expires_at (expires_at)
);

-- Blocked Tokens table (for archival; Redis が primary)
CREATE TABLE blocked_tokens (
  token_jti VARCHAR(255) PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  revoked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL,
  INDEX idx_user_id (user_id),
  INDEX idx_expires_at (expires_at)
);

-- Audit Log table
CREATE TABLE auth_audit_log (
  log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(user_id) ON DELETE SET NULL,
  action VARCHAR(50) NOT NULL, -- LOGIN, LOGOUT, TOKEN_REFRESH, DEVICE_REGISTER, etc.
  result VARCHAR(20) NOT NULL, -- SUCCESS, FAILURE
  detail TEXT,
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_user_id (user_id),
  INDEX idx_action (action),
  INDEX idx_created_at (created_at)
);
```

**Redis スキーマ** (Blocked Tokens キャッシュ):

```
# Blocked tokens (Set で高速チェック)
SET blocked_tokens:jti-uuid-123 1 EX 86400

# Refresh token blacklist (Optional for faster revocation)
SET revoked_refresh_tokens:jti-456 1 EX 2592000
```

### 6.3 メッセージブローカー
- **Broker**: AWS SQS
- **Event Topics**:
  - `auth.user_login` - ログイン成功
  - `auth.user_logout` - ログアウト
  - `auth.token_revoked` - トークン無効化
  - `auth.device_registered` - デバイス登録
  - `auth.cognito_synced` - Cognito 同期

**SQS Event Message Format** (JSON):
```json
{
  "event_type": "auth.user_login",
  "timestamp": "2026-04-13T10:30:45Z",
  "payload": {
    "user_id": "user-123",
    "session_id": "sess-456",
    "device_id": "dev-789",
    "ip_address": "203.0.113.42"
  }
}
```

### 6.4 外部ライブラリ＆SDK

| ライブラリ                    | バージョン | 用途                             |
| ----------------------------- | ---------- | -------------------------------- |
| github.com/gin-gonic/gin      | v1.9.1     | HTTP Web Framework               |
| github.com/lib/pq             | v1.10.9    | MySQL driver                     |
| github.com/redis/go-redis/v9  | v9.0.5     | Redis client                     |
| github.com/golang-jwt/jwt/v5  | v5.0.0     | JWT 生成・検証                   |
| github.com/lestrrat-go/jwx/v2 | v2.0.0     | JWKS 処理                        |
| github.com/aws/aws-sdk-go-v2  | v1.17.0    | AWS SDK (Cognito, SQS)           |
| google.golang.org/grpc        | v1.56.0    | gRPC client (Permission Service) |
| github.com/sqlc-dev/sqlc      | v1.19.0    | SQL code generation              |
| go.opentelemetry.io/api       | v1.16.0    | OpenTelemetry (Logging, Tracing) |
| github.com/uber-go/fx         | v1.19.0    | Dependency injection framework   |

### 6.5 依存性注入

```go
// Infrastructure - Dependency Injection (uber-go/fx)
package infrastructure

import (
	"context"
	"go.uber.org/fx"
	"database/sql"
	"github.com/redis/go-redis/v9"
	"github.com/gin-gonic/gin"
	"google.golang.org/grpc"
)

// Module provides all infrastructure dependencies
var Module = fx.Module("infrastructure",
	fx.Provide(
		// MySQL
		provideDatabaseConnection,

		// Redis
		provideRedisClient,

		// AWS Cognito
		provideCognitoClient,

		// AWS SQS
		provideSQSClient,

		// gRPC clients
		providePermissionServiceClient,

		// Repositories
		provideUserRepository,
		provideUserSessionRepository,
		provideDeviceRegistrationRepository,
		provideBlockedTokenRepository,
		provideRefreshTokenGrantRepository,

		// External Service Adapters
		provideCognitoAuthAdapter,
		providePermissionServiceAdapter,
		provideTokenSigningAdapter,

		// Event Publisher
		provideSQSEventPublisher,

		// Gin Engine
		provideGinEngine,

		// Controllers/Handlers
		provideLoginHandler,
		provideLogoutHandler,
		provideRefreshTokenHandler,
		provideSyncHandler,

		// Use Cases
		provideLoginUseCase,
		provideLogoutUseCase,
		provideRefreshTokenUseCase,
		provideRegisterDeviceUseCase,
		provideSyncCognitoUseCase,
		provideRevokeTokenUseCase,
	),
)

func provideDatabaseConnection() (*sql.DB, error) {
	return sql.Open("MySQL", "MySQL://user:pass@db:5432/recuerdo")
}

func provideRedisClient() *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr: "redis:6379",
	})
}

func provideGinEngine(
	loginHandler *LoginHandler,
	logoutHandler *LogoutHandler,
	refreshHandler *RefreshTokenHandler,
) *gin.Engine {
	engine := gin.Default()

	// Routes
	engine.POST("/api/auth/login", loginHandler.Handle)
	engine.POST("/api/auth/logout", logoutHandler.Handle)
	engine.POST("/api/auth/refresh", refreshHandler.Handle)
	engine.GET("/api/auth/sessions", sessionListHandler)
	engine.GET("/health", healthCheckHandler)

	return engine
}

func main() {
	app := fx.New(
		fx.Module("recuerdo-auth-svc",
			infrastructure.Module,
		),
		fx.Invoke(startServer),
	)
	app.Run()
}
```

---

## 7. ディレクトリ構成

```
recuerdo-auth-svc/
├── cmd/
│   └── main.go                   # エントリーポイント
├── domain/
│   ├── entities.go               # User, UserSession, Device, etc.
│   ├── value_objects.go          # AccessToken, RefreshToken, etc.
│   └── events.go                 # Domain events
├── application/
│   ├── dto/
│   │   └── dto.go                # Input/Output DTOs
│   ├── ports/
│   │   ├── repository.go         # Repository interfaces
│   │   └── external.go           # External service interfaces
│   └── usecases/
│       ├── login.go              # Login use case
│       ├── logout.go             # Logout use case
│       ├── refresh_token.go      # RefreshToken use case
│       ├── register_device.go    # RegisterDevice use case
│       ├── sync_cognito.go       # SyncCognito use case
│       ├── revoke_token.go       # RevokeToken use case
│       └── validate_token.go     # ValidateToken use case (gRPC)
├── adapters/
│   ├── handlers/
│   │   ├── login_handler.go
│   │   ├── logout_handler.go
│   │   ├── refresh_handler.go
│   │   └── session_handler.go
│   ├── repositories/
│   │   ├── MySQL_user.go
│   │   ├── MySQL_session.go
│   │   ├── MySQL_device.go
│   │   ├── redis_blocked_token.go
│   │   └── MySQL_refresh_grant.go
│   ├── external/
│   │   ├── cognito_adapter.go
│   │   ├── permission_grpc.go
│   │   └── token_signing.go
│   ├── mappers/
│   │   └── mappers.go            # Domain ↔ DTO mappings
│   └── presenters/
│       └── response_mapper.go    # Output → HTTP response
├── infrastructure/
│   ├── config.go                 # Configuration loading
│   ├── db.go                     # MySQL setup
│   ├── redis.go                  # Redis client setup
│   ├── aws.go                    # AWS SDK setup
│   ├── grpc.go                   # gRPC client setup
│   └── di.go                     # Dependency injection (fx module)
├── go.mod
├── go.sum
├── Dockerfile
└── k8s/
    ├── deployment.yaml           # Kubernetes Deployment
    ├── service.yaml              # Service definition
    ├── configmap.yaml            # Configuration ConfigMap
    └── statefulset-MySQL.yaml # MySQL StatefulSet (optional)
```

---

## 8. 依存性ルールと境界
### 8.1 許可される依存関係

| ソース層   | ターゲット層 | 許可 | 理由                                   |
| ---------- | ------------ | ---- | -------------------------------------- |
| Frameworks | Adapters     | Yes  | アダプタはフレームワークを使用         |
| Frameworks | UseCases     | No   | ビジネスロジックはフレームワーク非依存 |
| Adapters   | UseCases     | Yes  | ハンドラはユースケース呼び出し         |
| Adapters   | Entities     | Yes  | マッパーがドメインモデルを使用         |
| UseCases   | Entities     | Yes  | ビジネスロジック実行                   |
| UseCases   | Frameworks   | No   | 外部フレームワーク非依存               |
| Entities   | 他すべて     | No   | エンティティはビジネスロジックのみ     |

### 8.2 境界の横断
**許可される方法**:
1. **ポート/インターフェース**: 内側のレイヤーがインターフェース定義、外側が実装
2. **DTO**: レイヤー間のデータ転送用（ドメインモデルは未公開）
3. **ドメインイベント**: 非同期・疎結合通信

**禁止される方法**:
- 直接 import（例：usecase が gin.Context 直接使用）
- DB モデルの外部公開
- フレームワーク型の内部レイヤーへの波及

### 8.3 ルールの強制
**アーキテクチャ監視**:
- GitHub Actions で import グラフの循環参照検出
- staticcheck で禁止パターン検出
- Code review での手動チェック

```bash
# CI で実行
go mod graph | grep -E "usecase.*adapter|entity.*framework" && exit 1 || exit 0
```

---

## 9. テスト戦略
### 9.1 テストピラミッド

| テストレベル      | 割合 | テスト対象                             | ツール                      |
| ----------------- | ---- | -------------------------------------- | --------------------------- |
| Unit Tests        | 70%  | ユースケース、値オブジェクト、マッパー | testing, testify/assert     |
| Integration Tests | 20%  | リポジトリ実装、外部サービスアダプタ   | testcontainers              |
| E2E Tests         | 10%  | HTTP エンドポイント、完全フロー        | Go httptest, Docker Compose |

### 9.2 テスト例

```go
// Unit Tests - Login Use Case
package application

import (
	"context"
	"testing"
	"time"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

// Test Case 1: Login - Successful authentication and session creation
func TestLogin_Success(t *testing.T) {
	// Arrange
	mockCognitoAuth := new(MockCognitoAuthProvider)
	mockUserRepo := new(MockUserRepository)
	mockSessionRepo := new(MockUserSessionRepository)
	mockDeviceRepo := new(MockDeviceRegistrationRepository)
	mockPermissionClient := new(MockPermissionServiceClient)
	mockTokenSigner := new(MockTokenSigningProvider)
	mockEventPublisher := new(MockEventPublisher)

	cognitoAttrs := &domain.CognitoUserAttributes{
		Sub:   "cognito-sub-123",
		Email: "user@example.com",
	}

	mockCognitoAuth.On("InitiateAuth", mock.Anything, "user@example.com", "password").
		Return(&domain.CognitoAuthResponse{
			IDToken:      "id-token",
			AccessToken:  "cognito-access-token",
			RefreshToken: "refresh-token",
			ExpiresIn:    3600,
		}, nil)

	mockCognitoAuth.On("GetUserAttributes", mock.Anything, "cognito-access-token").
		Return(cognitoAttrs, nil)

	mockUserRepo.On("FindByCognitoSub", mock.Anything, "cognito-sub-123").
		Return(&domain.User{
			UserID:     "user-123",
			CognitoSub: "cognito-sub-123",
			Email:      "user@example.com",
		}, nil)

	mockPermissionClient.On("CheckUserSuspended", mock.Anything, "user-123").
		Return(false, nil)

	mockDeviceRepo.On("FindByUserIDAndFingerprint", mock.Anything, "user-123", "fingerprint-xyz").
		Return(nil, nil) // New device

	mockDeviceRepo.On("Save", mock.Anything, mock.Anything).Return(nil)

	mockSessionRepo.On("Save", mock.Anything, mock.Anything).Return(nil)

	mockTokenSigner.On("GenerateAccessToken", mock.Anything, mock.Anything).
		Return("generated-access-token", nil)

	mockTokenSigner.On("GenerateRefreshToken", mock.Anything, "user-123", mock.Anything).
		Return("generated-refresh-token", nil)

	mockEventPublisher.On("Publish", mock.Anything, "auth.user_login", mock.Anything).
		Return(nil)

	useCase := NewLoginUseCase(
		mockCognitoAuth,
		mockUserRepo,
		mockSessionRepo,
		mockDeviceRepo,
		mockPermissionClient,
		mockTokenSigner,
		mockEventPublisher,
	)

	input := &LoginInput{
		Email:       "user@example.com",
		Password:    "password",
		DeviceID:    "device-456",
		Fingerprint: "fingerprint-xyz",
	}

	// Act
	output, err := useCase.Execute(context.Background(), input)

	// Assert
	assert.NoError(t, err)
	assert.Equal(t, "user-123", output.UserID)
	assert.Equal(t, "generated-access-token", output.AccessToken)
	assert.Equal(t, "generated-refresh-token", output.RefreshToken)
	assert.Equal(t, "Bearer", output.TokenType)
	assert.Equal(t, 3600, output.ExpiresIn)

	mockCognitoAuth.AssertCalled(t, "InitiateAuth", mock.Anything, "user@example.com", "password")
	mockPermissionClient.AssertCalled(t, "CheckUserSuspended", mock.Anything, "user-123")
	mockEventPublisher.AssertCalled(t, "Publish", mock.Anything, "auth.user_login", mock.Anything)
}

// Test Case 2: Login - User suspended
func TestLogin_UserSuspended(t *testing.T) {
	mockCognitoAuth := new(MockCognitoAuthProvider)
	mockUserRepo := new(MockUserRepository)
	mockPermissionClient := new(MockPermissionServiceClient)

	mockCognitoAuth.On("InitiateAuth", mock.Anything, "user@example.com", "password").
		Return(&domain.CognitoAuthResponse{IDToken: "id", AccessToken: "at", RefreshToken: "rt", ExpiresIn: 3600}, nil)

	mockCognitoAuth.On("GetUserAttributes", mock.Anything, "at").
		Return(&domain.CognitoUserAttributes{Sub: "sub-123", Email: "user@example.com"}, nil)

	mockUserRepo.On("FindByCognitoSub", mock.Anything, "sub-123").
		Return(&domain.User{UserID: "user-123", CognitoSub: "sub-123"}, nil)

	mockPermissionClient.On("CheckUserSuspended", mock.Anything, "user-123").
		Return(true, nil) // User is suspended

	useCase := NewLoginUseCase(
		mockCognitoAuth,
		mockUserRepo,
		nil,
		nil,
		mockPermissionClient,
		nil,
		nil,
	)

	input := &LoginInput{Email: "user@example.com", Password: "password"}

	// Act
	output, err := useCase.Execute(context.Background(), input)

	// Assert
	assert.Error(t, err)
	assert.Nil(t, output)
	assert.Contains(t, err.Error(), "suspended")
}

// Test Case 3: RefreshToken - Generate new access token
func TestRefreshToken_Success(t *testing.T) {
	mockTokenSigner := new(MockTokenSigningProvider)
	mockGrantRepo := new(MockRefreshTokenGrantRepository)
	mockSessionRepo := new(MockUserSessionRepository)

	claims := &domain.TokenClaims{
		Sub: "cognito-sub-123",
		Exp: time.Now().Add(30 * 24 * time.Hour).Unix(),
		Iat: time.Now().Unix(),
	}

	mockTokenSigner.On("VerifyRefreshToken", mock.Anything, "refresh-token").
		Return(claims, nil)

	grant := &domain.RefreshTokenGrant{
		GrantID:   "grant-1",
		UserID:    "user-123",
		JTI:       "jti-refresh",
		ExpiresAt: time.Now().Add(30 * 24 * time.Hour),
		RevokedAt: nil,
	}

	mockGrantRepo.On("FindByJTI", mock.Anything, "jti-refresh").Return(grant, nil)

	mockTokenSigner.On("GenerateAccessToken", mock.Anything, mock.MatchedBy(func(c domain.TokenClaims) bool {
		return c.Sub == "cognito-sub-123"
	})).Return("new-access-token", nil)

	useCase := NewRefreshTokenUseCase(mockTokenSigner, mockGrantRepo, mockSessionRepo)

	input := &RefreshTokenInput{RefreshToken: "refresh-token"}

	// Act
	output, err := useCase.Execute(context.Background(), input)

	// Assert
	assert.NoError(t, err)
	assert.Equal(t, "new-access-token", output.AccessToken)
	assert.Equal(t, 3600, output.ExpiresIn)
	assert.Equal(t, "Bearer", output.TokenType)

	mockTokenSigner.AssertCalled(t, "VerifyRefreshToken", mock.Anything, "refresh-token")
	mockGrantRepo.AssertCalled(t, "FindByJTI", mock.Anything, "jti-refresh")
}

// Integration Test: MySQL UserRepository
func TestMySQLUserRepository_Integration(t *testing.T) {
	// Setup testcontainers
	ctx := context.Background()
	container, dbURL, err := setupMySQLContainer(ctx)
	assert.NoError(t, err)
	defer container.Terminate(ctx)

	db, err := sql.Open("MySQL", dbURL)
	assert.NoError(t, err)
	defer db.Close()

	repo := NewMySQLUserRepository(db)

	// Create user
	user := &domain.User{
		UserID:     "user-123",
		CognitoSub: "cognito-sub-456",
		Email:      "test@example.com",
		CreatedAt:  time.Now(),
		UpdatedAt:  time.Now(),
	}

	// Act: Save
	err = repo.Save(ctx, user)
	assert.NoError(t, err)

	// Act: FindByCognitoSub
	retrieved, err := repo.FindByCognitoSub(ctx, "cognito-sub-456")
	assert.NoError(t, err)
	assert.NotNil(t, retrieved)
	assert.Equal(t, "test@example.com", retrieved.Email)
}
```

---

## 10. エラーハンドリング
### 10.1 ドメインエラー

- **InvalidCredentials**: Cognito 認証失敗
- **UserNotFound**: User が存在しない
- **UserSuspended**: User が SUSPENDED 状態
- **TokenExpired**: アクセストークンまたはリフレッシュトークン期限切れ
- **InvalidRefreshToken**: リフレッシュトークンが無効（署名・クレーム不正）
- **TokenRevoked**: トークンがブロックリストに含まれている

### 10.2 アプリケーションエラー

- **CognitoServiceUnavailable**: AWS Cognito 接続失敗
- **DatabaseError**: MySQL クエリ失敗
- **PermissionServiceError**: Permission Service gRPC 失敗
- **DeviceRegistrationError**: デバイス登録失敗
- **SessionCreationError**: セッション作成失敗

### 10.3 エラー変換

| ドメイン/アプリエラー     | HTTPステータス            | レスポンスBody                                         |
| ------------------------- | ------------------------- | ------------------------------------------------------ |
| InvalidCredentials        | 401 Unauthorized          | `{"error": "INVALID_CREDENTIALS", "message": "..."}`   |
| UserNotFound              | 404 Not Found             | `{"error": "USER_NOT_FOUND", "message": "..."}`        |
| UserSuspended             | 403 Forbidden             | `{"error": "USER_SUSPENDED", "message": "..."}`        |
| TokenExpired              | 401 Unauthorized          | `{"error": "TOKEN_EXPIRED", "message": "..."}`         |
| InvalidRefreshToken       | 401 Unauthorized          | `{"error": "INVALID_REFRESH_TOKEN", "message": "..."}` |
| CognitoServiceUnavailable | 503 Service Unavailable   | `{"error": "SERVICE_UNAVAILABLE"}`                     |
| DatabaseError             | 500 Internal Server Error | `{"error": "INTERNAL_SERVER_ERROR"}`                   |

---

## 11. 横断的関心事
### 11.1 ロギング
**構造化ログ** (JSON、OpenTelemetry):
```json
{
  "timestamp": "2026-04-13T10:30:45.123Z",
  "level": "INFO",
  "service": "auth-svc",
  "user_id": "user-123",
  "action": "LOGIN",
  "result": "SUCCESS",
  "ip_address": "203.0.113.42",
  "device_id": "dev-456",
  "duration_ms": 234,
  "trace_id": "trace-uuid"
}
```

**監査ログ**: すべての認証関連アクション（LOGIN, LOGOUT, TOKEN_REFRESH, DEVICE_REGISTER）を audit_log テーブルに記録。

### 11.2 認証・認可
- **認証**: AWS Cognito (メール/パスワード)
- **認可**: Permission Service gRPC でユーザー状態チェック (SUSPENDED)
- **トークン管理**: JWT (RS256), AccessToken (1h), RefreshToken (30d)

### 11.3 バリデーション
- HTTP リクエスト: Content-Type (application/json), Body JSON 形式
- Email バリデーション: RFC 5322 準拠
- Password バリデーション: Cognito ポリシー適用
- JWT クレーム: exp, iat, sub, aud 検証

### 11.4 キャッシング
- **User**: MySQL primary; Redis L1 キャッシュなし (一貫性重視)
- **Blocked Tokens**: Redis TTL (トークン exp まで)
- **JWKS**: Redis キャッシュ (更新頻度低)

---

## 12. マイグレーション計画
### 12.1 現状
既存の単一アプリケーションで認証をローカル実装。

### 12.2 目標状態
Authentication Service として独立、AWS Cognito 統合、トークン管理一元化。

### 12.3 マイグレーション手順

| フェーズ              | 期間     | 実施内容                                                | リスク         |
| --------------------- | -------- | ------------------------------------------------------- | -------------- |
| Phase 1: 準備         | Week 1-2 | Auth Service 開発完了、AWS Cognito テナント設定         | なし           |
| Phase 2: ステージング | Week 3   | ステージング環境デプロイ、統合テスト (10% ユーザー)     | パフォーマンス |
| Phase 3: 本番導入     | Week 4-5 | 本番環境デプロイ、段階的ユーザー移行 (10% → 50% → 100%) | 認証失敗       |
| Phase 4: 監視・調整   | Week 6+  | メトリクス監視、レイテンシー最適化                      | なし           |

**ロールバック計画**: API Gateway の設定変更で旧認証エンドポイントへ即座に戻す (< 1分)

---

## 13. 未決事項と決定事項

| #   | 項目                       | 現在の決定                           | 代替案           | 理由                             |
| --- | -------------------------- | ------------------------------------ | ---------------- | -------------------------------- |
| 1   | トークン署名アルゴリズム   | RS256 (RSA-SHA256)                   | HS256, EdDSA     | 公開鍵検証可能、セキュリティ標準 |
| 2   | AccessToken TTL            | 3600秒 (1時間)                       | 1800, 7200秒     | セキュリティと UX のバランス     |
| 3   | RefreshToken TTL           | 2592000秒 (30日)                     | 7日, 90日        | 既存 Cognito デフォルト          |
| 4   | ユーザー同期               | Cognito → LocalDB (キャッシュ)       | Cognito オンリー | レイテンシー削減、キャッシュ効率 |
| 5   | デバイスフィンガープリント | User-Agent + IP hash                 | TLS fingerprint  | 実装簡易、ブラウザ互換性         |
| 6   | トークン無効化方式         | Redis Blocklist (高速) + DB 監査ログ | DB のみ          | O(1) チェック速度                |

---

## 14. 参考資料
- Robert C. Martin, "Clean Architecture: A Craftsman's Guide to Software Structure and Design", 2017
- Mark Richards & Neal Ford, "Fundamentals of Software Architecture", 2020
- OAuth 2.0 Authorization Framework (RFC 6749): https://tools.ietf.org/html/rfc6749
- JWT (RFC 7519): https://tools.ietf.org/html/rfc7519
- AWS Cognito Documentation: https://docs.aws.amazon.com/cognito/
- MySQL Documentation: https://www.MySQL.org/docs/
- Redis Documentation: https://redis.io/documentation
- OpenTelemetry: https://opentelemetry.io/
