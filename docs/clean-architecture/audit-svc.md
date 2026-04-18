# クリーンアーキテクチャ設計書

| 項目 | 値 |
|------|-----|
| **モジュール/サービス名** | Audit Service (recuerdo-audit-svc) |
| **作成者** | Akira |
| **作成日** | 2026-04-13 |
| **ステータス** | ドラフト |
| **バージョン** | 1.0 |

---

## 1. 概要
### 1.1 目的
Audit Service は、Recerdo アプリケーション全体における全システムアクション（ユーザ操作、管理者操作、サービス間通信）の不変監査証跡を提供します。GDPR コンプライアンス、セキュリティ監査、トラブルシューティングのための包括的なアクティビティログを維持し、過去のシステムイベントの復元不可能な記録を提供します。

### 1.2 ビジネスコンテキスト
- **主要ユースケース**: コンプライアンスレポート、管理者ダッシュボード、GDPR データ開示、セキュリティ監査
- **規制要件**: EU GDPR、データ保護法、監査証跡保持
- **イベント消費元**: API Gateway（認証失敗、権限否定）、Auth Service（ログイン/ログアウト）、全マイクロサービス（データ変更）
- **イベント配信**: SQS 非同期メッセージング
- **消費者**: 管理ダッシュボード、コンプライアンスレポート機能、ユーザ GDPR 開示
- **キー特性**: APPEND-ONLY パターン、PII 匿名化、S3 長期アーカイバル

### 1.3 アーキテクチャ原則
1. **ドメイン駆動設計**: ビジネスルール（不変性、監査証跡の完全性）をコア層に実装
2. **依存性逆転**: リポジトリ、キャッシュ、メッセージング参照はインターフェースで抽象化
3. **イベント駆動**: SQS メッセージを通じた疎結合なイベント処理
4. **責任の分離**: エンティティ層はドメインルール、ユースケース層はビジネスロジック、適配層は外部 I/O
5. **テスト可能性**: インターフェースベースで全レイヤをユニットテスト可能に

---

## 2. レイヤーアーキテクチャ
### 2.1 アーキテクチャ図

```
┌─────────────────────────────────────────────────────────────┐
│           External Systems (API, SQS, S3, DB)               │
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Framework & Drivers Layer (Infrastructure)               │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ HTTP Server | SQS Consumer | PostgreSQL | Redis | S3    ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Interface Adapters Layer (Controllers, Presenters)       │
│  ┌────────────┐ ┌────────────┐ ┌──────────────┐            │
│  │ HTTP       │ │ SQS        │ │ S3 Archival  │            │
│  │ Handlers   │ │ Consumers  │ │ Adapter      │            │
│  └────────────┘ └────────────┘ └──────────────┘            │
│  ┌────────────┐ ┌────────────────────────────┐              │
│  │ Presenters │ │ Repository Implementations │              │
│  └────────────┘ └────────────────────────────┘              │
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Application Layer (Use Cases)                            │
│  ┌──────────────────────────────────────────────────────────┐│
│  │ RecordAuditEntry │ QueryAuditLogs │ ExportAuditLogs     ││
│  │ ArchiveOldLogs   │ AnonymizeGDPRData                     ││
│  └──────────────────────────────────────────────────────────┘│
│  ┌──────────────────────────────────────────────────────────┐│
│  │ Ports: AuditRepository, ArchivalService, CacheService    ││
│  └──────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              △
                              │
┌─────────────────────────────────────────────────────────────┐
│    Entity Layer (Domain)                                    │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ AuditEntry (immutable) | RetentionPolicy             │ │
│  │ ArchivalJob | GDPRAnonymization                       │ │
│  │ Value Objects: AuditAction, ResourceType, etc.       │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール
- **内向き依存のみ**: 外層は内層に依存、逆は不可
- **インターフェース境界**: ユースケース層が Abstract Ports（リポジトリ、サービス）定義
- **DTO 翻訳**: 適配層で外部格式を内部 Entity へ変換
- **エラー変換**: ドメインエラーを HTTP レスポンスに変換（適配層）

---

## 3. エンティティ層（ドメイン）
### 3.1 ドメインモデル

| モデル | 説明 | 主要属性 |
|--------|------|---------|
| **AuditEntry** | 不変監査ログエントリ | id (UUID), actor_id, actor_type, action, resource_type, resource_id, result, ip_address, user_agent, metadata (JSONB), occurred_at (timestamptz) |
| **RetentionPolicy** | イベント種別の保持期間定義 | id, event_type, retention_days, created_at |
| **ArchivalJob** | S3 アーカイバル実行レコード | id, batch_id, status (PENDING/RUNNING/SUCCESS/FAILED), archived_at, rows_count, s3_path |
| **GDPRAnonymization** | GDPR 削除リクエスト追跡 | id, user_id, request_at, anonymized_at, status (PENDING/COMPLETED/FAILED), error_message |

### 3.2 値オブジェクト

| 値オブジェクト | 許可値 | バリデーション |
|---------|--------|----------|
| **AuditAction** | READ, WRITE, DELETE, LOGIN, LOGOUT, PERMISSION_CHECK, ADMIN_ACTION | 定義済み定数のみ |
| **ResourceType** | USER, ORG, MEDIA, ALBUM, EVENT, MESSAGE, PAYMENT, ROLE | 定義済み定数のみ |
| **ActorType** | USER, SERVICE, SYSTEM | 定義済み定数のみ |
| **AuditResult** | ALLOWED, DENIED, ERROR | 定義済み定数のみ |
| **IPAddress** | IPv4/IPv6 文字列 | 有効な IP アドレス形式 |

### 3.3 ドメインルール / 不変条件
- **不変性**: AuditEntry は作成後、更新・削除禁止（APPEND-ONLY）
- **完全な行為記録**: 全データ変更操作は actor_id と occurred_at を含む必須エントリ
- **アーカイバル**: created_at が 2 年以上前のエントリは S3 へアーカイブ必須
- **GDPR 削除**: user_id 削除リクエストは actor_id, email などの PII を HASH 値で置換（構造保持）
- **イベント分類**: action と resource_type の組み合わせで監査重要度決定
- **タイムスタンプ正確性**: occurred_at は UTC タイムゾーンで記録

### 3.4 ドメインイベント

| イベント名 | トリガ | ペイロード |
|-----------|--------|-----------|
| **AuditEntryRecorded** | RecordAuditEntry 実行完了 | audit_entry_id, actor_id, action, resource_id, occurred_at |
| **AuditLogsArchived** | ArchiveOldLogs 完了 | batch_id, rows_count, s3_path, archived_date |
| **GDPRAnonymizationCompleted** | AnonymizeGDPRData 完了 | user_id, anonymized_entry_count, completed_at |
| **ArchivalJobFailed** | S3 アーカイバル失敗 | batch_id, error_reason, retry_count |

### 3.5 エンティティ定義

```go
// ドメイン層: エンティティ定義

// AuditEntry: 不変監査ログエントリ
type AuditEntry struct {
    ID           uuid.UUID
    ActorID      string         // ユーザ/サービス ID
    ActorType    ActorType      // USER, SERVICE, SYSTEM
    Action       AuditAction    // READ, WRITE, DELETE, ...
    ResourceType ResourceType   // USER, ORG, MEDIA, ...
    ResourceID   string         // 対象リソース ID
    Result       AuditResult    // ALLOWED, DENIED, ERROR
    IPAddress    string         // リクエスト元 IP
    UserAgent    string         // HTTP User-Agent
    Metadata     map[string]interface{} // 追加コンテキスト JSON
    OccurredAt   time.Time      // UTC タイムスタンプ
    CreatedAt    time.Time      // レコード作成時刻
}

// IsImmutable: エンティティ変更禁止検査
func (ae *AuditEntry) IsImmutable() bool {
    return ae.ID != uuid.Nil && !ae.CreatedAt.IsZero()
}

// RetentionPolicy: 保持期間ポリシー
type RetentionPolicy struct {
    ID           uuid.UUID
    EventType    string    // "login", "data_change", "admin_action"
    RetentionDays int      // 何日保持するか
    CreatedAt    time.Time
}

// ArchivalJob: アーカイバル実行ジョブ
type ArchivalJob struct {
    ID          uuid.UUID
    BatchID     string           // バッチ識別子
    Status      ArchivalStatus   // PENDING, RUNNING, SUCCESS, FAILED
    RowsCount   int
    S3Path      string           // s3://bucket/path/to/archive
    ArchivedAt  *time.Time
    CreatedAt   time.Time
    UpdatedAt   time.Time
}

// GDPRAnonymization: GDPR 削除追跡
type GDPRAnonymization struct {
    ID             uuid.UUID
    UserID         string       // 削除対象ユーザ
    RequestedAt    time.Time
    AnonymizedAt   *time.Time
    Status         string       // PENDING, COMPLETED, FAILED
    ErrorMessage   string
}

// Value Objects
type AuditAction string

const (
    ActionRead            AuditAction = "READ"
    ActionWrite           AuditAction = "WRITE"
    ActionDelete          AuditAction = "DELETE"
    ActionLogin           AuditAction = "LOGIN"
    ActionLogout          AuditAction = "LOGOUT"
    ActionPermissionCheck AuditAction = "PERMISSION_CHECK"
    ActionAdminAction     AuditAction = "ADMIN_ACTION"
)

type ResourceType string

const (
    ResourceUser    ResourceType = "USER"
    ResourceOrg     ResourceType = "ORG"
    ResourceMedia   ResourceType = "MEDIA"
    ResourceAlbum   ResourceType = "ALBUM"
    ResourceEvent   ResourceType = "EVENT"
    ResourceMessage ResourceType = "MESSAGE"
)

type ActorType string

const (
    ActorUser    ActorType = "USER"
    ActorService ActorType = "SERVICE"
    ActorSystem  ActorType = "SYSTEM"
)

type AuditResult string

const (
    ResultAllowed AuditResult = "ALLOWED"
    ResultDenied  AuditResult = "DENIED"
    ResultError   AuditResult = "ERROR"
)
```

---

## 4. ユースケース層（アプリケーション）
### 4.1 ユースケース一覧

| ユースケース | アクタ | 説明 | 主要入力 |
|-----------|--------|------|---------|
| **RecordAuditEntry** | System (SQS) | SQS イベントから監査エントリを記録 | AuditEvent (SQS JSON) |
| **QueryAuditLogs** | Admin | 期間・条件で監査ログをクエリ | date_from, date_to, actor_id, action, resource_id |
| **ExportAuditLogs** | Admin | CSV 形式で監査ログをエクスポート | filters (date_from, date_to, ...) |
| **ArchiveOldLogs** | System (Scheduler) | 2 年以上前のログを S3 へ移動 | なし（定期実行） |
| **AnonymizeGDPRData** | System (Event) | GDPR 削除リクエスト → PII 匿名化 | user_id, gdpr_request_id |

### 4.2 ユースケース詳細

#### RecordAuditEntry (メインユースケース)
**アクタ**: System (SQS Consumer)

**前提条件**:
- SQS メッセージ受信（JSON フォーマット）
- メッセージスキーマ有効（actor_id, action, resource_type, resource_id 必須）

**フロー**:
1. SQS Consumer がメッセージを受信
2. JSON デシリアライズ → DTO 変換
3. バリデーション（null チェック、enum 値確認）
4. Domain Entity (AuditEntry) 構築
5. Repository.Save() で PostgreSQL に INSERT
6. 挿入成功時、キャッシュをインバリデート（Redis）
7. DomainEvent (AuditEntryRecorded) 発行

**事後条件**:
- AuditEntry が immutable で PostgreSQL に保存
- Redis キャッシュが新規エントリで更新
- ドメインイベント発行完了

**エラーケース**:
- スキーマバリデーション失敗 → DLQ へ移動
- DB コネクション失敗 → リトライ（SQS DeadLetterQueue）
- JSON パース失敗 → ログ出力、スキップ

### 4.3 入出力DTO

```go
// ユースケース層: 入出力DTO

// RecordAuditEntryInput
type RecordAuditEntryInput struct {
    ActorID      string `json:"actor_id" validate:"required"`
    ActorType    string `json:"actor_type" validate:"required,oneof=USER SERVICE SYSTEM"`
    Action       string `json:"action" validate:"required"`
    ResourceType string `json:"resource_type" validate:"required"`
    ResourceID   string `json:"resource_id" validate:"required"`
    Result       string `json:"result" validate:"required,oneof=ALLOWED DENIED ERROR"`
    IPAddress    string `json:"ip_address" validate:"required,ip"`
    UserAgent    string `json:"user_agent"`
    Metadata     map[string]interface{} `json:"metadata"`
    OccurredAt   string `json:"occurred_at" validate:"required,datetime=2006-01-02T15:04:05Z"`
}

// RecordAuditEntryOutput
type RecordAuditEntryOutput struct {
    AuditEntryID string `json:"audit_entry_id"`
    RecordedAt   string `json:"recorded_at"`
}

// QueryAuditLogsInput
type QueryAuditLogsInput struct {
    DateFrom   string `query:"date_from" validate:"datetime=2006-01-02T15:04:05Z"`
    DateTo     string `query:"date_to" validate:"datetime=2006-01-02T15:04:05Z"`
    ActorID    string `query:"actor_id"`
    Action     string `query:"action"`
    ResourceID string `query:"resource_id"`
    Limit      int    `query:"limit" validate:"max=1000"`
    Offset     int    `query:"offset"`
}

// AuditLogDTO
type AuditLogDTO struct {
    ID           string                 `json:"id"`
    ActorID      string                 `json:"actor_id"`
    ActorType    string                 `json:"actor_type"`
    Action       string                 `json:"action"`
    ResourceType string                 `json:"resource_type"`
    ResourceID   string                 `json:"resource_id"`
    Result       string                 `json:"result"`
    IPAddress    string                 `json:"ip_address"`
    Metadata     map[string]interface{} `json:"metadata"`
    OccurredAt   string                 `json:"occurred_at"`
}

// QueryAuditLogsOutput
type QueryAuditLogsOutput struct {
    Logs       []AuditLogDTO `json:"logs"`
    Total      int           `json:"total"`
    Limit      int           `json:"limit"`
    Offset     int           `json:"offset"`
}

// ExportAuditLogsInput
type ExportAuditLogsInput struct {
    DateFrom   string `json:"date_from" validate:"datetime=2006-01-02T15:04:05Z"`
    DateTo     string `json:"date_to" validate:"datetime=2006-01-02T15:04:05Z"`
    ActorID    string `json:"actor_id"`
    Format     string `json:"format" validate:"oneof=csv json"`
}

// ExportAuditLogsOutput
type ExportAuditLogsOutput struct {
    DownloadURL string `json:"download_url"`
    RowsCount   int    `json:"rows_count"`
}

// AnonymizeGDPRDataInput
type AnonymizeGDPRDataInput struct {
    UserID          string `validate:"required,uuid"`
    GDPRRequestID   string `validate:"required,uuid"`
}

// AnonymizeGDPRDataOutput
type AnonymizeGDPRDataOutput struct {
    AnonymizedCount int    `json:"anonymized_count"`
    Status          string `json:"status"`
    CompletedAt     string `json:"completed_at"`
}
```

### 4.4 リポジトリインターフェース（ポート）

```go
// ユースケース層: ポートインターフェース

// AuditRepository: 監査ログ永続化ポート
type AuditRepository interface {
    // Save: 新規 AuditEntry を保存（不変）
    Save(ctx context.Context, entry *domain.AuditEntry) error
    
    // FindByID: ID で監査ログを取得
    FindByID(ctx context.Context, id uuid.UUID) (*domain.AuditEntry, error)
    
    // Query: 条件で監査ログをクエリ
    Query(ctx context.Context, filter *domain.AuditFilter) ([]*domain.AuditEntry, int, error)
    
    // CountByDateRange: 日付範囲のエントリ件数
    CountByDateRange(ctx context.Context, from, to time.Time) (int, error)
    
    // FindOlderThan: 指定日付より古いエントリを取得（アーカイバル用）
    FindOlderThan(ctx context.Context, cutoffDate time.Time, limit int) ([]*domain.AuditEntry, error)
    
    // DeleteByID: 物理削除（GDPR のみ、エントリ自体は保持、PII 匿名化）
    AnonymizePII(ctx context.Context, userID string) error
}

// RetentionPolicyRepository: 保持ポリシーリポジトリ
type RetentionPolicyRepository interface {
    FindAll(ctx context.Context) ([]*domain.RetentionPolicy, error)
    FindByEventType(ctx context.Context, eventType string) (*domain.RetentionPolicy, error)
    Save(ctx context.Context, policy *domain.RetentionPolicy) error
}

// ArchivalJobRepository: アーカイバルジョブリポジトリ
type ArchivalJobRepository interface {
    Save(ctx context.Context, job *domain.ArchivalJob) error
    Update(ctx context.Context, job *domain.ArchivalJob) error
    FindByID(ctx context.Context, id uuid.UUID) (*domain.ArchivalJob, error)
    FindByStatus(ctx context.Context, status string) ([]*domain.ArchivalJob, error)
}

// GDPRAnonymizationRepository: GDPR 追跡リポジトリ
type GDPRAnonymizationRepository interface {
    Save(ctx context.Context, req *domain.GDPRAnonymization) error
    Update(ctx context.Context, req *domain.GDPRAnonymization) error
    FindByID(ctx context.Context, id uuid.UUID) (*domain.GDPRAnonymization, error)
}
```

### 4.5 外部サービスインターフェース（ポート）

```go
// ArchivalService: S3 アーカイバルポート
type ArchivalService interface {
    // ArchiveEntries: エントリリストを S3 へアーカイブ
    ArchiveEntries(ctx context.Context, entries []*domain.AuditEntry, s3Path string) (string, error)
    
    // DeleteFromDB: アーカイブ済みエントリを DB から削除
    DeleteFromDB(ctx context.Context, entryIDs []uuid.UUID) error
}

// CacheService: キャッシュ（Redis）ポート
type CacheService interface {
    Set(ctx context.Context, key string, value interface{}, ttl time.Duration) error
    Get(ctx context.Context, key string) (interface{}, error)
    InvalidatePattern(ctx context.Context, pattern string) error
}

// NotificationService: 通知ポート（GDPR 完了通知）
type NotificationService interface {
    SendGDPRCompletionNotification(ctx context.Context, userID string, count int) error
}

// EventPublisher: ドメインイベント発行ポート
type EventPublisher interface {
    PublishAuditEntryRecorded(ctx context.Context, event *domain.AuditEntryRecordedEvent) error
    PublishArchivalCompleted(ctx context.Context, event *domain.ArchivalCompletedEvent) error
}
```

---

## 5. インターフェースアダプタ層
### 5.1 コントローラ / ハンドラ

| ハンドラ | HTTP メソッド | パス | 説明 |
|---------|-------------|------|------|
| **SQSEventHandler** | - | (async) | SQS メッセージ受信 → RecordAuditEntry 実行 |
| **GetAuditLogsHandler** | GET | /api/audits | 監査ログクエリ（管理者） |
| **ExportAuditLogsHandler** | POST | /api/audits/export | CSV エクスポート（管理者） |
| **ArchiveLogsScheduler** | - | (cron) | 定期アーカイバル実行（24h ごと） |
| **GDPRAnonymizeScheduler** | - | (cron) | GDPR リクエスト処理（1h ごと） |

### 5.2 プレゼンター / レスポンスマッパー

```go
// インターフェース適配層: プレゼンター

type AuditPresenter struct{}

// PresentQueryAuditLogs: QueryAuditLogsOutput → HTTP 200 JSON
func (p *AuditPresenter) PresentQueryAuditLogs(output *application.QueryAuditLogsOutput) *http.Response {
    return &http.Response{
        StatusCode: 200,
        Body:       json.Marshal(output),
    }
}

// PresentExportAuditLogs: ExportAuditLogsOutput → HTTP 200 JSON
func (p *AuditPresenter) PresentExportAuditLogs(output *application.ExportAuditLogsOutput) *http.Response {
    return &http.Response{
        StatusCode: 200,
        Body:       json.Marshal(output),
    }
}

// PresentError: Error → HTTP エラーレスポンス
func (p *AuditPresenter) PresentError(err error) *http.Response {
    statusCode, message := p.mapErrorToHTTP(err)
    return &http.Response{
        StatusCode: statusCode,
        Body:       json.Marshal(map[string]string{"error": message}),
    }
}

func (p *AuditPresenter) mapErrorToHTTP(err error) (int, string) {
    switch err.(type) {
    case *domain.ValidationError:
        return 400, "Invalid input"
    case *domain.NotFoundError:
        return 404, "Resource not found"
    case *domain.UnauthorizedError:
        return 403, "Unauthorized"
    default:
        return 500, "Internal server error"
    }
}
```

### 5.3 リポジトリ実装（アダプタ）

| アダプタ | 技術 | 説明 |
|---------|------|------|
| **PostgresAuditRepository** | pgx/v5 | PostgreSQL 実装、月単位パーティション対応 |
| **RedisArchivalJobRepository** | go-redis/v9 | アーカイバルジョブ状態キャッシング |
| **S3ArchivalAdapter** | aws-sdk-go-v2 | S3 へのアーカイブ実装 |
| **PostgresRetentionPolicyRepository** | pgx/v5 | 保持ポリシー永続化 |

### 5.4 外部サービスアダプタ

| アダプタ | 実装 | 説明 |
|---------|------|------|
| **S3ArchivalServiceImpl** | aws-sdk-go-v2 | S3 バケットへの Parquet ファイルアップロード |
| **RedisCache** | go-redis/v9 | Redis キャッシュ実装 |
| **SQSEventPublisher** | aws-sdk-go-v2 | SQS へのイベント発行 |
| **EmailNotificationService** | sendgrid-go | GDPR 完了メール送信 |

### 5.5 マッパー

```go
// マッパー: DTO ↔ Entity 相互変換

type AuditMapper struct{}

// MapSQSEventToInput: SQS JSON メッセージ → RecordAuditEntryInput
func (m *AuditMapper) MapSQSEventToInput(event *sqs.Message) (*application.RecordAuditEntryInput, error) {
    var input application.RecordAuditEntryInput
    err := json.Unmarshal([]byte(event.Body), &input)
    if err != nil {
        return nil, fmt.Errorf("failed to unmarshal SQS message: %w", err)
    }
    return &input, nil
}

// MapInputToEntity: RecordAuditEntryInput → AuditEntry
func (m *AuditMapper) MapInputToEntity(input *application.RecordAuditEntryInput) (*domain.AuditEntry, error) {
    occurredAt, err := time.Parse(time.RFC3339, input.OccurredAt)
    if err != nil {
        return nil, fmt.Errorf("invalid occurred_at: %w", err)
    }
    
    return &domain.AuditEntry{
        ID:           uuid.New(),
        ActorID:      input.ActorID,
        ActorType:    domain.ActorType(input.ActorType),
        Action:       domain.AuditAction(input.Action),
        ResourceType: domain.ResourceType(input.ResourceType),
        ResourceID:   input.ResourceID,
        Result:       domain.AuditResult(input.Result),
        IPAddress:    input.IPAddress,
        UserAgent:    input.UserAgent,
        Metadata:     input.Metadata,
        OccurredAt:   occurredAt,
        CreatedAt:    time.Now(),
    }, nil
}

// MapEntityToDTO: AuditEntry → AuditLogDTO
func (m *AuditMapper) MapEntityToDTO(entry *domain.AuditEntry) *application.AuditLogDTO {
    return &application.AuditLogDTO{
        ID:           entry.ID.String(),
        ActorID:      entry.ActorID,
        ActorType:    string(entry.ActorType),
        Action:       string(entry.Action),
        ResourceType: string(entry.ResourceType),
        ResourceID:   entry.ResourceID,
        Result:       string(entry.Result),
        IPAddress:    entry.IPAddress,
        Metadata:     entry.Metadata,
        OccurredAt:   entry.OccurredAt.Format(time.RFC3339),
    }
}
```

---

## 6. フレームワーク＆ドライバ層（インフラストラクチャ）
### 6.1 Webフレームワーク
- **Go 1.22+** + **Echo v4** (HTTP サーバ、RESTful API)
- **Gin Gonic** 代替案（ルーティング、ミドルウェア）
- **grpc-go** (内部サービス間 RPC)

### 6.2 データベース

```sql
-- PostgreSQL 14+ スキーマ（月単位パーティション）

-- 監査エントリテーブル（親テーブル）
CREATE TABLE IF NOT EXISTS audit_entries (
    id UUID PRIMARY KEY NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    actor_type VARCHAR(50) NOT NULL CHECK (actor_type IN ('USER', 'SERVICE', 'SYSTEM')),
    action VARCHAR(50) NOT NULL CHECK (action IN ('READ', 'WRITE', 'DELETE', 'LOGIN', 'LOGOUT', 'PERMISSION_CHECK', 'ADMIN_ACTION')),
    resource_type VARCHAR(50) NOT NULL CHECK (resource_type IN ('USER', 'ORG', 'MEDIA', 'ALBUM', 'EVENT', 'MESSAGE')),
    resource_id VARCHAR(255) NOT NULL,
    result VARCHAR(50) NOT NULL CHECK (result IN ('ALLOWED', 'DENIED', 'ERROR')),
    ip_address INET NOT NULL,
    user_agent TEXT,
    metadata JSONB DEFAULT '{}',
    occurred_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
) PARTITION BY RANGE (created_at);

-- 月別パーティション（2024-01 から自動生成）
CREATE TABLE audit_entries_2026_01 PARTITION OF audit_entries
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE audit_entries_2026_02 PARTITION OF audit_entries
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE audit_entries_2026_03 PARTITION OF audit_entries
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');

-- インデックス（パーティションごと）
CREATE INDEX idx_audit_actor_id ON audit_entries (actor_id, created_at DESC);
CREATE INDEX idx_audit_resource ON audit_entries (resource_type, resource_id, created_at DESC);
CREATE INDEX idx_audit_action ON audit_entries (action, created_at DESC);
CREATE INDEX idx_audit_occurred_at ON audit_entries (occurred_at DESC);
CREATE INDEX idx_audit_metadata ON audit_entries USING GIN (metadata);

-- 保持ポリシーテーブル
CREATE TABLE IF NOT EXISTS retention_policies (
    id UUID PRIMARY KEY NOT NULL,
    event_type VARCHAR(100) UNIQUE NOT NULL,
    retention_days INTEGER NOT NULL CHECK (retention_days > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO retention_policies (id, event_type, retention_days) VALUES
    (gen_random_uuid(), 'LOGIN', 365),
    (gen_random_uuid(), 'DATA_CHANGE', 2555),  -- 7 years
    (gen_random_uuid(), 'ADMIN_ACTION', 2555),
    (gen_random_uuid(), 'PERMISSION_CHECK', 90);

-- アーカイバルジョブテーブル
CREATE TABLE IF NOT EXISTS archival_jobs (
    id UUID PRIMARY KEY NOT NULL,
    batch_id VARCHAR(100) UNIQUE NOT NULL,
    status VARCHAR(50) NOT NULL CHECK (status IN ('PENDING', 'RUNNING', 'SUCCESS', 'FAILED')),
    rows_count INTEGER DEFAULT 0,
    s3_path TEXT,
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_archival_status ON archival_jobs (status, created_at DESC);
CREATE INDEX idx_archival_batch_id ON archival_jobs (batch_id);

-- GDPR 匿名化テーブル
CREATE TABLE IF NOT EXISTS gdpr_anonymizations (
    id UUID PRIMARY KEY NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL,
    anonymized_at TIMESTAMPTZ,
    status VARCHAR(50) NOT NULL CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED')),
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_gdpr_user_id ON gdpr_anonymizations (user_id);
CREATE INDEX idx_gdpr_status ON gdpr_anonymizations (status, created_at DESC);
```

### 6.3 メッセージブローカー
- **AWS SQS**: イベント非同期処理
  - キュー名: `recuerdo-audit-events-queue`
  - DLQ: `recuerdo-audit-events-dlq`
  - メッセージ保有期間: 1 日
  - 可視性タイムアウト: 5 分

### 6.4 外部ライブラリ＆SDK

| ライブラリ | 用途 | バージョン |
|-----------|------|-----------|
| **pgx/v5** | PostgreSQL ドライバ | v5.5+ |
| **go-redis/v9** | Redis キャッシュ | v9.3+ |
| **aws-sdk-go-v2** | AWS S3, SQS | v1.24+ |
| **echo/v4** | HTTP フレームワーク | v4.10+ |
| **uber-go/fx** | DI コンテナ | v1.20+ |
| **go-playground/validator** | バリデーション | v10.16+ |
| **google/uuid** | UUID 生成 | v1.5+ |

### 6.5 依存性注入

```go
// インフラストラクチャ層: DI 設定 (uber-go/fx)

package infrastructure

import (
    "go.uber.org/fx"
    "github.com/jackc/pgx/v5/pgxpool"
    "github.com/redis/go-redis/v9"
    "github.com/aws/aws-sdk-go-v2/service/s3"
    "github.com/aws/aws-sdk-go-v2/service/sqs"
)

// FX モジュール: 依存関係の登録
var AuditModule = fx.Module("audit",
    fx.Provide(
        // インフラストラクチャ提供者
        providePostgresDB,
        provideRedis,
        provideS3Client,
        provideSQSClient,
        
        // リポジトリ実装
        repository.NewPostgresAuditRepository,
        repository.NewPostgresRetentionPolicyRepository,
        repository.NewPostgresArchivalJobRepository,
        
        // ユースケース
        usecase.NewRecordAuditEntryUsecase,
        usecase.NewQueryAuditLogsUsecase,
        usecase.NewArchiveOldLogsUsecase,
        usecase.NewAnonymizeGDPRDataUsecase,
        
        // ハンドラ
        handler.NewSQSEventHandler,
        handler.NewGetAuditLogsHandler,
        handler.NewExportAuditLogsHandler,
        
        // プレゼンター
        handler.NewAuditPresenter,
    ),
)

// providePostgresDB: PostgreSQL コネクションプール
func providePostgresDB(cfg *config.Config) (*pgxpool.Pool, error) {
    pool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
    if err != nil {
        return nil, err
    }
    return pool, nil
}

// provideRedis: Redis クライアント
func provideRedis(cfg *config.Config) *redis.Client {
    return redis.NewClient(&redis.Options{
        Addr: cfg.RedisAddr,
    })
}

// provideS3Client: AWS S3 クライアント
func provideS3Client(cfg *config.Config) *s3.Client {
    // AWS SDK v2 初期化
    awsCfg, _ := config.LoadDefaultConfig(context.Background())
    return s3.NewFromConfig(awsCfg)
}

// provideSQSClient: AWS SQS クライアント
func provideSQSClient(cfg *config.Config) *sqs.Client {
    awsCfg, _ := config.LoadDefaultConfig(context.Background())
    return sqs.NewFromConfig(awsCfg)
}

// main.go での使用
func main() {
    app := fx.New(
        AuditModule,
        fx.Provide(config.LoadConfig),
        fx.Invoke(startServer),
    )
    app.Run()
}

func startServer(
    handler *handler.GetAuditLogsHandler,
    sqsHandler *handler.SQSEventHandler,
) {
    e := echo.New()
    e.GET("/api/audits", handler.Handle)
    
    go sqsHandler.StartConsumer()
    
    e.Start(":8080")
}
```

---

## 7. ディレクトリ構成

```
recuerdo-audit-svc/
├── cmd/
│   ├── main.go                 # エントリポイント
│   └── migrations/             # DB マイグレーション
│       ├── 001_create_audit_tables.sql
│       └── 002_create_partitions.sql
│
├── domain/
│   ├── audit_entry.go          # エンティティ定義
│   ├── retention_policy.go
│   ├── archival_job.go
│   ├── gdpr_anonymization.go
│   ├── value_objects.go        # 値オブジェクト
│   ├── errors.go               # ドメインエラー
│   └── events.go               # ドメインイベント定義
│
├── application/
│   ├── usecase/
│   │   ├── record_audit_entry.go
│   │   ├── query_audit_logs.go
│   │   ├── export_audit_logs.go
│   │   ├── archive_old_logs.go
│   │   └── anonymize_gdpr_data.go
│   ├── port/
│   │   ├── audit_repository.go
│   │   ├── archival_service.go
│   │   └── cache_service.go
│   ├── dto/
│   │   ├── record_audit_entry_dto.go
│   │   ├── query_audit_logs_dto.go
│   │   └── export_audit_logs_dto.go
│   └── mapper/
│       └── audit_mapper.go
│
├── adapter/
│   ├── handler/
│   │   ├── sqs_event_handler.go
│   │   ├── get_audit_logs_handler.go
│   │   ├── export_audit_logs_handler.go
│   │   └── presenter.go
│   ├── repository/
│   │   ├── postgres_audit_repository.go
│   │   ├── postgres_retention_policy_repository.go
│   │   └── postgres_archival_job_repository.go
│   └── external/
│       ├── s3_archival_adapter.go
│       ├── redis_cache_adapter.go
│       ├── sqs_event_publisher.go
│       └── email_notification_adapter.go
│
├── infrastructure/
│   ├── config/
│   │   └── config.go
│   ├── database/
│   │   ├── connection.go
│   │   └── migrations.go
│   ├── cache/
│   │   └── redis.go
│   └── di/
│       └── module.go            # DI 初期化 (fx)
│
├── test/
│   ├── domain/
│   │   └── audit_entry_test.go
│   ├── application/
│   │   └── record_audit_entry_usecase_test.go
│   ├── adapter/
│   │   └── postgres_audit_repository_test.go
│   ├── integration/
│   │   └── sqs_to_postgres_test.go
│   └── fixtures/
│       ├── audit_entries.json
│       └── sample_events.json
│
├── go.mod
├── go.sum
├── Dockerfile
├── docker-compose.test.yml
├── README.md
└── .env.example
```

---

## 8. 依存性ルールと境界
### 8.1 許可される依存関係

| From Layer | To Layer | 許可 | 説明 |
|-----------|----------|------|------|
| Framework | Adapter | ✓ | ハンドラ実装、リポジトリ実装など |
| Adapter | Application | ✓ | ユースケース呼び出し、DTO 変換 |
| Application | Domain | ✓ | エンティティ、値オブジェクト使用 |
| Domain | (外部) | ✗ | フレームワーク、ライブラリ非参照 |
| Application | Framework | ✗ | DI コンテナのみ許可（初期化時） |
| Adapter | Adapter | ✗ | 各アダプタは独立、ポート経由で通信 |

### 8.2 境界の横断
1. **入口 (Handler → UseCase)**:
   - HTTP ハンドラが HTTP リクエスト → DTO に変換
   - ユースケースインスタンス呼び出し
   
2. **出口 (UseCase → Repository)**:
   - ユースケースが Abstract Repository ポート参照
   - 実装は DI コンテナで注入
   
3. **エラー処理**:
   - ドメインエラー → Application エラー → HTTP 400/403/500 に変換

### 8.3 ルールの強制
- **コンパイル時**: Go 内部パッケージ (`internal/domain`, `internal/application`) でアクセス制限
- **実行時**: ポート (インターフェース) 経由で外部参照、実装クラスは非公開
- **テスト**: Mock インターフェース実装で境界検証

---

## 9. テスト戦略
### 9.1 テストピラミッド

| レベル | カウント | 説明 | ツール |
|--------|---------|------|--------|
| **ユニット** | 40% | ドメインモデル、値オブジェクト | `testing`, `testify/assert` |
| **統合** | 35% | ユースケース + Mock リポジトリ | `testing`, `testify/mock` |
| **E2E** | 25% | SQS → DB → キャッシュ全フロー | `docker-compose`, `testcontainers` |

### 9.2 テスト例

```go
// domain/audit_entry_test.go: ドメインテスト
package domain_test

import (
    "testing"
    "time"
    "github.com/stretchr/testify/assert"
    "github.com/google/uuid"
    "recuerdo/audit/domain"
)

func TestAuditEntryImmutability(t *testing.T) {
    entry := &domain.AuditEntry{
        ID:        uuid.New(),
        ActorID:   "user-123",
        Action:    domain.ActionWrite,
        CreatedAt: time.Now(),
    }
    
    // エンティティは作成後 immutable
    assert.True(t, entry.IsImmutable())
}

func TestRecordAuditEntryValidation(t *testing.T) {
    tests := []struct {
        name    string
        input   *domain.AuditEntry
        wantErr bool
    }{
        {
            name: "valid audit entry",
            input: &domain.AuditEntry{
                ID:           uuid.New(),
                ActorID:      "user-123",
                ActorType:    domain.ActorUser,
                Action:       domain.ActionWrite,
                ResourceType: domain.ResourceMedia,
                ResourceID:   "media-456",
                Result:       domain.ResultAllowed,
                IPAddress:    "192.168.1.1",
                OccurredAt:   time.Now().UTC(),
                CreatedAt:    time.Now().UTC(),
            },
            wantErr: false,
        },
        {
            name: "missing actor_id",
            input: &domain.AuditEntry{
                ID:        uuid.New(),
                ActorID:   "",
                CreatedAt: time.Now(),
            },
            wantErr: true,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := tt.input.Validate()
            if tt.wantErr {
                assert.Error(t, err)
            } else {
                assert.NoError(t, err)
            }
        })
    }
}

// application/record_audit_entry_usecase_test.go: ユースケーステスト
package application_test

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "recuerdo/audit/application"
    "recuerdo/audit/domain"
)

type MockAuditRepository struct {
    mock.Mock
}

func (m *MockAuditRepository) Save(ctx context.Context, entry *domain.AuditEntry) error {
    args := m.Called(ctx, entry)
    return args.Error(0)
}

func TestRecordAuditEntryUsecase(t *testing.T) {
    mockRepo := new(MockAuditRepository)
    mockRepo.On("Save", mock.Anything, mock.MatchedBy(func(e *domain.AuditEntry) bool {
        return e.ActorID == "user-123" && e.Action == domain.ActionWrite
    })).Return(nil)
    
    usecase := application.NewRecordAuditEntryUsecase(mockRepo)
    
    input := &application.RecordAuditEntryInput{
        ActorID:      "user-123",
        ActorType:    "USER",
        Action:       "WRITE",
        ResourceType: "MEDIA",
        ResourceID:   "media-456",
        Result:       "ALLOWED",
        IPAddress:    "192.168.1.1",
        OccurredAt:   "2026-04-13T10:00:00Z",
    }
    
    output, err := usecase.Execute(context.Background(), input)
    
    assert.NoError(t, err)
    assert.NotNil(t, output)
    assert.NotEmpty(t, output.AuditEntryID)
    mockRepo.AssertExpectations(t)
}

// adapter/postgres_audit_repository_test.go: 統合テスト
package adapter_test

import (
    "context"
    "testing"
    "testcontainers"
    "github.com/stretchr/testify/assert"
    "recuerdo/audit/adapter/repository"
    "recuerdo/audit/domain"
)

func TestPostgresAuditRepository_Save(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test")
    }
    
    // PostgreSQL コンテナ起動
    postgres := testcontainers.NewPostgresContainer(t)
    defer postgres.Terminate(context.Background())
    
    pool := postgres.Pool()
    repo := repository.NewPostgresAuditRepository(pool)
    
    entry := &domain.AuditEntry{
        ID:           uuid.New(),
        ActorID:      "user-123",
        ActorType:    domain.ActorUser,
        Action:       domain.ActionWrite,
        ResourceType: domain.ResourceMedia,
        ResourceID:   "media-456",
        Result:       domain.ResultAllowed,
        IPAddress:    "192.168.1.1",
        OccurredAt:   time.Now().UTC(),
        CreatedAt:    time.Now().UTC(),
    }
    
    err := repo.Save(context.Background(), entry)
    assert.NoError(t, err)
    
    // 検証: DB から取得
    retrieved, err := repo.FindByID(context.Background(), entry.ID)
    assert.NoError(t, err)
    assert.Equal(t, entry.ActorID, retrieved.ActorID)
}
```

---

## 10. エラーハンドリング
### 10.1 ドメインエラー

```go
type ValidationError struct {
    Message string
}

type ImmutableViolationError struct {
    Message string
}

type NotFoundError struct {
    ResourceID string
}
```

### 10.2 アプリケーションエラー
- **InvalidInputError**: DTO バリデーション失敗
- **RepositoryError**: DB 永続化失敗
- **ArchivalError**: S3 アーカイバル失敗
- **CacheError**: Redis キャッシュ失敗

### 10.3 エラー変換 (HTTP マッピング)

| ドメイン / アプリケーションエラー | HTTP ステータス | HTTP メッセージ |
|-----------|--------|---------|
| ValidationError | 400 | "Invalid input: {details}" |
| ImmutableViolationError | 409 | "Cannot modify immutable record" |
| NotFoundError | 404 | "Audit entry not found" |
| UnauthorizedError | 403 | "Access denied" |
| RepositoryError | 500 | "Database error" |
| ArchivalError | 500 | "Archival service unavailable" |

---

## 11. 横断的関心事
### 11.1 ロギング
- **構造化ロギング**: JSON フォーマット（Zap, Logrus）
- **レベル**: INFO (API 呼び出し), ERROR (例外), DEBUG (DB クエリ)
- **トレース ID**: SQS メッセージ ID を全ログに包含

### 11.2 認証・認可
- **認証**: JWT ベアラトークン（Authorization ヘッダ）
- **認可**: 管理者ロールチェック（GET /api/audits は Admin のみ）
- **ミドルウェア**: Echo Middleware で認証検証

### 11.3 バリデーション
- **入力DTO**: `go-playground/validator` 使用
- **ドメイン**: Entity.Validate() メソッド
- **ルール**: 必須フィールド、enum 値、IP アドレス形式など

### 11.4 キャッシング
- **キャッシュ対象**: QueryAuditLogs 結果（5 分 TTL）
- **無効化**: 新規 AuditEntry 記録時に pattern invalidate
- **実装**: Redis `SETEX`, `GET`, `DEL` コマンド

---

## 12. マイグレーション計画
### 12.1 現状
- 既存システム: in-memory ログ（再起動で消失）
- スケーラビリティ: 1 サービスのみ
- コンプライアンス: GDPR 対応なし

### 12.2 目標状態
- PostgreSQL APPEND-ONLY ログ
- 複数マイクロサービス間の一元監査
- GDPR 削除リクエスト自動化
- S3 冷保存アーカイバル

### 12.3 マイグレーション手順

| フェーズ | 期間 | 作業 | リスク |
|---------|------|------|--------|
| **フェーズ 1** | W1-2 | PostgreSQL テーブル作成、パーティション設定 | テーブル設計誤り |
| **フェーズ 2** | W3-4 | SQS Consumer 実装、RecordAuditEntry テスト | メッセージ損失 |
| **フェーズ 3** | W5-6 | QueryAuditLogs API 実装、キャッシング | キャッシュ一貫性 |
| **フェーズ 4** | W7-8 | S3 アーカイバル、GDPR 匿名化実装 | データ消失 |
| **フェーズ 5** | W9-10 | ロードテスト、本番デプロイ | パフォーマンス低下 |

---

## 13. 未決事項と決定事項

| 項目 | ステータス | 決定 | 理由 |
|------|-----------|------|------|
| **メッセージフォーマット** | DECIDED | JSON (SQS) | 汎用性、デシリアライズ容易 |
| **キャッシュ戦略** | DECIDED | Redis (5min TTL) | QueryAuditLogs 頻出、低遅延必須 |
| **アーカイバル形式** | PENDING | Parquet vs CSV | 圧縮率と分析ツール互換性で検討中 |
| **GDPR 保持期間** | DECIDED | 匿名化後 1 年保持 | 法的最小要件 + 分析用 |
| **SQS リトライ** | DECIDED | DLQ + 3 回リトライ | 一時的なエラーに対応 |
| **テスト DB** | DECIDED | testcontainers | CI/CD 環境での再現性 |

---

## 14. 参考資料
- **Clean Architecture** (Uncle Bob): https://blog.cleancoder.com/
- **Domain-Driven Design** (Eric Evans): https://www.domainlanguage.com/
- **PostgreSQL パーティショニング**: https://www.postgresql.org/docs/current/ddl-partitioning.html
- **AWS S3 ライフサイクル**: https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html
- **GDPR コンプライアンス**: https://www.gdpr.eu/
- **uber-go/fx DI**: https://pkg.go.dev/go.uber.org/fx
