# クリーンアーキテクチャ設計書 — Feature Flag 管理システム

| 項目                      | 値                                              |
| ------------------------- | ----------------------------------------------- |
| **モジュール/サービス名** | Feature Flag System (recuerdo-feature-flag-svc) |
| **作成者**                | Claude (AI)                                     |
| **作成日**                | 2026-04-19                                      |
| **ステータス**            | 承認済み (Approved)                             |
| **バージョン**            | 1.0                                             |

> Notion レビューコメント: 「この内容で設計を実施したいと思います。」(2026-04-18)

---

## 1. 概要

### 1.1 目的

Feature Flag System は Recerdo プラットフォーム全体の機能フラグを一元管理する。OpenFeature SDK（CNCF標準）と Flipt（OSS）を組み合わせ、ON/OFF 制御・Percentage Rollout・IP制限・Kill Switch・エラー率閾値による自動停止を提供する。Permission Service の横断機能拡張として位置づけ、全マイクロサービスが OpenFeature SDK 経由でフラグを評価できる基盤を提供する。

### 1.2 ビジネスコンテキスト

新機能の段階的リリース・障害時の緊急停止・テスト環境での特定ユーザー限定公開を実現するために必要。LaunchDarkly等のSaaSと比較してゼロコスト（OSS）で実現し、CNCF標準準拠により将来の技術移行コストを最小化する。

### 1.3 アーキテクチャ原則

- **単一責任の原則**: フラグの評価・管理に専念する独立サービス
- **依存性の逆転**: リポジトリ・Flipt クライアントはインターフェース（ポート）経由
- **層間の厳密な分離**: Entity → UseCase → Adapter → Framework の一方向依存
- **フェイルセーフ**: Flipt 接続失敗時はフェイルクローズ（false 返却）を基本とし、フラグごとに設定可能
- **キャッシュ優先**: Redis キャッシュで評価レイテンシを最小化（< 1ms）

---

## 2. レイヤーアーキテクチャ

### 2.1 アーキテクチャ図

```
┌────────────────────────────────────────────────────────────┐
│  Frameworks & Drivers                                       │
│  Gin HTTP, MySQL, Redis, Flipt gRPC/REST, CloudWatch  │
└────────────────────────────────────────────────────────────┘
                          ▲
                          │ (依存)
┌────────────────────────────────────────────────────────────┐
│  Interface Adapters                                         │
│  HTTP Controllers (Admin API), FliptAdapter,               │
│  MySQLRepository, RedisCache, CloudWatchAlarmConsumer   │
└────────────────────────────────────────────────────────────┘
                          ▲
                          │ (依存)
┌────────────────────────────────────────────────────────────┐
│  Application Business Rules                                 │
│  EvaluateFlagUseCase, CreateFlagUseCase,                   │
│  TriggerKillSwitchUseCase, SetRolloutRuleUseCase           │
└────────────────────────────────────────────────────────────┘
                          ▲
                          │ (依存)
┌────────────────────────────────────────────────────────────┐
│  Enterprise Business Rules（ドメイン）                      │
│  FeatureFlag, FlagRule, FlagSegment, FlagAuditLog,         │
│  EvaluationContext, RolloutPercentage, IPRange              │
└────────────────────────────────────────────────────────────┘
```

### 2.2 依存性ルール

外側のレイヤーは内側に依存し、内側は外側に依存しない。Flipt への依存は FliptAdapter（Interface Adapters 層）に閉じ込め、ドメイン・ユースケース層は Flipt を直接知らない。

---

## 3. エンティティ層（ドメイン）

### 3.1 ドメインモデル

| エンティティ名 | 説明               | 主要フィールド                                                                                           |
| -------------- | ------------------ | -------------------------------------------------------------------------------------------------------- |
| FeatureFlag    | フラグ定義         | flagKey (string), name, description, enabled (bool), failMode (OPEN/CLOSE), createdAt, updatedAt         |
| FlagRule       | フラグ適用ルール   | ruleId (UUID), flagKey, ruleType (PERCENTAGE/SEGMENT/IP_RANGE/ALWAYS), ruleConfig (JSON), priority (int) |
| FlagSegment    | ユーザーセグメント | segmentKey, description, conditions (JSON)                                                               |
| FlagAuditLog   | 変更履歴           | logId (UUID), flagKey, changedBy, oldValue, newValue, changedAt                                          |
| FlagEvaluation | 評価ログ           | evalId (UUID), flagKey, entityId, result (bool), ruleMatched, evaluatedAt                                |

### 3.2 値オブジェクト

| 値オブジェクト    | 説明                                                        | 不変性 |
| ----------------- | ----------------------------------------------------------- | ------ |
| FlagKey           | フラグ識別子（snake_case, max 128char）                     | Yes    |
| EvaluationContext | 評価コンテキスト（entityId, orgId, ipAddress, attributes）  | Yes    |
| RolloutPercentage | ロールアウト割合（0〜100）                                  | Yes    |
| IPRange           | CIDR表記のIP範囲                                            | Yes    |
| FailMode          | Flipt接続失敗時の振る舞い（OPEN=true返却, CLOSE=false返却） | Yes    |

### 3.3 ドメインルール / 不変条件

- `FeatureFlag.enabled = false` のフラグは全ルールをスキップし常に false を返す
- Percentage Rollout は `hash(entityId + flagKey) % 100` による決定論的評価
- Kill Switch 発動後は手動再有効化まで enabled = false を維持（自動復旧しない）
- FlagRule.priority は同一フラグ内で一意
- IP制限ルールが存在するフラグに ip_address がない EvaluationContext は false を返す

### 3.4 ドメインイベント

| イベント名                 | 発火条件                             | ペイロード                                          |
| -------------------------- | ------------------------------------ | --------------------------------------------------- |
| flag.enabled               | フラグがONに変更                     | flagKey, changedBy, changedAt                       |
| flag.disabled              | フラグがOFFに変更（Kill Switch含む） | flagKey, reason (MANUAL/AUTO_KILLSWITCH), changedAt |
| flag.rule_updated          | ルールが変更                         | flagKey, ruleId, newConfig                          |
| flag.kill_switch_triggered | エラー率閾値超過で自動停止           | flagKey, errorRate, threshold, triggeredAt          |

### 3.5 エンティティ定義

```go
package domain

import "time"

type FeatureFlag struct {
    FlagKey     string
    Name        string
    Description string
    Enabled     bool
    FailMode    FailMode  // OPEN or CLOSE
    CreatedAt   time.Time
    UpdatedAt   time.Time
}

func (f *FeatureFlag) IsEnabled() bool {
    return f.Enabled
}

type FlagRule struct {
    RuleID     string // UUID
    FlagKey    string
    RuleType   RuleType // PERCENTAGE, SEGMENT, IP_RANGE, ALWAYS
    RuleConfig map[string]interface{} // JSON
    Priority   int
}

type EvaluationContext struct {
    EntityID   string
    OrgID      string
    IPAddress  string
    Attributes map[string]interface{}
}

type FailMode string

const (
    FailModeOpen  FailMode = "OPEN"  // 失敗時 true 返却
    FailModeClose FailMode = "CLOSE" // 失敗時 false 返却（デフォルト）
)

type RuleType string

const (
    RuleTypePercentage RuleType = "PERCENTAGE"
    RuleTypeSegment    RuleType = "SEGMENT"
    RuleTypeIPRange    RuleType = "IP_RANGE"
    RuleTypeAlways     RuleType = "ALWAYS"
)
```

---

## 4. ユースケース層（アプリケーション）

### 4.1 ユースケース一覧

| ユースケース      | アクター                  | 説明                             | 優先度 |
| ----------------- | ------------------------- | -------------------------------- | ------ |
| EvaluateFlag      | Microservice              | フラグをコンテキストに基づき評価 | HIGH   |
| CreateFlag        | Admin                     | フラグ新規作成                   | HIGH   |
| UpdateFlagStatus  | Admin                     | ON/OFF切り替え                   | HIGH   |
| TriggerKillSwitch | Admin / CloudWatch Lambda | Kill Switch発動                  | HIGH   |
| SetRolloutRule    | Admin                     | Percentage Rollout設定           | HIGH   |
| SetIPRestriction  | Admin                     | IP制限設定                       | MEDIUM |
| GetFlagStatus     | Admin                     | フラグ詳細・評価統計取得         | MEDIUM |
| ListFlags         | Admin                     | フラグ一覧取得                   | MEDIUM |

### 4.2 ユースケース定義

```go
package usecase

type EvaluateFlagInput struct {
    FlagKey string
    Context EvaluationContext
}

type EvaluateFlagOutput struct {
    Enabled     bool
    Reason      string // FLAG_DISABLED, RULE_MATCHED, DEFAULT, FAIL_OPEN, FAIL_CLOSE
    RuleMatched string // matched rule_id or ""
}

type EvaluateFlagUseCase struct {
    flagRepo    FlagRepository
    ruleRepo    FlagRuleRepository
    cache       Cache
    evalLogger  FlagEvaluationLogger
}

func (uc *EvaluateFlagUseCase) Execute(ctx context.Context, in EvaluateFlagInput) (*EvaluateFlagOutput, error) {
    // 1. キャッシュから取得
    cacheKey := fmt.Sprintf("ff:flag:%s", in.FlagKey)
    flag, err := uc.cache.GetFlag(cacheKey)
    if err != nil {
        flag, err = uc.flagRepo.FindByKey(ctx, in.FlagKey)
        if err != nil {
            // Flipt/DB 接続失敗 → FailMode に従って返却
            return uc.handleFailure(in.FlagKey)
        }
        uc.cache.SetFlag(cacheKey, flag, 60*time.Second)
    }

    // 2. フラグ無効なら即座に false
    if !flag.IsEnabled() {
        return &EvaluateFlagOutput{Enabled: false, Reason: "FLAG_DISABLED"}, nil
    }

    // 3. ルールを priority 順に評価
    rules, _ := uc.ruleRepo.FindByFlagKey(ctx, in.FlagKey)
    for _, rule := range rules {
        if matched, result := uc.evaluateRule(rule, in.Context); matched {
            go uc.evalLogger.Log(in.FlagKey, in.Context.EntityID, result, rule.RuleID)
            return &EvaluateFlagOutput{Enabled: result, Reason: "RULE_MATCHED", RuleMatched: rule.RuleID}, nil
        }
    }

    // 4. マッチなし → フラグデフォルト（enabled の現在値）
    return &EvaluateFlagOutput{Enabled: flag.Enabled, Reason: "DEFAULT"}, nil
}

type TriggerKillSwitchInput struct {
    FlagKey string
    Reason  string // MANUAL or AUTO_KILLSWITCH
    TriggeredBy string
}

type TriggerKillSwitchUseCase struct {
    flagRepo       FlagRepository
    auditRepo      FlagAuditRepository
    cache          Cache
    eventPublisher EventPublisher
    notifier       NotificationGateway
}

func (uc *TriggerKillSwitchUseCase) Execute(ctx context.Context, in TriggerKillSwitchInput) error {
    flag, err := uc.flagRepo.FindByKey(ctx, in.FlagKey)
    if err != nil {
        return err
    }
    flag.Enabled = false
    flag.UpdatedAt = time.Now()

    if err := uc.flagRepo.Update(ctx, flag); err != nil {
        return err
    }

    // キャッシュ即時無効化
    uc.cache.Delete(fmt.Sprintf("ff:flag:%s", in.FlagKey))

    // 監査ログ
    uc.auditRepo.Save(ctx, &FlagAuditLog{
        FlagKey:   in.FlagKey,
        ChangedBy: in.TriggeredBy,
        OldValue:  "enabled=true",
        NewValue:  "enabled=false",
        ChangedAt: time.Now(),
    })

    // イベント発行 → 管理者通知
    uc.eventPublisher.PublishKillSwitchTriggered(in.FlagKey, in.Reason)
    return nil
}
```

---

## 5. ポート・アダプタ設計

### 5.1 ポート定義（インターフェース）

```go
// Outbound Ports

type FlagRepository interface {
    Save(ctx context.Context, flag *FeatureFlag) error
    Update(ctx context.Context, flag *FeatureFlag) error
    FindByKey(ctx context.Context, flagKey string) (*FeatureFlag, error)
    List(ctx context.Context) ([]*FeatureFlag, error)
}

type FlagRuleRepository interface {
    Save(ctx context.Context, rule *FlagRule) error
    Update(ctx context.Context, rule *FlagRule) error
    FindByFlagKey(ctx context.Context, flagKey string) ([]*FlagRule, error)
    Delete(ctx context.Context, ruleID string) error
}

type FlagAuditRepository interface {
    Save(ctx context.Context, log *FlagAuditLog) error
    ListByFlagKey(ctx context.Context, flagKey string) ([]*FlagAuditLog, error)
}

type FlagEvaluationLogger interface {
    Log(flagKey string, entityID string, result bool, ruleMatched string) error
}

type Cache interface {
    GetFlag(key string) (*FeatureFlag, error)
    SetFlag(key string, flag *FeatureFlag, ttl time.Duration) error
    Delete(key string) error
}

type EventPublisher interface {
    PublishFlagEnabled(flagKey string, changedBy string) error
    PublishFlagDisabled(flagKey string, reason string) error
    PublishKillSwitchTriggered(flagKey string, reason string) error
}

type NotificationGateway interface {
    NotifyAdmins(subject string, body string) error
}
```

### 5.2 アダプタ実装

#### FliptEvaluationAdapter

```go
package adapter

import (
    "context"
    flipt "go.flipt.io/flipt/sdk/go"
)

type FliptEvaluationAdapter struct {
    client *flipt.Client
}

func NewFliptEvaluationAdapter(address string) (*FliptEvaluationAdapter, error) {
    client, err := flipt.New(flipt.WithAddress(address))
    if err != nil {
        return nil, err
    }
    return &FliptEvaluationAdapter{client: client}, nil
}

// FliptAdapter はフラグ評価を Flipt に委譲する（OpenFeature SDK Provider として機能）
func (a *FliptEvaluationAdapter) Evaluate(ctx context.Context, flagKey string, entityID string, context map[string]string) (bool, error) {
    resp, err := a.client.EvaluationService().Boolean(ctx, &flipt.BooleanEvaluationRequest{
        FlagKey:  flagKey,
        EntityId: entityID,
        Context:  context,
    })
    if err != nil {
        return false, err
    }
    return resp.Enabled, nil
}
```

#### RedisCache

```go
package adapter

import (
    "context"
    "encoding/json"
    "time"
    "github.com/redis/go-redis/v9"
)

type RedisFlagCache struct {
    client *redis.Client
}

func (c *RedisFlagCache) GetFlag(key string) (*domain.FeatureFlag, error) {
    val, err := c.client.Get(context.Background(), key).Result()
    if err != nil {
        return nil, err
    }
    var flag domain.FeatureFlag
    if err := json.Unmarshal([]byte(val), &flag); err != nil {
        return nil, err
    }
    return &flag, nil
}

func (c *RedisFlagCache) SetFlag(key string, flag *domain.FeatureFlag, ttl time.Duration) error {
    data, _ := json.Marshal(flag)
    return c.client.Set(context.Background(), key, data, ttl).Err()
}

func (c *RedisFlagCache) Delete(key string) error {
    return c.client.Del(context.Background(), key).Err()
}
```

---

## 6. テスト戦略

### 6.1 単体テスト（ユースケース層）

```go
func TestEvaluateFlag_Disabled(t *testing.T) {
    mockRepo := &MockFlagRepository{
        flag: &FeatureFlag{FlagKey: "feature.album.v2", Enabled: false},
    }
    uc := &EvaluateFlagUseCase{flagRepo: mockRepo, cache: &MockCache{}}

    out, err := uc.Execute(context.Background(), EvaluateFlagInput{
        FlagKey: "feature.album.v2",
        Context: EvaluationContext{EntityID: "user123"},
    })

    assert.NoError(t, err)
    assert.False(t, out.Enabled)
    assert.Equal(t, "FLAG_DISABLED", out.Reason)
}

func TestEvaluateFlag_PercentageRollout_Deterministic(t *testing.T) {
    // 同一 user_id は常に同じ結果になることを確認
    uc := buildEvaluateFlagUCWith50Percent()

    out1, _ := uc.Execute(ctx, EvaluateFlagInput{FlagKey: "feature.x", Context: EvaluationContext{EntityID: "userABC"}})
    out2, _ := uc.Execute(ctx, EvaluateFlagInput{FlagKey: "feature.x", Context: EvaluationContext{EntityID: "userABC"}})

    assert.Equal(t, out1.Enabled, out2.Enabled) // 決定論的
}
```

### 6.2 統合テスト

- Flipt 実サーバー（Docker）を使用した評価テスト
- Redis キャッシュを使用したキャッシュヒット/ミステスト
- Kill Switch 発動 → キャッシュ無効化 → 次回評価に反映されることの確認

---

## 7. デプロイ・運用

- **Flipt サーバー**: ECS Fargate（256MB / 0.25vCPU、最小構成）
- **データベース**: MySQL（他マイクロサービスと共有クラスター）
- **キャッシュ**: Redis（既存クラスター利用）
- **モニタリング**: Flipt 内蔵 Prometheus → CloudWatch
- **Kill Switch 自動化**: CloudWatch Alarm → Lambda → `POST /api/flags/{flag_key}/kill-switch`
