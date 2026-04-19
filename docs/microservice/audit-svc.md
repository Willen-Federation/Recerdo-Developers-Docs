# Audit Service (recuerdo-audit-svc)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoの全マイクロサービスからのイベント（API呼び出し、データアクセス、管理者操作、セキュリティイベント）に対して、不変の監査ログ（Audit Trail）を記録し、GDPR準拠性を実現するドメイン層設計書。監査サービスは監査ログを追記専用（Append-Only）で保持し、記録の削除・更新を一切許さない。後続システムは「誰が、何に、いつ、なぜアクセスしたか」を常に監査可能な状態とする。管理画面・コンプライアンスレポート・GDPR個人情報開示（Data Export）の基盤となる。

### ビジネスコンテキスト

解決する問題:
- GDPRコンプライアンス: 個人データへのアクセス履歴が不明確で、規制当局への説明責任が果たせない
- セキュリティインシデント対応: 不正アクセスの検証・原因究明に時間がかかる
- 監査人対応: 管理者操作の根拠が可視化できず、内部統制が脆弱

Key User Stories:
- コンプライアンス担当者として、過去3年間のユーザーデータアクセス履歴をCSV形式でエクスポートし、規制当局に報告したい
- セキュリティエンジニアとして、特定ユーザーの過去1週間の全操作（成功・失敗含む）をフィルタリングして確認し、異常検知したい
- GDPRの忘却権対応として、個人情報を削除するときに、個人識別情報（名前・メールアドレス）をハッシュに置き換えつつ、監査ログ構造は保持し続けたい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ      | 説明                                               | 主要属性                                                                                                                                                                                               |
| ----------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| AuditEntry        | 監査対象の操作1件を記録する不変なログエントリ      | entry_id (UUID), actor_id, actor_type, action, resource_type, resource_id, timestamp, result (SUCCESS/FAILURE), reason?, ip_address, user_agent, metadata (JSON), created_at (immutable), archived_at? |
| RetentionPolicy   | 監査ログの保管期間と削除方針を定義                 | policy_id, resource_type, action, retention_days (e.g. 2555 = 7年), archive_after_days (730 = 2年後S3へ), is_gdpr_sensitive (true=GDPRデータ削除対象), created_at, updated_at                          |
| ArchivalJob       | 古い監査ログをS3へ移行するジョブ                   | job_id, scheduled_at, started_at, completed_at, status (PENDING/RUNNING/COMPLETED/FAILED), record_count, s3_location, error_message?                                                                   |
| GDPRAnonymization | GDPR削除要請に対するユーザーデータの匿名化処理履歴 | anonymization_id, user_id, resource_ids[], anonymized_at, reason (FORGETTING_RIGHT/DATA_LOSS), operator_id, status (QUEUED/PROCESSING/COMPLETED/FAILED)                                                |

### 値オブジェクト

| 値オブジェクト                            | 説明                                 | バリデーションルール                                                                                             |
| ----------------------------------------- | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| AuditAction                               | 監査対象操作の種別                   | 値: READ / WRITE / DELETE / LOGIN / LOGOUT / PERMISSION_CHECK / ADMIN_ACTION。ドメインの主要な操作カテゴリに限定 |
| ResourceType                              | 監査対象リソースの種別               | 値: USER / ORG / MEDIA / ALBUM / EVENT / MESSAGE / ROLE / INTEGRATION。新規リソースタイプは設計変更が必要        |
| ActorType                                 | 操作者の種別                         | 値: USER (エンドユーザー) / SERVICE (マイクロサービス) / SYSTEM (内部スケジューラ)。認証方式の区別に使用         |
| AuditResult                               | 操作の成功・失敗状態                 | 値: SUCCESS / FAILURE。失敗時は reason フィールドで詳細を記録                                                    |
| PII (Personally Identifiable Information) | 個人特定情報の匿名化値               | 元データのSHA256ハッシュ。復号不可。GDPR削除時にuser_name/email/phone等を置き換える                              |
| QueryFilter                               | 監査ログ検索クエリの条件オブジェクト | actor_id, resource_type, action, date_range (from_ts/to_ts), result?。全フィールドOPT オプショナル               |

### ドメインルール / 不変条件

- AuditEntryは一度記録されたら更新・削除されてはならない（Append-Only）
- 全AuditEntryはactor_idを必須とする（無人操作は禁止）
- archived_at != null のAuditEntryはS3に移行済みで、ホットストレージ（MySQL）に存在しない
- GDPRAnonymizationが COMPLETED 状態のユーザーのAuditEntryは、user_name/email/phone等をPII（ハッシュ）に置き換える
- RetentionPolicyで指定された retention_days を超えたログは、S3への自動アーカイブ対象となる（削除ではなくアーカイブ）
- GDPRデータ削除対応時も、AuditEntry自体は物理削除しない。代わりに個人情報だけを不可逆的に匿名化する
- Permission Serviceがこのサービスをポーリングするため、AuditEntry作成から最大100ms以内に読み取り可能な状態にしなければならない

### ドメインイベント

| イベント                   | トリガー                                                   | 主要ペイロード                                                                               |
| -------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| AuditEntryRecorded         | QueuePort メッセージ（Beta: Redis+BullMQ/asynq、本番: OCI Queue）より新規 AuditEntry 作成時 | entry_id, actor_id, action, resource_type, resource_id, timestamp, result                    |
| ArchivalCompleted          | ArchivalJob完了時                                          | job_id, archived_record_count, s3_location, completion_timestamp                             |
| GDPRAnonymizationRequested | GDPR個人削除要請受信時                                     | anonymization_id, user_id, resource_ids, reason                                              |
| GDPRAnonymizationCompleted | ユーザー情報の匿名化完了時                                 | anonymization_id, user_id, anonymized_record_count, completion_timestamp                     |
| AuditQueryExecuted         | 管理画面・コンプライアンスレポートから監査ログを検索実行時 | query_id, filter (actor_id/resource_type/date_range等), result_count, executor_id, timestamp |

### エンティティ定義（コードスケッチ）

```go
// Go-style pseudocode

type AuditEntry struct {
    EntryID    string                 `json:"entry_id"`    // UUID
    ActorID    string                 `json:"actor_id"`    // 必須。ユーザーID / サービス名
    ActorType  ActorType              `json:"actor_type"`  // USER / SERVICE / SYSTEM
    Action     AuditAction            `json:"action"`      // READ / WRITE / DELETE / ...
    ResourceType ResourceType         `json:"resource_type"` // USER / ORG / MEDIA / ...
    ResourceID string                 `json:"resource_id"`   // 操作対象リソースのID
    Timestamp  time.Time              `json:"timestamp"`     // 操作の発生時刻
    Result     AuditResult            `json:"result"`        // SUCCESS / FAILURE
    Reason     *string                `json:"reason,omitempty"` // 失敗時の理由
    IPAddress  string                 `json:"ip_address"`    // クライアントIP
    UserAgent  string                 `json:"user_agent"`    // HTTP User-Agent
    Metadata   map[string]interface{} `json:"metadata"`      // 追加情報（JSON）
    CreatedAt  time.Time              `json:"created_at"`    // 記録作成時刻（不変）
    ArchivedAt *time.Time             `json:"archived_at,omitempty"` // S3移行済み時刻
}

func (a *AuditEntry) Validate() error {
    if a.EntryID == "" { return ErrMissingEntryID }
    if a.ActorID == "" { return ErrMissingActorID }
    if err := a.Action.Validate(); err != nil { return err }
    if err := a.ResourceType.Validate(); err != nil { return err }
    if err := a.ActorType.Validate(); err != nil { return err }
    if a.CreatedAt.IsZero() { return ErrMissingCreatedAt }
    return nil
}

func (a *AuditEntry) CanBeArchived(now time.Time, retentionDays int) bool {
    cutoffTime := a.CreatedAt.AddDate(0, 0, retentionDays)
    return now.After(cutoffTime) && a.ArchivedAt == nil
}

type RetentionPolicy struct {
    PolicyID      string    `json:"policy_id"`      // UUID
    ResourceType  string    `json:"resource_type"`  // null = 全リソースタイプ
    Action        string    `json:"action"`         // null = 全操作
    RetentionDays int       `json:"retention_days"` // 保管期間（日数）
    ArchiveAfterDays int    `json:"archive_after_days"` // アーカイブ移行日数
    IsGDPRSensitive bool    `json:"is_gdpr_sensitive"` // GDPR削除対象か
    CreatedAt     time.Time `json:"created_at"`
    UpdatedAt     time.Time `json:"updated_at"`
}

func (r *RetentionPolicy) Validate() error {
    if r.RetentionDays <= 0 { return ErrInvalidRetentionDays }
    if r.ArchiveAfterDays > r.RetentionDays {
        return ErrArchiveDaysExceedsRetention
    }
    return nil
}

type GDPRAnonymization struct {
    AnonymizationID string     `json:"anonymization_id"` // UUID
    UserID          string     `json:"user_id"`
    ResourceIDs     []string   `json:"resource_ids"`     // 関連リソースID
    AnonymizedAt    *time.Time `json:"anonymized_at"`
    Reason          string     `json:"reason"`           // FORGETTING_RIGHT / DATA_LOSS
    OperatorID      string     `json:"operator_id"`      // 実行者（管理者）
    Status          string     `json:"status"`           // QUEUED / PROCESSING / COMPLETED / FAILED
    CreatedAt       time.Time  `json:"created_at"`
    UpdatedAt       time.Time  `json:"updated_at"`
}

func (g *GDPRAnonymization) IsCompleted() bool {
    return g.Status == "COMPLETED"
}

type ArchivalJob struct {
    JobID         string     `json:"job_id"`         // UUID
    ScheduledAt   time.Time  `json:"scheduled_at"`
    StartedAt     *time.Time `json:"started_at"`
    CompletedAt   *time.Time `json:"completed_at"`
    Status        string     `json:"status"`         // PENDING / RUNNING / COMPLETED / FAILED
    RecordCount   int        `json:"record_count"`   // アーカイブされたレコード数
    ArchiveLocation *string  `json:"archive_location"` // object-storage://bucket/prefix/... (Beta: Garage / 本番: OCI Object Storage)
    ErrorMessage  *string    `json:"error_message"`
    CreatedAt     time.Time  `json:"created_at"`
    UpdatedAt     time.Time  `json:"updated_at"`
}

func (a *ArchivalJob) CanStart() bool {
    return a.Status == "PENDING" && time.Now().After(a.ScheduledAt)
}

func (a *ArchivalJob) MarkAsRunning(now time.Time) error {
    if a.Status != "PENDING" { return ErrJobNotPending }
    a.Status = "RUNNING"
    a.StartedAt = &now
    return nil
}

func (a *ArchivalJob) MarkAsCompleted(now time.Time, count int, s3Loc string) error {
    if a.Status != "RUNNING" { return ErrJobNotRunning }
    a.Status = "COMPLETED"
    a.CompletedAt = &now
    a.RecordCount = count
    a.S3Location = &s3Loc
    return nil
}
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース           | 入力DTO                                                                                                        | 出力DTO                                                                      | 説明                                           |
| ---------------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------- |
| RecordAuditEntry       | RecordAuditEntryInput{actor_id, action, resource_type, resource_id, result, reason?, ip, user_agent, metadata} | RecordAuditEntryOutput{entry_id}                                             | QueuePort メッセージ受信→監査ログ作成・保存     |
| QueryAuditLogs         | QueryAuditLogsInput{actor_id?, resource_type?, action?, from_ts?, to_ts?, limit, offset}                       | QueryAuditLogsOutput{entries[], total_count, next_offset}                    | 管理画面/レポート用の監査ログ検索              |
| ExportAuditLogs        | ExportAuditLogsInput{actor_id?, resource_type?, action?, from_ts?, to_ts?, format (CSV/JSON)}                  | ExportAuditLogsOutput{file_url, expires_at}                                  | GDPR個人情報開示・コンプライアンスレポート生成 |
| ArchiveOldLogs         | ArchiveOldLogsInput{retention_policy_id, batch_size}                                                           | ArchiveOldLogsOutput{archived_count, next_batch_offset, job_status}          | バッチジョブ: MySQL→S3への古いログ移行         |
| AnonymizeGDPRData      | AnonymizeGDPRDataInput{user_id, reason}                                                                        | AnonymizeGDPRDataOutput{anonymization_id, anonymized_count}                  | GDPR削除要請時に個人情報をハッシュで置き換え   |
| GetRetentionPolicies   | GetRetentionPoliciesInput{resource_type?}                                                                      | GetRetentionPoliciesOutput{policies[]}                                       | 保管期間ポリシーの照会                         |
| CreateRetentionPolicy  | CreateRetentionPolicyInput{resource_type?, action?, retention_days, archive_after_days, is_gdpr_sensitive}     | CreateRetentionPolicyOutput{policy_id}                                       | 保管期間ポリシーの新規作成                     |
| ScheduleArchivalJob    | ScheduleArchivalJobInput{scheduled_at}                                                                         | ScheduleArchivalJobOutput{job_id}                                            | 定期的なアーカイブジョブのスケジューリング     |
| GetAnonymizationStatus | GetAnonymizationStatusInput{anonymization_id}                                                                  | GetAnonymizationStatusOutput{status, anonymized_count, completion_timestamp} | GDPR匿名化処理の進捗確認                       |

### ユースケース詳細（主要ユースケース）

## RecordAuditEntry — 主要ユースケース詳細

### トリガー
- API Gateway が AuthenticationFailed / PermissionDenied イベントを QueuePort 経由で送信
- Auth Service が login/logout イベントを QueuePort 経由で送信
- User Service / Org Service / Storage Service 等が data mutation (WRITE/DELETE) イベントを QueuePort 経由で送信
- QueuePort 実装: Beta は Redis + BullMQ (Node) / asynq (Go)、本番は OCI Queue Service（差分は Feature Flag + 環境変数で切替）

### フロー
1. QueuePort.Consume（Beta: Redis+BullMQ/asynq、本番: OCI Queue の long-poll）でメッセージを取得
2. メッセージペイロードを RecordAuditEntryInput にデシリアライズ
   - 不正フォーマット → DLQへ移動、エラーログ記録
3. ActorID存在チェック
   - 空またはnull → ErrMissingActorID を返す
4. Action / ResourceType / ActorType の enum バリデーション
   - 不正値 → ErrInvalidAuditAction / ErrInvalidResourceType
5. AuditEntry エンティティ生成（CreatedAt = now、ArchivedAt = null）
6. AuditEntryRepository.Save(ctx, entry) で MySQL に INSERT
   - トランザクション分離レベル: READ_COMMITTED
   - Uniqueness: (entry_id) は自動生成UUID、重複なし
7. AuditEntryRecorded ドメインイベント発行
   - QueuePort.Publish(`recuerdo.audit.entry_recorded`) → permission-svc・admin-dashboard・compliance-reporter が購読
8. QueryCache（Redis）をinvalidate (actor_id, resource_type キーで削除)
9. QueuePort.Ack でメッセージ削除（visibility timeout 満了前に成功をマーク。Redis+BullMQ は completedJob 処理、OCI Queue は DeleteMessage）
10. 成功ログ: "AuditEntry recorded: entry_id={id}, actor_id={actor}, action={action}"

### 注意事項
- QueuePort メッセージ処理は idempotent であること（entry_id が重複していないか確認）
- MySQL/MariaDB commit の成功 → QueuePort.Ack の順序が重要（commit 後に ack しないと重複記録が起きる）
- 処理時間目標: P99 100ms以内（キャッシュ invalidate のコスト含む）

### リポジトリ・サービスポート（インターフェース）

```go
// Repository Ports
type AuditEntryRepository interface {
    Save(ctx context.Context, entry *AuditEntry) error
    FindByID(ctx context.Context, entryID string) (*AuditEntry, error)
    FindByQuery(ctx context.Context, filter *QueryFilter, limit int, offset int) ([]*AuditEntry, int, error)
    // FindByQuery は total_count を3番目の戻り値で返す（ページネーション用）
    FindOldestUnarchived(ctx context.Context, olderThanDays int, limit int) ([]*AuditEntry, error)
    ArchiveToS3(ctx context.Context, entries []*AuditEntry, s3Location string) error
    AnonymizeByUserID(ctx context.Context, userID string, piiHash map[string]string) error
    // AnonymizeByUserID は user_name/email/phone を piiHash の値で置き換える（不可逆的に）
}

type RetentionPolicyRepository interface {
    FindAll(ctx context.Context) ([]*RetentionPolicy, error)
    FindByResourceType(ctx context.Context, resourceType string) (*RetentionPolicy, error)
    Save(ctx context.Context, policy *RetentionPolicy) error
    Update(ctx context.Context, policy *RetentionPolicy) error
}

type GDPRAnonymizationRepository interface {
    Save(ctx context.Context, anon *GDPRAnonymization) error
    FindByID(ctx context.Context, anonymizationID string) (*GDPRAnonymization, error)
    FindPending(ctx context.Context) ([]*GDPRAnonymization, error)
    Update(ctx context.Context, anon *GDPRAnonymization) error
}

type ArchivalJobRepository interface {
    Save(ctx context.Context, job *ArchivalJob) error
    FindPending(ctx context.Context) ([]*ArchivalJob, error)
    FindByID(ctx context.Context, jobID string) (*ArchivalJob, error)
    Update(ctx context.Context, job *ArchivalJob) error
}

// Service Ports
type QueuePort interface {
    // 監査イベントの受信と発行を抽象化（Beta: Redis+BullMQ/asynq、本番: OCI Queue Service）
    Consume(ctx context.Context, topic string, handler MessageHandler) error
    Publish(ctx context.Context, topic string, payload []byte) error
    Ack(ctx context.Context, messageID string) error
}

type EventPublisherPort interface {
    Publish(ctx context.Context, event DomainEvent) error  // QueuePort 委譲
}

type QueryCachePort interface {
    Set(ctx context.Context, key string, value interface{}, ttl time.Duration) error
    Get(ctx context.Context, key string) (interface{}, error)
    Delete(ctx context.Context, key string) error
}

type ObjectStorageExportPort interface {
    // Garage（Beta）/ OCI Object Storage（本番）どちらも S3 互換 API で実装
    UploadCSV(ctx context.Context, entries []*AuditEntry, bucket, key string) (string, error)
    UploadJSON(ctx context.Context, entries []*AuditEntry, bucket, key string) (string, error)
    ArchiveRecords(ctx context.Context, entries []*AuditEntry, bucket, prefix string) (string, error)  // Parquet / NDJSON アーカイブ
}

type GDPRAnonymizationPort interface {
    AnonymizeEmail(email string) string       // SHA256ハッシュ化
    AnonymizePhoneNumber(phone string) string // SHA256ハッシュ化
    AnonymizeName(name string) string         // SHA256ハッシュ化
}
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ           | ルート/トリガー          | ユースケース                                       |
| ---------------------- | ------------------------ | -------------------------------------------------- |
| QueueAuditConsumer     | Topic: `recuerdo.audit.events` | RecordAuditEntryUseCase                      |
| QueryAuditLogsHandler  | POST /admin/audit/query  | QueryAuditLogsUseCase                              |
| ExportAuditLogsHandler | POST /admin/audit/export | ExportAuditLogsUseCase                             |
| GDPRAnonymizeHandler   | POST /gdpr/anonymize     | AnonymizeGDPRDataUseCase                           |
| ArchivalJobScheduler   | Cron: 毎日 02:00 UTC     | ScheduleArchivalJobUseCase → ArchiveOldLogsUseCase |
| ArchivalJobWorker      | polling 10秒間隔         | ArchiveOldLogsUseCase (スケーリング可能)           |
| HealthHandler          | GET /health              | ヘルスチェック（ユースケース不要）                 |
| MetricsHandler         | GET /metrics             | Prometheusメトリクス（ユースケース不要）           |

### リポジトリ実装

| ポートインターフェース      | 実装クラス               | データストア                                             |
| --------------------------- | ------------------------ | -------------------------------------------------------- |
| AuditEntryRepository        | MySQLAuditRepository     | MySQL 8.0 / MariaDB 10.11 (audit_entries テーブル、月ごと RANGE パーティション) |
| RetentionPolicyRepository   | MySQLRetentionRepository | MySQL 8.0 / MariaDB 10.11 (retention_policies テーブル)                         |
| GDPRAnonymizationRepository | MySQLGDPRRepository      | MySQL 8.0 / MariaDB 10.11 (gdpr_anonymizations テーブル)                        |
| ArchivalJobRepository       | MySQLArchivalRepository  | MySQL 8.0 / MariaDB 10.11 (archival_jobs テーブル)                              |
| QueryCachePort              | RedisQueryCache          | Redis 7.x (キー: audit_query:{hash}, TTL: 5分)                                  |

### 外部サービスアダプタ

| ポートインターフェース | アダプタクラス     | 外部システム                           |
| ---------------------- | ------------------ | -------------------------------------- |
| QueuePort              | **Beta:** `RedisBullMQAdapter` / `AsynqAdapter` / **本番:** `OCIQueueAdapter` | Redis 7.x + BullMQ/asynq / OCI Queue Service（Topic: `recuerdo.audit.events`） |
| EventPublisherPort     | `QueueEventPublisher`（QueuePort 委譲） | Topic: `recuerdo.audit.entry_recorded`                   |
| ObjectStorageExportPort | **Beta:** `GarageArchivalAdapter` / **本番:** `OCIArchivalAdapter` | Garage（S3 互換 OSS, CoreServerV2 CORE+X）/ OCI Object Storage。バケット: `recuerdo-audit-exports` |
| GDPRAnonymizationPort  | `SHA256Anonymizer` | 標準ライブラリ crypto/sha256                                               |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + net/http + chi (HTTP ルーター) + aws-sdk-go-v2/service/s3（**S3 互換 API クライアント** として Garage / OCI Object Storage を操作）+ hibiken/asynq または Redis + BullMQ クライアント（Beta）/ OCI SDK（本番）

### データベース

MySQL 8.0 / MariaDB 10.11（互換性テスト必須。すべてのクエリを両方で CI 実行）。audit_entries テーブルは月ごとパーティション（RANGE パーティショニング by created_at）で、古いパーティションの高速削除・アーカイブを実現。Beta: XServer VPS 自己運用、本番: OCI MySQL HeatWave。

#### SQL スキーマ例

```sql
-- audit_entries テーブル（親テーブル、パーティション親）
CREATE TABLE audit_entries (
    entry_id UUID PRIMARY KEY,
    actor_id VARCHAR(255) NOT NULL,
    actor_type VARCHAR(50) NOT NULL,
    action VARCHAR(50) NOT NULL,
    resource_type VARCHAR(50) NOT NULL,
    resource_id VARCHAR(255) NOT NULL,
    timestamp TIMESTAMP(6) NOT NULL,
    result VARCHAR(20) NOT NULL,
    reason TEXT,
    ip_address VARCHAR(45),
    user_agent TEXT,
    metadata JSON,
    created_at TIMESTAMP(6) NOT NULL,
    archived_at TIMESTAMP(6),
    
    CONSTRAINT chk_action CHECK (action IN ('READ','WRITE','DELETE','LOGIN','LOGOUT','PERMISSION_CHECK','ADMIN_ACTION')),
    CONSTRAINT chk_resource_type CHECK (resource_type IN ('USER','ORG','MEDIA','ALBUM','EVENT','MESSAGE','ROLE','INTEGRATION')),
    CONSTRAINT chk_result CHECK (result IN ('SUCCESS','FAILURE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  PARTITION BY RANGE (YEAR(created_at) * 100 + MONTH(created_at)) (
    PARTITION p202604 VALUES LESS THAN (202605),
    PARTITION p202605 VALUES LESS THAN (202606),
    PARTITION p202606 VALUES LESS THAN (202607),
    PARTITION pmax    VALUES LESS THAN MAXVALUE
  );

-- 月次パーティションは ALTER TABLE ... REORGANIZE PARTITION で追加／削除する
-- （PostgreSQL の CREATE TABLE ... PARTITION OF は MySQL/MariaDB に存在しないため使用しない）
CREATE INDEX idx_audit_entries_actor_id       ON audit_entries(actor_id);
CREATE INDEX idx_audit_entries_resource_id    ON audit_entries(resource_id);
CREATE INDEX idx_audit_entries_created_at     ON audit_entries(created_at);
CREATE INDEX idx_audit_entries_action_resource ON audit_entries(action, resource_type);

-- retention_policies テーブル
CREATE TABLE retention_policies (
    policy_id          CHAR(36)    NOT NULL,               -- UUID 文字列 (gen_random_uuid() は不使用)
    resource_type      VARCHAR(50),
    action             VARCHAR(50),
    retention_days     INT         NOT NULL,
    archive_after_days INT         NOT NULL,
    is_gdpr_sensitive  TINYINT(1)  NOT NULL DEFAULT 0,
    created_at         DATETIME(6) NOT NULL,
    updated_at         DATETIME(6) NOT NULL,
    PRIMARY KEY (policy_id),
    CONSTRAINT chk_retention_days CHECK (retention_days > 0),
    CONSTRAINT chk_archive_days CHECK (archive_after_days <= retention_days)
);

CREATE INDEX idx_retention_policies_resource_type ON retention_policies(resource_type);

-- gdpr_anonymizations テーブル
CREATE TABLE gdpr_anonymizations (
    anonymization_id UUID PRIMARY KEY,
    user_id VARCHAR(255) NOT NULL,
    resource_ids TEXT[] NOT NULL,
    anonymized_at TIMESTAMP(6),
    reason VARCHAR(100) NOT NULL,
    operator_id VARCHAR(255) NOT NULL,
    status VARCHAR(50) NOT NULL,
    created_at TIMESTAMP(6) NOT NULL,
    updated_at TIMESTAMP(6) NOT NULL,
    
    CONSTRAINT chk_status CHECK (status IN ('QUEUED','PROCESSING','COMPLETED','FAILED'))
);

CREATE INDEX idx_gdpr_anonymizations_user_id ON gdpr_anonymizations(user_id);
CREATE INDEX idx_gdpr_anonymizations_status ON gdpr_anonymizations(status);

-- archival_jobs テーブル
CREATE TABLE archival_jobs (
    job_id UUID PRIMARY KEY,
    scheduled_at TIMESTAMP(6) NOT NULL,
    started_at TIMESTAMP(6),
    completed_at TIMESTAMP(6),
    status VARCHAR(50) NOT NULL,
    record_count INTEGER,
    s3_location VARCHAR(512),
    error_message TEXT,
    created_at TIMESTAMP(6) NOT NULL,
    updated_at TIMESTAMP(6) NOT NULL,
    
    CONSTRAINT chk_status CHECK (status IN ('PENDING','RUNNING','COMPLETED','FAILED'))
);

CREATE INDEX idx_archival_jobs_status ON archival_jobs(status);
CREATE INDEX idx_archival_jobs_scheduled_at ON archival_jobs(scheduled_at);
```

### 主要ライブラリ・SDK

| ライブラリ                | 目的                            | レイヤー       |
| ------------------------- | ------------------------------- | -------------- |
| hibiken/asynq (Go) / BullMQ (Node) | Beta: Redis ベースの QueuePort 実装 | Infrastructure |
| OCI Queue Service SDK     | 本番: OCI Queue 実装            | Infrastructure |
| aws-sdk-go-v2/service/s3  | **S3 互換 API クライアント** として Garage / OCI Object Storage にエクスポート・アーカイブ | Infrastructure |
| github.com/go-sql-driver/mysql | MySQL 8.0 / MariaDB 10.11 両対応ドライバ | Infrastructure |
| go-redis/v9               | Redis クエリキャッシュ          | Infrastructure |
| github.com/google/uuid    | UUID 生成                       | Domain         |
| github.com/go-chi/chi/v5  | HTTP ルーター                   | Adapter        |
| uber-go/fx                | 依存性注入                      | Infrastructure |
| uber-go/zap               | 構造化ログ                      | Infrastructure |
| go.opentelemetry.io/otel  | 分散トレーシング                | Infrastructure |
| prometheus/client_golang  | メトリクス収集                  | Infrastructure |
| github.com/jmoiron/sqlc   | SQL コード生成                  | Infrastructure |

### 依存性注入

uber-go/fx を使用。QueuePort コンシューマと HTTP ハンドラを分離可能に設計。

```go
fx.Provide(
    // Domain
    NewAuditEntryFactory,
    NewRetentionPolicyFactory,
    
    // Repositories
    NewMySQLAuditRepository,
    NewMySQLRetentionRepository,
    NewMySQLGDPRRepository,
    NewMySQLArchivalRepository,
    
    // External Services (Feature Flag で Beta / 本番切替)
    NewRedisBullMQAdapter,        // → QueuePort (Beta, Node) / NewAsynqAdapter (Beta, Go)
    NewOCIQueueAdapter,           // → QueuePort (本番)
    NewQueueEventPublisher,       // → EventPublisherPort (QueuePort 委譲)
    NewGarageArchivalAdapter,     // → ObjectStorageExportPort (Beta)
    NewOCIArchivalAdapter,        // → ObjectStorageExportPort (本番)
    NewSHA256Anonymizer,
    NewRedisQueryCache,
    
    // UseCases
    NewRecordAuditEntryUseCase,
    NewQueryAuditLogsUseCase,
    NewExportAuditLogsUseCase,
    NewArchiveOldLogsUseCase,
    NewAnonymizeGDPRDataUseCase,
    NewScheduleArchivalJobUseCase,
    
    // Handlers
    NewQueueAuditConsumer,
    NewQueryAuditLogsHandler,
    NewExportAuditLogsHandler,
    NewGDPRAnonymizeHandler,
    NewArchivalJobScheduler,
    NewArchivalJobWorker,
),

fx.Invoke(
    RegisterHTTPRoutes,    // chi ルーターの登録
    StartQueueConsumer,    // QueuePort 購読開始
    StartArchivalScheduler, // Cron スケジューラ開始
)
```

## 6. ディレクトリ構成

### ディレクトリツリー

```
recuerdo-audit-svc/
├── cmd/
│   ├── server/main.go              # HTTP サーバー起動
│   └── archival-worker/main.go     # アーカイブワーカー（独立実行可能）
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── audit_entry.go
│   │   │   ├── retention_policy.go
│   │   │   ├── gdpr_anonymization.go
│   │   │   └── archival_job.go
│   │   ├── valueobject/
│   │   │   ├── audit_action.go
│   │   │   ├── resource_type.go
│   │   │   ├── actor_type.go
│   │   │   ├── audit_result.go
│   │   │   ├── pii.go
│   │   │   └── query_filter.go
│   │   ├── event/domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── record_audit_entry.go    # QueuePort メッセージ → DB 保存
│   │   ├── query_audit_logs.go      # 管理画面検索
│   │   ├── export_audit_logs.go     # GDPR / コンプライアンスレポート
│   │   ├── archive_old_logs.go      # MySQL/MariaDB → オブジェクトストレージ（Garage/OCI）移行
│   │   ├── anonymize_gdpr_data.go   # GDPR 削除対応
│   │   ├── get_retention_policies.go
│   │   ├── create_retention_policy.go
│   │   ├── schedule_archival_job.go
│   │   ├── get_anonymization_status.go
│   │   └── port/
│   │       ├── repository.go        # AuditEntryRepository等のインターフェース
│   │       └── service.go           # QueuePort・ObjectStorageExportPort 等のインターフェース
│   ├── adapter/
│   │   ├── http/
│   │   │   ├── query_handler.go     # POST /admin/audit/query
│   │   │   ├── export_handler.go    # POST /admin/audit/export
│   │   │   ├── gdpr_handler.go      # POST /gdpr/anonymize
│   │   │   ├── health_handler.go
│   │   │   └── routes.go            # chi ルーター登録
│   │   ├── queue/
│   │   │   └── queue_consumer.go    # QueuePort subscribe + メッセージハンドラ
│   │   └── scheduler/
│   │       ├── archival_scheduler.go # Cron ジョブスケジューラ
│   │       └── archival_worker.go    # ArchiveOldLogsUseCase 実行
│   └── infrastructure/
│       ├── MySQL/
│       │   ├── audit_repository.go
│       │   ├── retention_repository.go
│       │   ├── gdpr_repository.go
│       │   ├── archival_repository.go
│       │   └── migrations/
│       │       ├── 001_audit_entries.sql
│       │       ├── 002_retention_policies.sql
│       │       ├── 003_gdpr_anonymizations.sql
│       │       └── 004_archival_jobs.sql
│       ├── redis/
│       │   └── query_cache.go
│       ├── queue/
│       │   ├── redis_bullmq_adapter.go # Beta
│       │   ├── asynq_adapter.go        # Beta (Go)
│       │   ├── oci_queue_adapter.go    # 本番
│       │   └── publisher.go
│       ├── objectstorage/
│       │   ├── garage_adapter.go       # Beta: Garage（S3 互換）
│       │   └── oci_adapter.go          # 本番: OCI Object Storage
│       ├── gdpr/
│       │   └── anonymizer.go        # SHA256ハッシュ化
│       └── logging/
│           └── structured_logger.go
├── config/
│   ├── config.go                    # 環境変数読込
│   └── defaults.yaml
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── cronjob.yaml                 # アーカイブ用 Cron Job
├── migrations/                      # migrate CLI 用
│   └── *.sql
├── test/
│   ├── unit/
│   │   ├── entity_test.go
│   │   ├── usecase_test.go
│   │   └── valueobject_test.go
│   ├── integration/
│   │   ├── MySQL_test.go         # testcontainers-go
│   │   ├── redis_test.go
│   │   └── queue_test.go            # Redis+BullMQ（testcontainers）/ OCI Queue（sandbox）
│   └── fixtures/
│       └── sample_events.json
└── go.mod / go.sum
```

## 7. テスト戦略

### レイヤー別テストピラミッド

| レイヤー                     | テスト種別       | モック戦略                                                                                   |
| ---------------------------- | ---------------- | -------------------------------------------------------------------------------------------- |
| Domain (entity/valueobject)  | Unit test        | 外部依存なし。AuditEntry.Validate()・RetentionPolicy.CanArchive()等                          |
| UseCase                      | Unit test        | mockeryで全ポート（AuditEntryRepository/QueuePort 等）をモック                               |
| Adapter (HTTP Handlers)      | Integration test | httptest.Server + モック Repository・UseCase。403/404/500等のエラー応答テスト                |
| Adapter (QueuePort Consumer) | Integration test | Redis + BullMQ コンテナ（testcontainers）+ テスト用メッセージ送信。メッセージ処理の idempotency テスト。本番向けは OCI Queue sandbox を別途実行 |
| Adapter (Archival Scheduler) | Integration test | clock モック（時刻操作）+ MySQL テスト                                                       |
| Infrastructure (MySQL)       | Integration test | testcontainers-go で PG コンテナ起動。月次パーティションの切り替え、アーカイブクエリのテスト |
| Infrastructure (Redis)       | Integration test | testcontainers-go で Redis コンテナ起動。キャッシュの TTL・削除テスト                        |
| Infrastructure (ObjectStorage) | Integration test | Garage コンテナ（testcontainers）でエクスポート・アーカイブの検証。本番向けは OCI Object Storage sandbox で再検証 |
| E2E                          | E2E test         | イベント受信 → ログ記録 → キャッシュ invalidate → クエリ実行の完全フロー                     |
| GDPR compliance test         | 特別テスト       | ユーザー匿名化後、個人情報がハッシュに置き換わっているか確認。復号不可性の検証               |

### テストコード例

```go
// Entity Test
func TestAuditEntry_Validate_MissingActorID(t *testing.T) {
    entry := &AuditEntry{
        EntryID:    "test-id-123",
        ActorID:    "", // 空
        Action:     "READ",
        CreatedAt:  time.Now(),
    }
    err := entry.Validate()
    assert.ErrorIs(t, err, ErrMissingActorID)
}

func TestAuditEntry_CanBeArchived(t *testing.T) {
    createdAt := time.Now().AddDate(0, -3, 0) // 3ヶ月前
    entry := &AuditEntry{
        EntryID:    "test-id",
        CreatedAt:  createdAt,
        ArchivedAt: nil,
    }
    assert.True(t, entry.CanBeArchived(time.Now(), 60)) // 60日保管ポリシー
}

func TestRetentionPolicy_Validate_ArchiveDaysExceeded(t *testing.T) {
    policy := &RetentionPolicy{
        RetentionDays:    100,
        ArchiveAfterDays: 150, // 異常値
    }
    err := policy.Validate()
    assert.ErrorIs(t, err, ErrArchiveDaysExceedsRetention)
}

// UseCase Test
func TestRecordAuditEntry_Success(t *testing.T) {
    mockRepo := new(MockAuditRepository)
    mockRepo.On("Save", mock.Anything, mock.MatchedBy(func(e *AuditEntry) bool {
        return e.ActorID == "user-123" && e.Action == "WRITE"
    })).Return(nil)

    mockPublisher := new(MockEventPublisher)
    mockPublisher.On("Publish", mock.Anything, mock.MatchedBy(func(e DomainEvent) bool {
        return e.EventType() == "AuditEntryRecorded"
    })).Return(nil)

    uc := NewRecordAuditEntryUseCase(mockRepo, mockPublisher)
    input := RecordAuditEntryInput{
        ActorID:      "user-123",
        Action:       "WRITE",
        ResourceType: "MEDIA",
        ResourceID:   "media-456",
        Result:       "SUCCESS",
    }
    
    output, err := uc.Execute(context.Background(), input)
    
    assert.NoError(t, err)
    assert.NotEmpty(t, output.EntryID)
    mockRepo.AssertCalled(t, "Save", mock.Anything, mock.Anything)
    mockPublisher.AssertCalled(t, "Publish", mock.Anything, mock.Anything)
}

func TestQueryAuditLogs_WithFilters(t *testing.T) {
    mockRepo := new(MockAuditRepository)
    expectedEntries := []*AuditEntry{
        {EntryID: "id-1", ActorID: "user-123", Action: "READ"},
        {EntryID: "id-2", ActorID: "user-123", Action: "WRITE"},
    }
    mockRepo.On("FindByQuery", mock.Anything, mock.MatchedBy(func(f *QueryFilter) bool {
        return f.ActorID == "user-123"
    }), 10, 0).Return(expectedEntries, 2, nil)

    mockCache := new(MockQueryCache)
    mockCache.On("Get", mock.Anything, mock.Anything).Return(nil, errors.New("cache miss"))
    mockCache.On("Set", mock.Anything, mock.Anything, mock.Anything, 5*time.Minute).Return(nil)

    uc := NewQueryAuditLogsUseCase(mockRepo, mockCache)
    input := QueryAuditLogsInput{
        ActorID: "user-123",
        Limit:   10,
        Offset:  0,
    }

    output, err := uc.Execute(context.Background(), input)

    assert.NoError(t, err)
    assert.Len(t, output.Entries, 2)
    assert.Equal(t, 2, output.TotalCount)
}

// Adapter Test (HTTP)
func TestQueryAuditLogsHandler_UnauthorizedAccess(t *testing.T) {
    handler := NewQueryAuditLogsHandler(nil) // usecase mock
    
    req := httptest.NewRequest("POST", "/admin/audit/query", nil)
    req.Header.Set("Authorization", "") // ヘッダー無し
    w := httptest.NewRecorder()
    
    handler.ServeHTTP(w, req)
    
    assert.Equal(t, http.StatusUnauthorized, w.Code)
}

// Integration Test (MySQL + testcontainers)
func TestArchiveOldLogs_MigratesRecordToS3(t *testing.T) {
    if testing.Short() {
        t.Skip("Skipping integration test")
    }

    ctx := context.Background()
    pgContainer, db := setupMySQL(ctx, t) // testcontainers-go
    defer pgContainer.Terminate(ctx)

    // 古いログ挿入（2年以上前）
    oldEntry := &AuditEntry{
        EntryID:   uuid.New().String(),
        ActorID:   "user-old",
        Action:    "READ",
        CreatedAt: time.Now().AddDate(-2, -1, 0),
    }
    
    repo := NewMySQLAuditRepository(db)
    err := repo.Save(ctx, oldEntry)
    assert.NoError(t, err)

    // アーカイブジョブ実行
    archiveAdapter := &MockObjectStorageExportAdapter{}  // Beta: Garage / 本番: OCI Object Storage
    archiveAdapter.On("ArchiveRecords", mock.Anything, mock.Anything, mock.Anything, mock.Anything).
        Return("object-storage://recuerdo-audit-exports/2026-04/archived.parquet", nil)

    job := &ArchivalJob{
        JobID:       uuid.New().String(),
        Status:      "PENDING",
        ScheduledAt: time.Now(),
    }
    
    uc := NewArchiveOldLogsUseCase(repo, archiveAdapter, 730) // 2年
    output, err := uc.Execute(ctx, ArchiveOldLogsInput{BatchSize: 1000})

    assert.NoError(t, err)
    assert.Greater(t, output.ArchivedCount, 0)
    archiveAdapter.AssertCalled(t, "ArchiveRecords", mock.Anything, mock.Anything, mock.Anything, mock.Anything)
}

// GDPR Compliance Test
func TestGDPRAnonymization_ReplacesPersonalInfo(t *testing.T) {
    ctx := context.Background()
    pgContainer, db := setupMySQL(ctx, t)
    defer pgContainer.Terminate(ctx)

    // ユーザーのログを複数挿入（メール・名前含む）
    entry := &AuditEntry{
        EntryID:    uuid.New().String(),
        ActorID:    "user-to-delete",
        Metadata:   map[string]interface{}{"email": "john@example.com", "name": "John Doe"},
        CreatedAt:  time.Now(),
    }
    repo := NewMySQLAuditRepository(db)
    repo.Save(ctx, entry)

    // GDPR匿名化実行
    anonymizer := NewSHA256Anonymizer()
    uc := NewAnonymizeGDPRDataUseCase(repo, anonymizer)
    output, err := uc.Execute(ctx, AnonymizeGDPRDataInput{
        UserID: "user-to-delete",
        Reason: "FORGETTING_RIGHT",
    })

    assert.NoError(t, err)
    assert.Greater(t, output.AnonymizedCount, 0)

    // 匿名化後、メールと名前がハッシュに置き換わっているか確認
    retrievedEntry, _ := repo.FindByID(ctx, entry.EntryID)
    assert.NotEqual(t, "john@example.com", retrievedEntry.Metadata["email"])
    assert.NotEqual(t, "John Doe", retrievedEntry.Metadata["name"])
    // ハッシュ値は 64 文字（SHA256）
    assert.Equal(t, 64, len(retrievedEntry.Metadata["email"].(string)))
}
```

## 8. エラーハンドリング

### ドメインエラー

- ErrMissingEntryID: AuditEntry.EntryID が空
- ErrMissingActorID: AuditEntry.ActorID が空またはnull（全操作は操作者IDを必須とする）
- ErrInvalidAuditAction: Action が enum 定義外（READ/WRITE等のいずれでもない）
- ErrInvalidResourceType: ResourceType が enum 定義外
- ErrInvalidActorType: ActorType が enum 定義外
- ErrMissingCreatedAt: CreatedAt がゼロ値
- ErrInvalidRetentionDays: RetentionDays が0以下
- ErrArchiveDaysExceedsRetention: ArchiveAfterDays > RetentionDays（アーカイブ期間が保管期間を超える）
- ErrJobNotPending: ArchivalJob.MarkAsRunning() が PENDING 状態でないジョブに呼ばれた
- ErrJobNotRunning: ArchivalJob.MarkAsCompleted() が RUNNING 状態でないジョブに呼ばれた
- ErrDuplicateEntryID: QueuePort の再配送で同じ entry_id が既に DB に存在
- ErrQueryCacheInvalidate: Redis キャッシュ削除が失敗
- ErrObjectStorageUploadFailed: オブジェクトストレージ（Garage / OCI Object Storage）へのエクスポート・アーカイブがエラー
- ErrGDPRAnonymizationNotFound: 指定された GDPRAnonymization が存在しない

### エラー → HTTPステータスマッピング

| ドメインエラー               | HTTPステータス            | ユーザーメッセージ                                                                                |
| ---------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------- |
| ErrMissingActorID            | 400 Bad Request           | Invalid audit entry: actor_id is required                                                         |
| ErrInvalidAuditAction        | 400 Bad Request           | Invalid audit action. Allowed: READ, WRITE, DELETE, LOGIN, LOGOUT, PERMISSION_CHECK, ADMIN_ACTION |
| ErrInvalidResourceType       | 400 Bad Request           | Invalid resource type. Allowed: USER, ORG, MEDIA, ALBUM, EVENT, MESSAGE, ROLE, INTEGRATION        |
| ErrDuplicateEntryID          | 409 Conflict              | Audit entry with this ID already exists (idempotency check)                                       |
| ErrQueryCacheInvalidate      | 500 Internal Server Error | Failed to refresh audit log cache. Please try again.                                              |
| ErrObjectStorageUploadFailed | 503 Service Unavailable   | Failed to export audit logs to object storage. Please try again later.                            |
| ErrGDPRAnonymizationNotFound | 404 Not Found             | GDPR anonymization request not found                                                              |
| ErrInvalidRetentionDays      | 400 Bad Request           | Retention days must be greater than 0                                                             |

## 9. 未決事項

### 質問・決定事項

| #   | 質問                                                                                                                             | ステータス | 決定                                                                                                                                               |
| --- | -------------------------------------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | 月次パーティション分割時、新しいパーティションは自動作成するか                                                                   | Resolved   | Beta / 本番とも MariaDB/MySQL の ALTER TABLE ... REORGANIZE を毎月初に実行する Cron Job を ArchivalJobScheduler と同梱。ドリフト発生時は Loki + Grafana でアラート |
| 2   | GDPR 削除時のハッシュ salt 値は何か                                                                                              | Resolved   | `user_id` を salt として SHA256 ハッシュ（決定論的）。salt は MySQL/MariaDB 側に保存せず、入力値のみで再現可能に                                 |
| 3   | 監査ログ検索 API はロール制御をどうするか                                                                                        | Resolved   | SUPERUSER / Org Admin / 本人のみ。一般ユーザーの GDPR DSAR は後続フェーズで拡張                                                                  |
| 4   | アーカイブ形式は何か                                                                                                             | Resolved   | JSON Lines (NDJSON) + gzip 圧縮を採用（Garage / OCI Object Storage 互換、DuckDB などで後続クエリ可能）。Parquet は将来のオプション               |
| 5   | RetentionPolicy の更新時、既存ログは遡及適用されるか                                                                             | Resolved   | 記録時のポリシーを保持（retroactive 適用なし）                                                                                                   |
| 6   | QueuePort メッセージの visibility timeout と再処理の上限                                                                         | Resolved   | Visibility timeout 300秒。最大 3 回再処理後、DLQ（Redis list / OCI Queue DLQ）へ。DLQ は Loki + Grafana で監視                                   |
| 7   | 複数 Archival Worker の排他制御                                                                                                  | Resolved   | MySQL `GET_LOCK()` / MariaDB 同等関数を使用した advisory lock。Kubernetes/Docker Job 側では `parallelism=1` で二重起動を防止                     |
| 8   | GDPRAnonymization が FAILED 時の再実行フロー                                                                                     | Resolved   | 管理者 UI から手動再試行。併せて Loki + Grafana でアラート。非同期自動リトライは将来実装                                                         |
| 9   | Redis query cache の invalidation 戦略                                                                                           | Resolved   | `audit_query:{actor_id}:{resource_type}:{action_hash}` のキー単位で削除                                                                         |
| 10  | エクスポートファイルの有効期限・Presigned URL TTL                                                                                | Resolved   | Presigned URL の TTL: 24 時間。Garage / OCI Object Storage のライフサイクルルールで 30 日後に自動削除                                             |

---

最終更新: 2026-04-19 ポリシー適用

