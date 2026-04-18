# クリーンアーキテクチャ設計書

| 項目                      | 値                                 |
| ------------------------- | ---------------------------------- |
| **モジュール/サービス名** | API Gateway (recuerdo-api-gateway) |
| **作成者**                | Akira                              |
| **作成日**                | 2026-04-13                         |
| **ステータス**            | ドラフト                           |
| **バージョン**            | 1.0                                |

---

## 1. 概要
### 1.1 目的
API Gatewayは、Recuerdoプラットフォーム全体の単一エントリポイントとして機能し、マイクロサービスアーキテクチャ全体のリクエスト/レスポンス処理を統括する。JWT認証、レート制限、サーキットブレーカー、WebSocketプロキシ、権限チェック、ルートマッピングを一元管理し、バックエンドサービスを保護する。

### 1.2 ビジネスコンテキスト
ユーザーが複数のマイクロサービス（Event Service、Album Service、Messaging Service等）と通信する際、統一された認証・認可・ルーティングレイヤーが必須。API Gatewayはそのためのセントラルハブとして機能し、ビジネスロジックから横断的関心事を分離する。

### 1.3 アーキテクチャ原則
- **単一責任の原則**: API Gatewayは認証・ルーティング・レート制限に専念し、ビジネスロジックを含まない
- **依存性の逆転**: すべての内向きな依存は利用ケースに向かう
- **層間の分離**: Entities → UseCases → Adapters → Frameworks という厳密な方向
- **テスト可能性**: すべての主要ロジックはインターフェース依存で、モック可能に設計
- **外部独立性**: フレームワーク・データベース・ライブラリの変更がビジネスロジックに影響しない

---

## 2. レイヤーアーキテクチャ
### 2.1 アーキテクチャ図
```
┌─────────────────────────────────────────────────────┐
│  Frameworks & Drivers (フレームワーク＆ドライバ)     │
│  Gin, Redis, SQS, OpenTelemetry, Kubernetes        │
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
外側のレイヤーは内側のレイヤーに依存する。内側のレイヤーは外側のレイヤーに一切依存しない。外側のレイヤー間の通信はインターフェース（ポート）を通じてのみ行われ、直接的な依存は禁止。

---

## 3. エンティティ層（ドメイン）
### 3.1 ドメインモデル

| エンティティ名       | 説明                                                     | 主要フィールド                                                  |
| -------------------- | -------------------------------------------------------- | --------------------------------------------------------------- |
| RouteDefinition      | 外部リクエストを内部マイクロサービスにマッピングする定義 | path, method, upstreamUrl, middlewares, timeout, retryPolicy    |
| AuthenticatedRequest | 認証済みHTTPリクエスト                                   | userId, requestId, path, method, headers, body, tokenClaims     |
| RateLimitWindow      | スライディングウィンドウレート制限の状態                 | userId, windowStart, requestCount, limit, windowSize            |
| BlockedToken         | 無効化されたJWTトークン                                  | tokenId, userId, revokedAt, expiresAt                           |
| CircuitBreakerState  | サーキットブレーカーの状態管理                           | upstreamUrl, state, failureCount, lastFailureTime, successCount |

### 3.2 値オブジェクト

| 値オブジェクト  | 説明                                               | 不変性 |
| --------------- | -------------------------------------------------- | ------ |
| JWT             | JWTトークン文字列と検証済みクレーム                | Yes    |
| JWKS            | JSON Web Key Set（公開キーセット）                 | Yes    |
| RequestPath     | HTTPメソッドとパス                                 | Yes    |
| UpstreamURL     | バックエンドサービスのURL                          | Yes    |
| RateLimitConfig | レート制限の設定（リクエスト数、ウィンドウサイズ） | Yes    |

### 3.3 ドメインルール / 不変条件
- JWTトークンは署名検証が必須。署名が無効な場合、リクエストは拒否される
- BlockedTokenリスト内のトークンはどのような場合でも受け入れられない
- CircuitBreakerStateがOPENの場合、すべてのリクエストは即座にエラーを返す
- RateLimitWindowの容量を超えたリクエストは429 Too Many Requestsを返す
- すべてのリクエストには一意のrequestIdが割り当てられ、トレーシングに使用される

### 3.4 ドメインイベント

| イベント名           | 発火条件                 | ペイロード                                         |
| -------------------- | ------------------------ | -------------------------------------------------- |
| AuthenticationFailed | JWT検証失敗              | requestId, userId, reason, timestamp               |
| RateLimitExceeded    | レート制限超過           | userId, path, windowStart, requestCount, timestamp |
| CircuitBreakerOpened | サーキットブレーカー遷移 | upstreamUrl, failureCount, timestamp               |
| TokenRevoked         | トークン無効化           | tokenId, userId, revokedAt                         |

### 3.5 エンティティ定義

```go
// Domain Entities
package domain

import "time"

// RouteDefinition represents an API route mapping
type RouteDefinition struct {
	ID              string
	Path            string            // e.g., "/api/friends/*"
	Method          string            // GET, POST, etc.
	UpstreamURL     string            // e.g., "http://friends-svc:8080"
	Middlewares     []string          // auth, ratelimit, logging, etc.
	TimeoutSeconds  int
	RetryPolicy     *RetryPolicy
	CircuitBreaker  *CircuitBreakerConfig
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// AuthenticatedRequest represents a validated HTTP request
type AuthenticatedRequest struct {
	RequestID       string
	UserID          string
	Path            string
	Method          string
	Headers         map[string]string
	Body            []byte
	TokenClaims     map[string]interface{}
	Timestamp       time.Time
}

// RateLimitWindow tracks requests within a time window
type RateLimitWindow struct {
	UserID         string
	WindowStart    time.Time
	RequestCount   int
	Limit          int
	WindowSizeMs   int64
}

// BlockedToken represents a revoked JWT
type BlockedToken struct {
	TokenID    string
	UserID     string
	RevokedAt  time.Time
	ExpiresAt  time.Time
}

// CircuitBreakerState manages circuit breaker state
type CircuitBreakerState struct {
	UpstreamURL    string
	State          string // CLOSED, OPEN, HALF_OPEN
	FailureCount   int
	SuccessCount   int
	LastFailureAt  time.Time
	LastSuccessAt  time.Time
	Threshold      int
}

// Value Objects
type JWT struct {
	Token  string
	Claims map[string]interface{}
}

type JWKS struct {
	Keys []map[string]interface{}
}
```

---

## 4. ユースケース層（アプリケーション）
### 4.1 ユースケース一覧

| ユースケース        | アクター       | 説明                                                                   | 優先度 |
| ------------------- | -------------- | ---------------------------------------------------------------------- | ------ |
| ProcessRequest      | ExternalClient | 外部からのHTTPリクエストを受け取り、認証・ルーティング・プロキシを実行 | HIGH   |
| AuthenticateRequest | System         | JWT検証とクレーム抽出を実行                                            | HIGH   |
| CheckRateLimit      | System         | ユーザーのレート制限チェック                                           | HIGH   |
| CheckPermission     | System         | Permission Serviceとの通信で権限確認                                   | HIGH   |
| RouteRequest        | System         | RouteDefinitionに基づいてバックエンドにルーティング                    | HIGH   |
| ProxyWebSocket      | ExternalClient | WebSocket接続をMessaging Serviceにプロキシ                             | MEDIUM |
| BlockToken          | System         | トークン無効化リスト内にトークンを追加                                 | HIGH   |
| ReloadRoutes        | Operator       | ConfigMapからRouteDefinitionを再読み込み                               | MEDIUM |

### 4.2 ユースケース詳細 - ProcessRequest

**アクター**: ExternalClient (Webブラウザ、モバイルアプリ)

**事前条件**: 
- HTTP リクエストが API Gateway に到達している
- RouteDefinitionsが正しく読み込まれている

**フロー**:
1. リクエストに一意のrequestIdを割り当てる
2. AuthenticationFailed イベントを購読し、失敗時処理を準備
3. AuthenticateRequest ユースケースを実行（JWT検証）
4. 認証失敗の場合、401 Unauthorizedを返す
5. CheckRateLimit ユースケースを実行
6. レート制限超過の場合、429 Too Many Requestsを返す
7. CheckPermission ユースケースを実行（Permission Service gRPC呼び出し）
8. 権限不足の場合、403 Forbiddenを返す
9. RouteRequest ユースケースを実行
10. バックエンドからのレスポンスをクライアントに返す

**事後条件**: 
- リクエストがバックエンドで処理され、レスポンスが返される
- 必要なイベントが SQS に発行される

**エラーケース**:
- JWT検証失敗 → 401 Unauthorized、AuthenticationFailed イベント発行
- トークンがブロックリスト内 → 401 Unauthorized
- レート制限超過 → 429 Too Many Requests、RateLimitExceeded イベント発行
- 権限不足 → 403 Forbidden
- サーキットブレーカーOPEN → 503 Service Unavailable、CircuitBreakerOpened イベント発行
- バックエンドタイムアウト → 504 Gateway Timeout

### 4.3 入出力DTO

```go
// Application DTOs
package application

import "time"

// ProcessRequestInput ユースケース入力
type ProcessRequestInput struct {
	Method          string
	Path            string
	Headers         map[string]string
	Body            []byte
	RemoteAddr      string
}

// ProcessRequestOutput ユースケース出力
type ProcessRequestOutput struct {
	StatusCode  int
	Headers     map[string]string
	Body        []byte
	RequestID   string
	ProcessedAt time.Time
}

// AuthenticateRequestInput 認証ユースケース入力
type AuthenticateRequestInput struct {
	AuthorizationHeader string
	RequestID           string
}

// AuthenticateRequestOutput 認証ユースケース出力
type AuthenticateRequestOutput struct {
	UserID      string
	TokenClaims map[string]interface{}
	TokenID     string
}

// CheckRateLimitInput レート制限チェック入力
type CheckRateLimitInput struct {
	UserID   string
	Endpoint string
}

// CheckRateLimitOutput レート制限チェック出力
type CheckRateLimitOutput struct {
	Allowed           bool
	RemainingQuota    int
	ResetAt           time.Time
	RetryAfterSeconds int
}

// CheckPermissionInput 権限チェック入力
type CheckPermissionInput struct {
	UserID   string
	Resource string
	Action   string
}

// CheckPermissionOutput 権限チェック出力
type CheckPermissionOutput struct {
	Allowed bool
	Reason  string
}

// RouteRequestInput ルーティング入力
type RouteRequestInput struct {
	AuthenticatedRequest *AuthenticatedRequest
	RouteDefinition      *RouteDefinition
}

// RouteRequestOutput ルーティング出力
type RouteRequestOutput struct {
	StatusCode int
	Headers    map[string]string
	Body       []byte
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

// RouteDefinitionRepository route定義の永続化と取得
type RouteDefinitionRepository interface {
	FindByPathAndMethod(ctx context.Context, path, method string) (*RouteDefinition, error)
	FindAll(ctx context.Context) ([]*RouteDefinition, error)
	Save(ctx context.Context, route *RouteDefinition) error
}

// BlockedTokenRepository ブロックリスト管理
type BlockedTokenRepository interface {
	IsBlocked(ctx context.Context, tokenID string) (bool, error)
	Add(ctx context.Context, tokenID string, expiresAt time.Time) error
	RemoveExpired(ctx context.Context) error
}

// RateLimitRepository レート制限ウィンドウ管理
type RateLimitRepository interface {
	GetWindow(ctx context.Context, userID, endpoint string) (*RateLimitWindow, error)
	IncrementAndCheck(ctx context.Context, userID, endpoint string, limit int, windowMs int64) (bool, int, error)
	ResetWindow(ctx context.Context, userID, endpoint string) error
}

// CircuitBreakerRepository サーキットブレーカー状態管理
type CircuitBreakerRepository interface {
	GetState(ctx context.Context, upstreamURL string) (*CircuitBreakerState, error)
	RecordSuccess(ctx context.Context, upstreamURL string) error
	RecordFailure(ctx context.Context, upstreamURL string) error
	Open(ctx context.Context, upstreamURL string) error
	Reset(ctx context.Context, upstreamURL string) error
}

// JWKSRepository JWKS キャッシュ管理
type JWKSRepository interface {
	Get(ctx context.Context) (*JWKS, error)
	Set(ctx context.Context, jwks *JWKS, ttl time.Duration) error
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

// CognitoJWKSProvider AWS Cognito JWKS取得
type CognitoJWKSProvider interface {
	GetJWKS(ctx context.Context) (*JWKS, error)
}

// PermissionServiceClient Permission Serviceへの gRPC クライアント
type PermissionServiceClient interface {
	CheckPermission(ctx context.Context, userID, resource, action string) (bool, error)
	CheckUserSuspended(ctx context.Context, userID string) (bool, error)
}

// UpstreamServiceClient バックエンドサービスへのHTTPクライアント
type UpstreamServiceClient interface {
	Do(ctx context.Context, method, url string, headers map[string]string, body []byte) (int, map[string]string, []byte, error)
}

// WebSocketProxyHandler WebSocketプロキシ
type WebSocketProxyHandler interface {
	ProxyWebSocket(ctx context.Context, userID, targetURL string) error
}
```

---

## 5. インターフェースアダプタ層
### 5.1 コントローラ / ハンドラ

| コントローラ             | HTTPメソッド                  | エンドポイント       | 説明                                                       |
| ------------------------ | ----------------------------- | -------------------- | ---------------------------------------------------------- |
| RequestHandler           | GET, POST, PUT, DELETE, PATCH | /*                   | メインリクエストハンドラー、すべてのHTTPメソッドをキャッチ |
| WebSocketHandler         | GET                           | /ws/*                | WebSocket接続を受け付け、Messaging Serviceにプロキシ       |
| HealthCheckHandler       | GET                           | /health              | API Gatewayの稼働状況確認                                  |
| MetricsHandler           | GET                           | /metrics             | Prometheus メトリクス公開                                  |
| AdminReloadRoutesHandler | POST                          | /admin/reload-routes | 管理者用ルート再読み込みエンドポイント                     |

### 5.2 プレゼンター / レスポンスマッパー

**プレゼンター役割**: アプリケーション層からのOutput DTOをHTTPレスポンスに変換する。

**レスポンスマッパー**:
- ProcessRequestOutput → HTTP Status Code + Headers + Body
- 認証失敗 → 401 JSON error response
- レート制限超過 → 429 JSON error response with Retry-After header
- 権限不足 → 403 JSON error response
- バックエンドエラー → 対応するHTTP status code

**エラーレスポンス形式**:
```json
{
  "error": "AUTHENTICATION_FAILED",
  "message": "Invalid JWT signature",
  "request_id": "req-12345",
  "timestamp": "2026-04-13T10:30:45Z"
}
```

### 5.3 リポジトリ実装（アダプタ）

| リポジトリ実装                | 技術スタック        | 説明                                             |
| ----------------------------- | ------------------- | ------------------------------------------------ |
| RedisBlockedTokenRepository   | Redis (go-redis/v9) | BlockedTokenをRedis Setで管理、TTL自動削除       |
| RedisRateLimitRepository      | Redis               | Sorted Setを使用したスライディングウィンドウ実装 |
| RedisCircuitBreakerRepository | Redis               | CircuitBreaker状態をRedis Stringで管理           |
| ConfigMapRouteRepository      | Kubernetes Client   | ConfigMapからROUTES.yamlを読み込み               |
| RedisJWKSRepository           | Redis               | Cognito JWKSをキャッシュ、定期的に更新           |
| SQSEventPublisher             | AWS SDK             | イベントをSQSキューに発行                        |

### 5.4 外部サービスアダプタ

| アダプタ                     | 外部サービス              | 説明                                                             |
| ---------------------------- | ------------------------- | ---------------------------------------------------------------- |
| AWSCognitoJWKSAdapter        | AWS Cognito               | JWKS公開キーをHTTP経由で取得                                     |
| GRPCPermissionServiceAdapter | gRPC (Permission Service) | 権限チェックをPermission Serviceに委譲                           |
| HTTPUpstreamServiceAdapter   | HTTP                      | バックエンドへのHTTPリクエストを実行、タイムアウト・リトライ実装 |
| GorillaWebSocketAdapter      | gorilla/websocket         | WebSocket接続をMessaging Serviceにプロキシ                       |

### 5.5 マッパー

**ドメイン ↔ DTO マッピング**:

```go
// Mappers
package adapters

import "domain"
import "application"

// MapProcessRequestInputToDomain HTTP request → Domain AuthenticatedRequest
func MapProcessRequestInputToDomain(input *ProcessRequestInput, userID string, claims map[string]interface{}) *domain.AuthenticatedRequest {
	return &domain.AuthenticatedRequest{
		RequestID:   generateRequestID(),
		UserID:      userID,
		Path:        input.Path,
		Method:      input.Method,
		Headers:     input.Headers,
		Body:        input.Body,
		TokenClaims: claims,
		Timestamp:   time.Now(),
	}
}

// MapDomainToProcessRequestOutput Domain output → HTTP response
func MapDomainToProcessRequestOutput(output *domain.RouteRequestOutput) *application.ProcessRequestOutput {
	return &application.ProcessRequestOutput{
		StatusCode:  output.StatusCode,
		Headers:     output.Headers,
		Body:        output.Body,
		RequestID:   output.RequestID,
		ProcessedAt: time.Now(),
	}
}
```

---

## 6. フレームワーク＆ドライバ層（インフラストラクチャ）
### 6.1 Webフレームワーク
- **Framework**: Gin Web Framework (github.com/gin-gonic/gin)
- **TLS**: 本番環境ではCloudflareで自動証明書更新
- **Port**: 8080 (HTTP), 8443 (HTTPS)
- **CORS**: 設定可能、デフォルトはレストリクティブ
- **Request Logging**: 構造化ログ（JSON形式、OpenTelemetryと統合）

### 6.2 データベース
**データベース**: Redis 7.x + Kubernetes ConfigMap

**Redis データ構造**:

```
# Blocked Tokens (Set)
SET blocked_tokens:token-uuid-123 1 EX 3600

# Rate Limit Windows (Sorted Set)
ZADD rate_limits:user-123:api.friends 1681395000000 req-1
ZADD rate_limits:user-123:api.friends 1681395005000 req-2
...

# Circuit Breaker State (Hash)
HSET cb:friends-svc state CLOSED
HSET cb:friends-svc failure_count 0
HSET cb:friends-svc success_count 15

# JWKS Cache (String)
SET jwks:cognito "{...}" EX 86400

# Route Definitions (String) - ConfigMapから同期
SET routes:config "YAML content here"
```

**ConfigMap YAML Schema** (routes.yaml):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-gateway-routes
  namespace: recuerdo
data:
  routes.yaml: |
    routes:
      - id: friends-service
        path: /api/friends/*
        method: "*"
        upstreamUrl: http://friends-svc.recuerdo.svc.cluster.local:8080
        middlewares:
          - auth
          - ratelimit
          - logging
        timeoutSeconds: 30
        circuitBreaker:
          threshold: 5
          timeout: 60
          halfOpenRequests: 1
        retryPolicy:
          maxRetries: 3
          backoffMs: 100

      - id: memory-service
        path: /api/memories/*
        method: "*"
        upstreamUrl: http://memory-svc.recuerdo.svc.cluster.local:8080
        middlewares:
          - auth
          - ratelimit
          - logging
        timeoutSeconds: 30
        circuitBreaker:
          threshold: 5
          timeout: 60
```

### 6.3 メッセージブローカー
- **Broker**: SQS
- **Topics**:
  - `auth.token_revoked` - トークン無効化イベント
  - `api-gateway.authentication_failed` - 認証失敗
  - `api-gateway.rate_limit_exceeded` - レート制限超過
  - `api-gateway.circuit_breaker_opened` - サーキットブレーカー開

**SQS Event Format** (JSON):
```json
{
  "event_type": "auth.token_revoked",
  "timestamp": "2026-04-13T10:30:45Z",
  "payload": {
    "token_id": "jti-uuid-123",
    "user_id": "user-456",
    "revoked_at": "2026-04-13T10:30:00Z"
  }
}
```

### 6.4 外部ライブラリ＆SDK

| ライブラリ                    | バージョン | 用途                                       |
| ----------------------------- | ---------- | ------------------------------------------ |
| github.com/gin-gonic/gin      | v1.9.1     | HTTPウェブフレームワーク                   |
| github.com/redis/go-redis/v9  | v9.0.5     | Redisクライアント                          |
| github.com/gorilla/websocket  | v1.5.0     | WebSocketハンドラ                          |
| github.com/golang-jwt/jwt/v5  | v5.0.0     | JWT解析・検証                              |
| github.com/lestrrat-go/jwx/v2 | v2.0.0     | JWKS処理                                   |
| go.temporal.io/api            | latest     | トレーシング用メタデータ                   |
| github.com/fsnotify/fsnotify  | v1.6.0     | ConfigMap ファイルウォッチ                 |
| go.opentelemetry.io/api       | v1.16.0    | OpenTelemetry (ログ・メトリクス・トレース) |
| github.com/uber-go/fx         | v1.19.0    | 依存性注入フレームワーク                   |

### 6.5 依存性注入

```go
// Infrastructure - Dependency Injection
package infrastructure

import (
	"context"
	"go.uber.org/fx"
	"github.com/redis/go-redis/v9"
	"github.com/gin-gonic/gin"
)

// Module provides all infrastructure dependencies
var Module = fx.Module("infrastructure",
	fx.Provide(
		// Redis
		provideRedisClient,

		// HTTP Client
		provideHTTPClient,

		// AWS SDK
		provideAWSConfig,
		provideSQSClient,
		provideCognitoClient,

		// gRPC clients
		providePermissionServiceClient,

		// Repositories
		provideBlockedTokenRepository,
		provideRateLimitRepository,
		provideCircuitBreakerRepository,
		provideJWKSRepository,
		provideRouteDefinitionRepository,

		// External Service Adapters
		provideCognitoJWKSAdapter,
		providePermissionServiceAdapter,
		provideUpstreamServiceAdapter,

		// Event Publisher
		provideSQSEventPublisher,

		// Gin Engine
		provideGinEngine,

		// Controllers
		provideRequestHandler,
		provideWebSocketHandler,

		// Use Cases
		provideProcessRequestUseCase,
		provideAuthenticateRequestUseCase,
		provideCheckRateLimitUseCase,
		provideCheckPermissionUseCase,
		provideRouteRequestUseCase,
		provideBlockTokenUseCase,
		provideReloadRoutesUseCase,
	),
)

func provideRedisClient() *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr: "redis:6379",
	})
}

func provideGinEngine(
	requestHandler *RequestHandler,
	wsHandler *WebSocketHandler,
) *gin.Engine {
	engine := gin.Default()

	// Mount handlers
	engine.Any("/*path", requestHandler.Handle)
	engine.GET("/ws/*path", wsHandler.Handle)
	engine.GET("/health", healthCheck)
	engine.GET("/metrics", metricsHandler)
	engine.POST("/admin/reload-routes", adminReloadRoutes)

	return engine
}

func main() {
	app := fx.New(
		fx.Module("recuerdo-api-gateway",
			infrastructure.Module,
			handlers.Module,
		),
		fx.Invoke(startServer),
	)
	app.Run()
}
```

---

## 7. ディレクトリ構成

```
recuerdo-api-gateway/
├── cmd/
│   └── main.go                 # エントリーポイント
├── domain/
│   ├── entities.go             # RouteDefinition, AuthenticatedRequest, etc.
│   ├── value_objects.go        # JWT, JWKS, RateLimitConfig
│   └── events.go               # Domain events
├── application/
│   ├── dto/
│   │   └── dto.go              # Input/Output DTOs
│   ├── ports/
│   │   ├── repository.go       # Repository interfaces
│   │   └── external.go         # External service interfaces
│   └── usecases/
│       ├── process_request.go  # ProcessRequest use case
│       ├── authenticate.go     # AuthenticateRequest use case
│       ├── ratelimit.go        # CheckRateLimit use case
│       ├── permission.go       # CheckPermission use case
│       ├── route.go            # RouteRequest use case
│       ├── proxy.go            # WebSocket proxy use case
│       ├── block_token.go      # BlockToken use case
│       └── reload_routes.go    # ReloadRoutes use case
├── adapters/
│   ├── handlers/
│   │   ├── request_handler.go  # HTTP request handler
│   │   ├── websocket_handler.go
│   │   └── admin_handler.go
│   ├── repositories/
│   │   ├── redis_blocked_token.go
│   │   ├── redis_ratelimit.go
│   │   ├── redis_circuitbreaker.go
│   │   ├── redis_jwks.go
│   │   └── configmap_routes.go
│   ├── external/
│   │   ├── cognito_adapter.go
│   │   ├── permission_grpc.go
│   │   └── upstream_http.go
│   ├── mappers/
│   │   └── mappers.go          # Domain ↔ DTO mappings
│   └── presenters/
│       └── response_mapper.go  # Output → HTTP response
├── infrastructure/
│   ├── config.go               # Configuration loading
│   ├── redis.go                # Redis client setup
│   ├── http.go                 # HTTP client factory
│   ├── aws.go                  # AWS SDK setup
│   ├── grpc.go                 # gRPC client setup
│   ├── routes_watcher.go       # ConfigMap fsnotify watcher
│   └── di.go                   # Dependency injection (fx module)
├── go.mod
├── go.sum
├── Dockerfile
└── k8s/
    ├── deployment.yaml         # Kubernetes Deployment
    ├── service.yaml            # Service definition
    ├── configmap.yaml          # Routes ConfigMap
    └── ingress.yaml            # Ingress configuration
```

---

## 8. 依存性ルールと境界
### 8.1 許可される依存関係

| ソース層   | ターゲット層 | 許可 | 理由                                   |
| ---------- | ------------ | ---- | -------------------------------------- |
| Frameworks | Adapters     | Yes  | アダプタはフレームワークを使用         |
| Frameworks | UseCases     | No   | ビジネスロジックはフレームワーク非依存 |
| Adapters   | UseCases     | Yes  | アダプタはユースケース呼び出し         |
| Adapters   | Entities     | Yes  | データ構造化のため                     |
| UseCases   | Entities     | Yes  | ビジネスロジック実行                   |
| UseCases   | Frameworks   | No   | 外部フレームワーク非依存               |
| Entities   | 他すべて     | No   | エンティティはビジネスロジックのみ     |

### 8.2 境界の横断
**許可される横断方法**:
1. **ポート/インターフェース**: 内側のレイヤーがインターフェースを定義し、外側のレイヤーが実装
2. **DTO**: データ構造化と転送用（ドメインモデルの直接公開は禁止）
3. **イベント**: ドメインイベント経由の疎結合通信

**禁止される横断方法**:
- 直接的なimport（例：UseCaseが gin.Context を直接参照）
- データベースモデルの外部公開
- フレームワーク固有の型の内部レイヤーへの波及

### 8.3 ルールの強制
**アーキテクチャ監視**:
- go-detect-cycles を使用したサイクル検出
- GitHub Actions CI で import パターンをチェック
- Code review でアーキテクチャ違反を指摘

**コード例**:
```bash
# CI workflow で実行
go mod graph | grep -E "usecase.*adapter|entity.*framework" && exit 1 || exit 0
```

---

## 9. テスト戦略
### 9.1 テストピラミッド

| テストレベル      | 割合 | テスト対象                                     | ツール                      |
| ----------------- | ---- | ---------------------------------------------- | --------------------------- |
| Unit Tests        | 70%  | 各ユースケース、値オブジェクト、ドメインルール | testing, testify/assert     |
| Integration Tests | 20%  | リポジトリ実装、外部サービスアダプタ           | testcontainers, Docker      |
| E2E Tests         | 10%  | HTTP エンドポイント、完全フロー                | Go httptest, Docker Compose |

### 9.2 テスト例

```go
// Unit Tests
package application

import (
	"context"
	"testing"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

// Test Case 1: ProcessRequest - Successful authentication and routing
func TestProcessRequest_Success(t *testing.T) {
	// Arrange
	mockBlockedTokenRepo := new(MockBlockedTokenRepository)
	mockRateLimitRepo := new(MockRateLimitRepository)
	mockPermissionClient := new(MockPermissionServiceClient)
	mockRouteRepo := new(MockRouteDefinitionRepository)
	mockUpstreamClient := new(MockUpstreamServiceClient)

	mockBlockedTokenRepo.On("IsBlocked", mock.Anything, "token-123").Return(false, nil)
	mockRateLimitRepo.On("IncrementAndCheck", mock.Anything, "user-456", "/api/friends", 1000, 60000).Return(true, 999, nil)
	mockPermissionClient.On("CheckPermission", mock.Anything, "user-456", "/api/friends", "GET").Return(true, nil)
	mockRouteRepo.On("FindByPathAndMethod", mock.Anything, "/api/friends", "GET").Return(&domain.RouteDefinition{
		UpstreamURL: "http://friends-svc:8080",
	}, nil)
	mockUpstreamClient.On("Do", mock.Anything, "GET", mock.Anything, mock.Anything, mock.Anything).Return(200, map[string]string{}, []byte(`{"friends": []}`), nil)

	useCase := NewProcessRequestUseCase(
		mockBlockedTokenRepo,
		mockRateLimitRepo,
		mockPermissionClient,
		mockRouteRepo,
		mockUpstreamClient,
	)

	input := &ProcessRequestInput{
		Method:  "GET",
		Path:    "/api/friends",
		Headers: map[string]string{"Authorization": "Bearer token-123"},
	}

	// Act
	output, err := useCase.Execute(context.Background(), input)

	// Assert
	assert.NoError(t, err)
	assert.Equal(t, 200, output.StatusCode)
	assert.Equal(t, `{"friends": []}`, string(output.Body))
	mockBlockedTokenRepo.AssertCalled(t, "IsBlocked", mock.Anything, "token-123")
}

// Test Case 2: ProcessRequest - Token in blocked list
func TestProcessRequest_TokenBlocked(t *testing.T) {
	mockBlockedTokenRepo := new(MockBlockedTokenRepository)
	mockBlockedTokenRepo.On("IsBlocked", mock.Anything, "token-blocked").Return(true, nil)

	useCase := NewProcessRequestUseCase(mockBlockedTokenRepo, nil, nil, nil, nil)

	input := &ProcessRequestInput{
		Method:  "GET",
		Path:    "/api/friends",
		Headers: map[string]string{"Authorization": "Bearer token-blocked"},
	}

	// Act
	output, err := useCase.Execute(context.Background(), input)

	// Assert
	assert.Error(t, err)
	assert.Equal(t, 401, output.StatusCode)
	assert.Contains(t, string(output.Body), "token revoked")
}

// Test Case 3: CheckRateLimit - Quota exceeded
func TestCheckRateLimit_QuotaExceeded(t *testing.T) {
	mockRateLimitRepo := new(MockRateLimitRepository)
	mockRateLimitRepo.On("IncrementAndCheck", mock.Anything, "user-999", "/api/friends", 100, 60000).Return(false, 0, nil)

	useCase := NewCheckRateLimitUseCase(mockRateLimitRepo)

	input := &CheckRateLimitInput{
		UserID:   "user-999",
		Endpoint: "/api/friends",
	}

	// Act
	output, err := useCase.Execute(context.Background(), input)

	// Assert
	assert.NoError(t, err)
	assert.False(t, output.Allowed)
	assert.Equal(t, 0, output.RemainingQuota)
}

// Integration Test: Redis RateLimitRepository
func TestRedisRateLimitRepository_Integration(t *testing.T) {
	// Use testcontainers for Redis
	ctx := context.Background()
	container, err := createRedisContainer(ctx)
	assert.NoError(t, err)
	defer container.Terminate(ctx)

	client := redis.NewClient(&redis.Options{
		Addr: "localhost:6379",
	})
	repo := NewRedisRateLimitRepository(client)

	// Act: First request
	allowed1, remaining1, err := repo.IncrementAndCheck(ctx, "user-123", "api", 5, 60000)
	assert.NoError(t, err)
	assert.True(t, allowed1)
	assert.Equal(t, 4, remaining1)

	// Act: Fill up quota
	for i := 0; i < 4; i++ {
		allowed, _, _ := repo.IncrementAndCheck(ctx, "user-123", "api", 5, 60000)
		assert.True(t, allowed)
	}

	// Act: Exceed quota
	allowed6, _, err := repo.IncrementAndCheck(ctx, "user-123", "api", 5, 60000)
	assert.NoError(t, err)
	assert.False(t, allowed6)
}
```

---

## 10. エラーハンドリング
### 10.1 ドメインエラー

- **InvalidJWT**: JWT署名が無効な場合
- **TokenRevoked**: トークンがブロックリスト内の場合
- **RateLimitExceeded**: ユーザーのレート制限を超えた場合
- **PermissionDenied**: ユーザーにリソースアクセス権限がない場合
- **CircuitBreakerOpen**: バックエンドサーキットブレーカーが開いている場合

### 10.2 アプリケーションエラー

- **RouteNotFound**: マッチするRouteDefinitionが見つからない場合
- **UpstreamServiceError**: バックエンドサービスがエラーを返した場合
- **UpstreamTimeout**: バックエンドがタイムアウトした場合
- **JWKSFetchError**: Cognito JWKSを取得できない場合
- **PermissionServiceUnavailable**: Permission Service gRPCが失敗した場合

### 10.3 エラー変換

| ドメイン/アプリエラー | HTTPステータス          | レスポンスBody                                       |
| --------------------- | ----------------------- | ---------------------------------------------------- |
| InvalidJWT            | 401 Unauthorized        | `{"error": "INVALID_JWT", "message": "..."}`         |
| TokenRevoked          | 401 Unauthorized        | `{"error": "TOKEN_REVOKED", "message": "..."}`       |
| RateLimitExceeded     | 429 Too Many Requests   | `{"error": "RATE_LIMIT", "retry_after": 60}`         |
| PermissionDenied      | 403 Forbidden           | `{"error": "PERMISSION_DENIED", "message": "..."}`   |
| CircuitBreakerOpen    | 503 Service Unavailable | `{"error": "SERVICE_UNAVAILABLE", "message": "..."}` |
| RouteNotFound         | 404 Not Found           | `{"error": "NOT_FOUND", "message": "..."}`           |
| UpstreamTimeout       | 504 Gateway Timeout     | `{"error": "GATEWAY_TIMEOUT", "message": "..."}`     |
| UpstreamServiceError  | 5xx (proxy)             | プロキシレスポンス                                   |

---

## 11. 横断的関心事
### 11.1 ロギング
**構造化ログ** (JSON、OpenTelemetry): 
```json
{
  "timestamp": "2026-04-13T10:30:45.123Z",
  "level": "INFO",
  "service": "api-gateway",
  "request_id": "req-uuid-123",
  "user_id": "user-456",
  "method": "GET",
  "path": "/api/friends",
  "status_code": 200,
  "duration_ms": 145,
  "trace_id": "trace-789"
}
```

**レベル**: DEBUG, INFO, WARN, ERROR

### 11.2 認証・認可
- **認証**: JWT (RS256) 署名検証 + BlockedToken チェック
- **認可**: Permission Service gRPC で CheckPermission
- **セッション**: Stateless (各リクエストで JWT 検証)

### 11.3 バリデーション
- HTTP リクエスト: Content-Type, Content-Length, Body JSON 形式
- JWT クレーム: exp, iat, sub, aud 検証
- ルーティング: パスのワイルドカード展開

### 11.4 キャッシング
- **JWKS**: Redis TTL 24時間
- **RouteDefinition**: ConfigMap fsnotify で即座に更新
- **Permission チェック**: 応答側でキャッシュ (Permission Service 側)

---

## 12. マイグレーション計画
### 12.1 現状
複数のマイクロサービスが存在し、クライアントが各サービスに直接アクセスしている。

### 12.2 目標状態
API Gateway を単一エントリポイント化し、すべてのクライアント通信を一元管理。

### 12.3 マイグレーション手順

| フェーズ                | 期間     | 実施内容                                                  | リスク             |
| ----------------------- | -------- | --------------------------------------------------------- | ------------------ |
| Phase 1: 準備           | Week 1-2 | API Gateway コード完成、スタック確認、テスト完成          | なし               |
| Phase 2: ステージング   | Week 3-4 | ステージング環境デプロイ、負荷テスト (10% トラフィック)   | パフォーマンス問題 |
| Phase 3: 段階的本番導入 | Week 5-8 | 本番環境デプロイ、10% → 50% → 100% トラフィック段階的移行 | 本番サービス影響   |
| Phase 4: 監視・調整     | Week 9+  | メトリクス監視、バグ修正、パフォーマンス最適化            | なし               |

**ロールバック計画**: Kubernetes 前バージョンへの即座なRollout (< 2分)

---

## 13. 未決事項と決定事項

| #   | 項目                     | 現在の決定                                  | 代替案                              | 理由                       |
| --- | ------------------------ | ------------------------------------------- | ----------------------------------- | -------------------------- |
| 1   | レート制限アルゴリズム   | スライディングウィンドウ (Redis Sorted Set) | トークンバケット                    | Redis との親和性、精度     |
| 2   | サーキットブレーカー実装 | Redis-backed state machine                  | 組み込みライブラリ (sony/gobreaker) | 分散環境での状態共有が必要 |
| 3   | JWT署名検証              | JWKS キャッシュ (Redis 24h TTL)             | オンデマンド取得                    | レイテンシー削減           |
| 4   | WebSocket プロキシ       | gorilla/websocket (ダイレクトプロキシ)      | Socket.io 経由                      | Go standard に近い         |
| 5   | ルート設定管理           | Kubernetes ConfigMap + fsnotify ウォッチ    | etcd, Consul                        | K8s native, dynamic reload |
| 6   | イベント発行             | AWS SQS (非同期)                            | Kafka                               | 既存 AWS インフラ活用      |

---

## 14. 参考資料
- Robert C. Martin, "Clean Architecture: A Craftsman's Guide to Software Structure and Design", 2017
- Mark Richards & Neal Ford, "Fundamentals of Software Architecture", 2020
- AWS API Gateway Documentation: https://docs.aws.amazon.com/apigateway/
- Gin Web Framework: https://github.com/gin-gonic/gin
- Redis Documentation: https://redis.io/documentation
- JWT (RFC 7519): https://tools.ietf.org/html/rfc7519
- OpenTelemetry: https://opentelemetry.io/
