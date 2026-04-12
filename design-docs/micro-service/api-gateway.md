# API Gateway Module (recuerdo-api-gateway)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoの全マイクロサービスへの単一エントリポイントとして、JWT認証・権限チェック・ルーティング・レート制限・WebSocketプロキシを一元管理するドメイン層設計書。各マイクロサービスの内部APIを外部に直接公開せず、ゲートウェイで抽象化することでバックエンドの変更をフロントエンドに影響させない。ゲートウェイ自体はステートレスでビジネスロジックを持たず、リクエスト処理パイプラインのオーケストレーションのみを担う。

### ビジネスコンテキスト

解決する問題:
- マイクロサービスが増えるにつれAPIが散在し管理が困難になる（会話で特定した課題）
- 認証・権限チェック・レート制限ロジックが各サービスに重複実装される
- フロントエンド（iOS/Web）が複数のサービスエンドポイントを直接管理する必要がある

Key User Stories:
- iOSアプリ開発者として、単一のAPIエンドポイントに対してリクエストを送るだけで適切なサービスに振り分けてほしい
- バックエンド開発者として、新しいマイクロサービスを追加する際にフロントエンドのコード変更なしにゲートウェイのルーティング設定だけで対応したい
- セキュリティ担当として、全リクエストの認証・権限チェックを一箇所で管理したい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ | 説明 | 主要属性 |
| --- | --- | --- |
| RouteDefinition | パスパターンから上流サービスへのルーティングルール | path_prefix, upstream_url, protocol (HTTP/WS), auth_required, permission_check, required_role?, timeout_ms |
| AuthenticatedRequest | JWT検証済みリクエストのコンテキスト。下流サービスへ伝達する | user_id, system_role, trace_id, original_path, method, headers, body |
| RateLimitWindow | ユーザー/IP単位のスライディングウィンドウカウンター（Redis管理） | key (user_id or ip), count, window_start, ttl |
| BlockedToken | 明示的に無効化されたJWT（ログアウト・強制切断） | jti (JWT ID), user_id, expires_at |
| CircuitBreakerState | 上流サービスへのサーキットブレーカー状態 | upstream_name, state (CLOSED/OPEN/HALF_OPEN), failure_count, last_failure_at, next_attempt_at |

### 値オブジェクト

| 値オブジェクト | 説明 | バリデーションルール |
| --- | --- | --- |
| JWTClaims | Cognito JWTのペイロード | sub (user_id)・exp・iss が必須。issはCognito User Pool URLと一致 |
| TraceID | W3C Trace Context形式のトレースID | traceparent形式 (version-traceid-spanid-flags)。全リクエストで付与 |
| UpstreamURL | 上流サービスのURL | http:// または ws:// スキームのみ。Kubernetes Service名形式 |
| RateLimitKey | レート制限のRedisキー | rate_limit:{user_id}:{window} または rate_limit:ip:{ip}:{window} |
| CircuitBreakerThreshold | サーキットブレーカー設定値 | failure_count_threshold > 0, half_open_timeout_seconds > 0 |

### ドメインルール / 不変条件

- auth_required=trueのルートはJWT検証なしに上流サービスに転送してはならない
- permission_check=trueのルートはPermission Serviceの承認なしに転送してはならない
- BlockedTokensに存在するJTIを持つリクエストは403を返さなければならない
- サーキットブレーカーがOPEN状態の上流サービスへはリクエストを転送してはならない
- レート制限超過のリクエストには必ず429と適切なRetry-Afterヘッダーを返す
- 全リクエストにtraceIDを付与して下流に伝播しなければならない
- ゲートウェイはレスポンスボディを変更してはならない（プロキシとして透過的に動作）
- required_role指定のあるルートはPermission ServiceでSystemRoleを確認する
- WebSocketルートはJWT検証後に接続をそのまま上流サービスに引き渡す

### ドメインイベント

| イベント | トリガー | 主要ペイロード |
| --- | --- | --- |
| AuthenticationFailed | JWT検証失敗時 | ip, endpoint, reason (invalid_signature/expired/missing), timestamp |
| RateLimitExceeded | レート制限超過時 | user_id?, ip, endpoint, limit, count, timestamp |
| CircuitBreakerOpened | サーキットブレーカーがOPEN状態に遷移した時 | upstream_name, failure_count, timestamp |
| CircuitBreakerClosed | サーキットブレーカーがCLOSED状態に復旧した時 | upstream_name, timestamp |
| PermissionDeniedAtGateway | 権限チェックで拒否された時 | user_id, path, action, reason, timestamp |
| TokenBlocked | JWTが無効化リストに追加された時 | jti, user_id, reason, expires_at, timestamp |

### エンティティ定義（コードスケッチ）

// Go-style pseudocode

type RouteDefinition struct {
    PathPrefix    string
    UpstreamURL   string
    Protocol      string // HTTP or WS
    AuthRequired  bool
    PermCheck     bool
    RequiredRole  *string // e.g. "SUPERUSER"
    TimeoutMs     int
}

func (r *RouteDefinition) Validate() error {
    if r.PathPrefix == "" { return ErrInvalidPathPrefix }
    if !strings.HasPrefix(r.UpstreamURL, "http") &&
       !strings.HasPrefix(r.UpstreamURL, "ws") {
        return ErrInvalidUpstreamURL
    }
    if r.TimeoutMs <= 0 { return ErrInvalidTimeout }
    return nil
}

type AuthenticatedRequest struct {
    UserID     string
    SystemRole string
    TraceID    string
    Path       string
    Method     string
    Headers    map[string]string
}

func NewAuthenticatedRequest(claims JWTClaims, r *http.Request) *AuthenticatedRequest {
    traceID := r.Header.Get("traceparent")
    if traceID == "" {
        traceID = generateTraceID() // W3C traceparent形式
    }
    return &AuthenticatedRequest{
        UserID:  claims.Sub,
        TraceID: traceID,
        Path:    r.URL.Path,
        Method:  r.Method,
    }
}

type CircuitBreakerState struct {
    UpstreamName  string
    State         string // CLOSED / OPEN / HALF_OPEN
    FailureCount  int
    LastFailureAt time.Time
    NextAttemptAt time.Time
}

func (c *CircuitBreakerState) ShouldAllow() bool {
    switch c.State {
    case "CLOSED":    return true
    case "OPEN":      return time.Now().After(c.NextAttemptAt)
    case "HALF_OPEN": return true // 1リクエストのみ試行
    default:          return false
    }
}

func (c *CircuitBreakerState) RecordFailure(threshold int, halfOpenTimeout time.Duration) {
    c.FailureCount++
    c.LastFailureAt = time.Now()
    if c.FailureCount >= threshold {
        c.State = "OPEN"
        c.NextAttemptAt = time.Now().Add(halfOpenTimeout)
    }
}

func (c *CircuitBreakerState) RecordSuccess() {
    c.State = "CLOSED"
    c.FailureCount = 0
}

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース | 入力DTO | 出力DTO | 説明 |
| --- | --- | --- | --- |
| ProcessRequest | ProcessRequestInput{http.Request, route} | ProcessRequestOutput{upstream_response} | リクエスト処理パイプライン全体のオーケストレーション。最重要ユースケース |
| AuthenticateRequest | AuthenticateRequestInput{authorization_header} | AuthenticateRequestOutput{jwt_claims, user_id} | JWT検証・BlockedTokensチェック・JWKSキャッシュ管理 |
| CheckRateLimit | CheckRateLimitInput{user_id?, ip, endpoint} | CheckRateLimitOutput{allowed, remaining, reset_at} | Redis sliding windowによるレート制限チェック |
| CheckPermission | CheckPermissionInput{user_id, path, method, required_role?} | CheckPermissionOutput{allowed, reason} | Permission Service (gRPC) への権限チェック委譲 |
| RouteRequest | RouteRequestInput{authenticated_request, route} | RouteRequestOutput{upstream_response} | サーキットブレーカー確認後に上流サービスにプロキシ |
| ProxyWebSocket | ProxyWebSocketInput{ws_conn, route, user_id} | ProxyWebSocketOutput{} | JWT検証後にWebSocket接続を上流サービスへ透過プロキシ |
| BlockToken | BlockTokenInput{jti, user_id, expires_at} | BlockTokenOutput{success} | JWTをblocked_tokensに追加（ログアウト・ユーザーサスペンド） |
| ReloadRoutes | ReloadRoutesInput{} | ReloadRoutesOutput{route_count} | ConfigMapからルーティング設定をホットリロード |

### ユースケース詳細（主要ユースケース）

## ProcessRequest — 主要ユースケース詳細

### トリガー
iOSアプリ/WebアプリからのHTTPリクエスト

### フロー
1. RouteMatchingPort.Match(path, method) でRouteDefinitionを取得
   - マッチなし → 404
2. リクエストサイズチェック (最大50MB)
   - 超過 → 413
3. auth_required=true の場合:
   a. AuthenticateRequestUseCase.Execute(authorization_header)
      - JWT検証失敗 → 401
      - BlockedTokensに存在 → 401
   b. AuthenticatedRequest を生成 (user_id, trace_id付与)
4. permission_check=true の場合:
   a. CheckRateLimitUseCase.Execute(user_id, ip, endpoint)
      - 超過 → 429 + X-RateLimit-* ヘッダー
   b. CheckPermissionUseCase.Execute(user_id, path, method, required_role?)
      - DENIED → 403
5. CircuitBreakerStatePort.Check(upstream_name)
   - OPEN → 503
6. リクエストヘッダーに付与:
   - X-User-Id: user_id
   - traceparent: trace_id
   - X-Forwarded-For: client_ip
7. RouteRequestUseCase.Execute(authenticated_request, route)
   - タイムアウト → 504
   - 上流5xx → CircuitBreakerStatePort.RecordFailure()
   - 上流200〜4xx → CircuitBreakerStatePort.RecordSuccess()
8. レスポンスをそのままクライアントに返す（ボディ変更なし）

### 注意事項
- 全フローのオーバーヘッド目標: P99 50ms以内
- 手順3b (permission_check) はタイムアウト150ms

### リポジトリ・サービスポート（インターフェース）

// Repository Ports
type RouteMatchingPort interface {
    Match(path, method string) (*RouteDefinition, error)
    Reload(ctx context.Context) (int, error) // ConfigMapホットリロード
}

type BlockedTokenRepository interface {
    Exists(ctx context.Context, jti string) (bool, error)
    Add(ctx context.Context, token BlockedToken) error
}

type RateLimitRepository interface {
    Check(ctx context.Context, key RateLimitKey, limit int, window time.Duration) (bool, int, time.Time, error)
}

type CircuitBreakerStatePort interface {
    Check(ctx context.Context, upstreamName string) (*CircuitBreakerState, error)
    RecordSuccess(ctx context.Context, upstreamName string) error
    RecordFailure(ctx context.Context, upstreamName string) error
}

// Service Ports
type JWTVerifierPort interface {
    Verify(ctx context.Context, token string) (*JWTClaims, error)
    // JWKSをRedisキャッシュから取得。TTL切れ時にCognitoから再取得
}

type PermissionPort interface {
    CheckPermission(ctx context.Context, userID, path, method string, requiredRole *string) (bool, string, error)
}

type HTTPProxyPort interface {
    Forward(ctx context.Context, req *AuthenticatedRequest, route *RouteDefinition) (*http.Response, error)
}

type WebSocketProxyPort interface {
    Proxy(ctx context.Context, clientConn *websocket.Conn, route *RouteDefinition, userID string) error
}

type EventPublisherPort interface {
    Publish(ctx context.Context, event DomainEvent) error
}

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ | ルート/トリガー | ユースケース |
| --- | --- | --- |
| HTTPGatewayHandler | 全HTTPリクエスト (/*) | ProcessRequestUseCase |
| WebSocketGatewayHandler | WebSocket /ws/* | ProxyWebSocketUseCase |
| HealthHandler | GET /health | ヘルスチェック（ユースケース不要） |
| MetricsHandler | GET /metrics | Prometheusメトリクス（ユースケース不要） |
| SQSConsumer | Queue: permission.user_suspended | BlockTokenUseCase (user_idに紐づく全JTIをblock) |
| SQSConsumer | Queue: auth.token_revoked | BlockTokenUseCase |
| ConfigMapWatcher | ConfigMap変更検知 (fsnotify) | ReloadRoutesUseCase |

### リポジトリ実装

| ポートインターフェース | 実装クラス | データストア |
| --- | --- | --- |
| RouteMatchingPort | YAMLRouteRepository | ConfigMap (YAML, fsnotifyでホットリロード) |
| BlockedTokenRepository | RedisBlockedTokenRepository | Redis 7.x (jti → TTL付きSET) |
| RateLimitRepository | RedisSlidingWindowRepository | Redis 7.x (sliding window counter) |
| CircuitBreakerStatePort | RedisCircuitBreakerRepository | Redis 7.x (upstream状態管理) |

### 外部サービスアダプタ

| ポートインターフェース | アダプタクラス | 外部システム |
| --- | --- | --- |
| JWTVerifierPort | CognitoJWTVerifier | AWS Cognito (JWKS endpoint, Redisキャッシュ付き) |
| PermissionPort | PermissionServiceGRPCAdapter | recuerdo-permission-svc (gRPC) |
| HTTPProxyPort | ReverseHTTPProxy | 各マイクロサービス (net/http/httputil.ReverseProxy) |
| WebSocketProxyPort | WebSocketReverseProxy | recuerdo-messaging-svc (gorilla/websocket) |
| EventPublisherPort | SQSEventPublisher | AWS SQS (recuerdo-gateway-events) |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + net/http (HTTPサーバー) + gorilla/websocket (WebSocketプロキシ) + httputil.ReverseProxy (HTTPプロキシ)

### データベース

Redis 7.x のみ (go-redis/v9, pool max 20)。ゲートウェイ自体はDBを持たないステートレス設計。ルーティング設定はKubernetes ConfigMap (YAML) で管理。

### 主要ライブラリ・SDK

| ライブラリ | 目的 | レイヤー |
| --- | --- | --- |
| golang-jwt/jwt/v5 | JWT検証・JWTClaims解析 | Adapter |
| lestrrat-go/jwx/v2 | JWKS取得・公開鍵キャッシュ | Infrastructure |
| gorilla/websocket | WebSocketプロキシ実装 | Infrastructure |
| go-redis/v9 | BlockedTokens・レート制限・サーキットブレーカー状態 | Infrastructure |
| google.golang.org/grpc | Permission Service gRPCクライアント | Infrastructure |
| fsnotify/fsnotify | ConfigMapファイル変更検知によるホットリロード | Infrastructure |
| aws-sdk-go-v2/service/sqs | SQSイベント消費・発行 | Infrastructure |
| uber-go/fx | 依存性注入 | Infrastructure |
| uber-go/zap | 構造化ログ | Infrastructure |
| go.opentelemetry.io/otel | 分散トレーシング・TraceID生成 | Infrastructure |
| prometheus/client_golang | メトリクス収集 | Infrastructure |

### 依存性注入

uber-go/fx を使用。全ポートをインターフェースとして登録。

fx.Provide(
    NewYAMLRouteRepository,          // → RouteMatchingPort
    NewRedisBlockedTokenRepository,  // → BlockedTokenRepository
    NewRedisSlidingWindowRepository, // → RateLimitRepository
    NewRedisCircuitBreakerRepository,// → CircuitBreakerStatePort
    NewCognitoJWTVerifier,           // → JWTVerifierPort
    NewPermissionServiceGRPCAdapter, // → PermissionPort
    NewReverseHTTPProxy,             // → HTTPProxyPort
    NewWebSocketReverseProxy,        // → WebSocketProxyPort
    NewSQSEventPublisher,            // → EventPublisherPort
    NewProcessRequestUseCase,
    NewHTTPGatewayHandler,
    NewWebSocketGatewayHandler,
)

## 6. ディレクトリ構成

### ディレクトリツリー

recuerdo-api-gateway/
├── cmd/server/main.go
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── route_definition.go
│   │   │   ├── authenticated_request.go
│   │   │   ├── rate_limit_window.go
│   │   │   ├── blocked_token.go
│   │   │   └── circuit_breaker_state.go
│   │   ├── valueobject/
│   │   │   ├── jwt_claims.go
│   │   │   ├── trace_id.go
│   │   │   ├── upstream_url.go
│   │   │   └── rate_limit_key.go
│   │   ├── event/domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── process_request.go      # 最重要。リクエスト処理パイプライン全体
│   │   ├── authenticate_request.go
│   │   ├── check_rate_limit.go
│   │   ├── check_permission.go
│   │   ├── route_request.go
│   │   ├── proxy_websocket.go
│   │   ├── block_token.go
│   │   ├── reload_routes.go
│   │   └── port/
│   │       ├── repository.go
│   │       └── service.go
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── gateway_handler.go  # 全HTTPリクエストのエントリポイント
│   │   │   └── health_handler.go
│   │   ├── websocket/
│   │   │   └── proxy_handler.go
│   │   ├── queue/
│   │   │   └── sqs_consumer.go    # user_suspended等の消費
│   │   └── config/
│   │       └── configmap_watcher.go # fsnotifyでホットリロード
│   └── infrastructure/
│       ├── redis/
│       │   ├── blocked_token_repo.go
│       │   ├── rate_limit_repo.go
│       │   └── circuit_breaker_repo.go
│       ├── cognito/
│       │   └── jwt_verifier.go    # JWKS取得・Redisキャッシュ
│       ├── grpc/
│       │   └── permission_adapter.go
│       ├── proxy/
│       │   ├── http_proxy.go      # httputil.ReverseProxy
│       │   └── websocket_proxy.go
│       └── sqs/
│           └── event_publisher.go
├── config/
│   └── routing_rules.yaml          # ルーティング定義
└── k8s/
    └── configmap.yaml

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー | テスト種別 | モック戦略 |
| --- | --- | --- |
| Domain (entity/valueobject) | Unit test | 外部依存なし。RouteDefinition.Validate()・CircuitBreakerState.ShouldAllow()等 |
| UseCase | Unit test | mockeryで全ポート（JWTVerifierPort/PermissionPort等）をモック |
| Adapter (HTTP Gateway) | Integration test | httptest.Server で上流サービスをモック。全ルートの認証・ルーティングを検証 |
| Adapter (WebSocket) | Integration test | gorilla/websocket テストクライアント + モックMessaging Service |
| Infrastructure (Redis) | Integration test | testcontainers-go でRedis7コンテナを起動してレート制限・BlockedTokensを検証 |
| E2E | E2E test | JWT取得→認証→各サービスへのルーティングの完全シナリオ |
| Security test | Penetration test | OWASP ZAP自動スキャン。JWT改ざん・パストラバーサル・レート制限バイパス試行 |

### テストコード例

// Entity Test
func TestCircuitBreakerState_ShouldAllow_WhenOpen(t *testing.T) {
    cb := &CircuitBreakerState{
        State:         "OPEN",
        NextAttemptAt: time.Now().Add(30 * time.Second),
    }
    assert.False(t, cb.ShouldAllow())
}

func TestCircuitBreakerState_ShouldAllow_AfterHalfOpenTimeout(t *testing.T) {
    cb := &CircuitBreakerState{
        State:         "OPEN",
        NextAttemptAt: time.Now().Add(-1 * time.Second), // 過去
    }
    assert.True(t, cb.ShouldAllow())
}

func TestRouteDefinition_Validate_InvalidUpstream(t *testing.T) {
    route := &RouteDefinition{
        PathPrefix:  "/test",
        UpstreamURL: "ftp://invalid",
        TimeoutMs:   3000,
    }
    err := route.Validate()
    assert.ErrorIs(t, err, ErrInvalidUpstreamURL)
}

// UseCase Test
func TestProcessRequest_BlockedToken_Returns401(t *testing.T) {
    mockJWT := new(MockJWTVerifierPort)
    mockJWT.On("Verify", "Bearer token").Return(&JWTClaims{Sub: "user-1", JTI: "jti-123"}, nil)

    mockBlocked := new(MockBlockedTokenRepository)
    mockBlocked.On("Exists", "jti-123").Return(true, nil)

    uc := NewAuthenticateRequestUseCase(mockJWT, mockBlocked)
    _, err := uc.Execute(ctx, AuthenticateRequestInput{AuthHeader: "Bearer token"})

    assert.ErrorIs(t, err, ErrTokenRevoked)
}

func TestProcessRequest_RateLimitExceeded_Returns429(t *testing.T) {
    mockRL := new(MockRateLimitRepository)
    mockRL.On("Check", mock.Anything, 300, mock.Anything).Return(false, 0, time.Now().Add(time.Minute), nil)

    uc := NewCheckRateLimitUseCase(mockRL)
    out, err := uc.Execute(ctx, CheckRateLimitInput{UserID: "user-1", Endpoint: "/orgs"})

    assert.NoError(t, err)
    assert.False(t, out.Allowed)
}

## 8. エラーハンドリング

### ドメインエラー

- ErrRouteNotFound: リクエストパスに対応するルートが定義されていない
- ErrInvalidPathPrefix: RouteDefinitionのpath_prefixが空
- ErrInvalidUpstreamURL: UpstreamURLがhttp://またはws://スキームでない
- ErrInvalidTimeout: タイムアウト値が0以下
- ErrMissingAuthHeader: auth_required=trueのルートでAuthorizationヘッダーが存在しない
- ErrInvalidJWT: JWTの署名・形式・issuerが不正
- ErrExpiredJWT: JWTの有効期限切れ
- ErrTokenRevoked: JTIがBlockedTokensに存在する（ログアウト・強制切断済み）
- ErrRateLimitExceeded: レート制限を超過した
- ErrPermissionDenied: Permission Serviceによる権限チェックで拒否
- ErrCircuitBreakerOpen: 上流サービスのサーキットブレーカーがOPEN状態
- ErrUpstreamTimeout: 上流サービスへのリクエストがタイムアウト
- ErrUpstreamUnavailable: 上流サービスが503/接続拒否を返した
- ErrRequestTooLarge: リクエストボディが50MBを超えた

### エラー → HTTPステータスマッピング

| ドメインエラー | HTTPステータス | ユーザーメッセージ |
| --- | --- | --- |
| ErrRouteNotFound | 404 Not Found | The requested endpoint does not exist |
| ErrMissingAuthHeader | 401 Unauthorized | Authorization header is required |
| ErrInvalidJWT | 401 Unauthorized | Invalid or malformed authentication token |
| ErrExpiredJWT | 401 Unauthorized | Authentication token has expired |
| ErrTokenRevoked | 401 Unauthorized | Authentication token has been revoked |
| ErrRateLimitExceeded | 429 Too Many Requests | Too many requests. Please try again later. |
| ErrPermissionDenied | 403 Forbidden | You do not have permission to perform this action |
| ErrCircuitBreakerOpen | 503 Service Unavailable | Service temporarily unavailable. Please try again later. |
| ErrUpstreamTimeout | 504 Gateway Timeout | The request timed out. Please try again. |
| ErrUpstreamUnavailable | 503 Service Unavailable | Service temporarily unavailable. Please try again later. |
| ErrRequestTooLarge | 413 Content Too Large | Request body exceeds the maximum allowed size |

## 9. 未決事項

### 質問・決定事項

| # | 質問 | ステータス | 決定 |
| --- | --- | --- | --- |
| 1 | 既存のbeta API (api-recuerdo-beta.skslprd.com) からゲートウェイへの移行は段階的か一括か。既存クライアントの互換性をどう保つか | Open | 未決定。v1プレフィックス追加で既存パスを維持しつつゲートウェイに統合する方針で検討中 |
| 2 | Permission ServiceがダウンしたときのFail-Open緊急モードの発動条件と操作権限を誰が持つか | Open | 未決定。SUPERUSERがConfigMapのfail_open_modeフラグを更新する運用手順を整備予定 |
| 3 | CognitoのJWKSキャッシュTTLは300秒で十分か。鍵ローテーション時の遅延が許容されるか | Open | 未決定。300秒を初期値とし、Cognitoの鍵ローテーション頻度に合わせて調整 |
| 4 | レート制限のRedisがダウンした場合はFail-Open（制限なし）かFail-Closed（全拒否）か | Open | 未決定。初期はFail-Open（ユーザー体験優先）。セキュリティインシデント後に再評価 |
| 5 | WebSocketプロキシ時に上流サービス（Messaging）がダウンした場合、クライアントへの切断通知はどうするか | Open | 未決定。WebSocketクローズフレーム (code 1014 Bad Gateway) を送信後に切断する予定 |
