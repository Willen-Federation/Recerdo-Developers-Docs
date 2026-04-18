# Feature Flag 管理システム (recuerdo-feature-flag-svc)

**作成者**: Claude (AI) · **作成日**: 2026-04-19 · **ステータス**: 承認済み (Approved)

> Notion レビューコメント: 「この内容で設計を実施したいと思います。」(2026-04-18)

---

## 1. 概要

### 目的

Recerdo プラットフォーム全体の機能フラグ（Feature Flag）を一元管理するシステム。新機能のリリース制御、段階的ロールアウト、障害時の緊急停止（Kill Switch）、IP/Firewallベースのアクセス制御を提供する。OpenFeature SDK（CNCF標準）と Flipt（OSS、軽量）を組み合わせたゼロコスト構成を採用する。

### ビジネスコンテキスト

解決する問題:
- 新機能のリリース時に全ユーザーへの一括公開リスクを回避できない
- エラー率が上昇した機能を即座に停止する手段がない
- 特定ユーザーグループや地域向けの段階的公開ができない
- Feature Flagの設定がコードやデプロイに依存しており、実行時変更ができない

Key User Stories:
- 開発者として、新機能を全ユーザーに公開する前に、社内チームまたは5%のユーザーに試験公開したい
- 運用担当として、特定機能のエラー率が閾値を超えたとき、コードデプロイなしで即座に機能を無効化したい
- 管理者として、特定のIPアドレス範囲からのみアクセスを許可するフラグを設定したい
- 機能オーナーとして、フラグの現在の状態（ON/OFF、適用ユーザー数）をダッシュボードで確認したい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ | 説明 | 主要属性 |
| --- | --- | --- |
| FeatureFlag | フラグ定義 | flag_key (string, unique), name, description, enabled (bool), flag_type (BOOLEAN/VARIANT), created_at, updated_at |
| FlagRule | フラグ適用ルール | rule_id (UUID), flag_key, rule_type (PERCENTAGE/SEGMENT/IP_RANGE/ALWAYS), rule_config (JSON), priority (int) |
| FlagEvaluation | フラグ評価ログ | eval_id (UUID), flag_key, entity_id (user_id), result (bool/variant), rule_matched, evaluated_at |
| FlagSegment | ユーザーセグメント | segment_key, description, conditions (user_id_list / org_id_list / custom JSON) |
| FlagAuditLog | 設定変更履歴 | log_id (UUID), flag_key, changed_by, old_value, new_value, changed_at |

### 値オブジェクト

| 値オブジェクト | 説明 | バリデーション |
| --- | --- | --- |
| FlagKey | フラグ識別子 | snake_case、最大128文字、プレフィックス形式（`feature.album.v2` 等） |
| RolloutPercentage | ロールアウト割合 | 0〜100の整数 |
| IPRange | IP制限範囲 | CIDR表記（例: `192.168.1.0/24`）、IPv4/IPv6 |
| ErrorRateThreshold | 自動停止エラー率閾値 | 0.0〜1.0（例: 0.05 = 5%） |
| EvaluationContext | フラグ評価コンテキスト | entity_id (user_id), org_id, ip_address, custom_attributes (map) |

### ドメインルール / 不変条件

- `enabled = false` のフラグは、どのルールが定義されていても評価結果は常に `false`（Off）を返す
- Percentage Rollout は同一 `entity_id` に対して決定論的でなければならない（同じユーザーには常に同じ結果）
- Kill Switch が発動した場合（エラー率閾値超過）、フラグは自動的に `enabled = false` に遷移し、FlagAuditLog に記録する
- FlagRule の `priority` は一意であり、低い値が優先評価される
- IP制限フラグが定義されている場合、EvaluationContext に ip_address がなければ評価を拒否する

### ドメインイベント

| イベント | トリガー | 主要ペイロード |
| --- | --- | --- |
| FlagEnabled | フラグが ON に変更された | flag_key, changed_by, changed_at |
| FlagDisabled | フラグが OFF に変更された（Kill Switchを含む） | flag_key, reason (MANUAL/AUTO_KILLSWITCH), changed_by, changed_at |
| FlagRuleUpdated | ルール（Rollout、Segment等）が変更された | flag_key, rule_id, old_config, new_config |
| KillSwitchTriggered | エラー率閾値超過で自動停止 | flag_key, error_rate, threshold, triggered_at |
| EvaluationAnomaly | 予期しない評価エラーが多発 | flag_key, error_count, window_seconds |

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース | 入力 | 出力 | 説明 |
| --- | --- | --- | --- |
| EvaluateFlag | EvaluateFlagInput{flag_key, entity_id, context} | EvaluateFlagOutput{enabled, variant, reason} | フラグを評価（マイクロサービスが毎リクエスト呼び出し） |
| CreateFlag | CreateFlagInput{flag_key, name, description, enabled} | CreateFlagOutput{flag_key} | フラグ新規作成 |
| UpdateFlagStatus | UpdateFlagStatusInput{flag_key, enabled} | UpdateFlagStatusOutput{updated_at} | フラグON/OFF切り替え |
| SetRolloutRule | SetRolloutRuleInput{flag_key, percentage} | SetRolloutRuleOutput{rule_id} | Percentage Rollout設定 |
| SetIPRestriction | SetIPRestrictionInput{flag_key, cidr_ranges[]} | SetIPRestrictionOutput{rule_id} | IP制限設定 |
| TriggerKillSwitch | TriggerKillSwitchInput{flag_key, reason} | TriggerKillSwitchOutput{disabled_at} | Kill Switch発動（手動または自動） |
| GetFlagStatus | GetFlagStatusInput{flag_key} | GetFlagStatusOutput{enabled, rules[], eval_stats} | フラグ状態取得 |
| ListFlags | ListFlagsInput{filter} | ListFlagsOutput{flags[]} | フラグ一覧取得 |

### ユースケース詳細（EvaluateFlag）

**トリガー**: 各マイクロサービスが機能実行前に呼び出し（OpenFeature SDK 経由）

**フロー**:
1. EvaluationContext（entity_id、org_id、ip_address 等）を受け取る
2. フラグ定義をキャッシュ（Redis / Flipt in-memory）から取得
3. `enabled = false` なら即座に `{enabled: false, reason: FLAG_DISABLED}` を返す
4. FlagRule を priority 順に評価:
   - IP_RANGE: EvaluationContext.ip_address が許可範囲か確認
   - SEGMENT: entity_id が FlagSegment の条件を満たすか確認
   - PERCENTAGE: hash(entity_id + flag_key) % 100 < percentage か確認
   - ALWAYS: 無条件で適用
5. 最初にマッチしたルールの結果を返す
6. マッチなし → フラグデフォルト値（enabled の現在値）を返す
7. 評価ログを非同期で記録（FlagEvaluation）

**エラーハンドリング**:
- Flipt 接続エラー時: フェイルオープン（`enabled: true`）またはフェイルクローズ（`enabled: false`）をフラグごとに設定可能
- デフォルトはフェイルクローズ（安全側）

### ユースケース詳細（TriggerKillSwitch）

**トリガー**: 
- 手動: 管理者が API または Flipt UI から実行
- 自動: CloudWatch アラームが ErrorRate 閾値超過を検知し、Lambda 経由で API 呼び出し

**フロー**:
1. flag_key と reason（MANUAL/AUTO_KILLSWITCH）を受け取る
2. FeatureFlag.enabled を false に更新
3. FlagAuditLog に変更履歴を記録
4. KillSwitchTriggered ドメインイベントを発行
5. Notification Service に通知（管理者への PUSH 通知）
6. Redis キャッシュを即座に無効化（次回評価からフラグOFF が反映される）

## 4. インフラ層

### 外部サービス連携

#### Flipt（CNCF OSS）

- **用途**: Feature Flag サーバー（評価エンジン・管理UI）
- **コスト**: $0（OSS、自前運用）
- **デプロイ**: Docker コンテナ、ECS Fargate または EC2
- **Go SDK**: `go.flipt.io/flipt/sdk/go`
- **特徴**:
  - gRPC + REST API
  - Percentage Rollout、Segment、Boolean フラグをネイティブサポート
  - 管理 UI（Web ダッシュボード）内包
  - 評価結果のメトリクス出力（Prometheus）

#### OpenFeature SDK（CNCF標準）

- **用途**: マイクロサービスがフラグを評価する際のクライアントインターフェース
- **コスト**: $0（OSS）
- **Go SDK**: `github.com/open-feature/go-sdk`
- **特徴**:
  - ベンダーニュートラルな標準インターフェース
  - Flipt を Provider として設定（将来的に他ツールに切り替え可能）
  - フック（Hook）機能でメトリクス収集・ログ出力を標準化

```go
// OpenFeature SDK セットアップ例
import (
    "github.com/open-feature/go-sdk/openfeature"
    flipt "github.com/open-feature/go-sdk-contrib/providers/flipt/pkg/provider"
)

func InitFeatureFlags() {
    provider := flipt.NewProvider(
        flipt.WithAddress("http://flipt-svc:8080"),
    )
    openfeature.SetProvider(provider)
}

// 機能フラグ評価
func IsAlbumV2Enabled(ctx context.Context, userID string) bool {
    client := openfeature.NewClient("album-svc")
    enabled, err := client.BooleanValue(ctx, "feature.album.v2", false,
        openfeature.NewEvaluationContext(userID, map[string]interface{}{
            "org_id": orgID,
        }),
    )
    if err != nil {
        return false // フェイルクローズ
    }
    return enabled
}
```

#### PostgreSQL

- **用途**: FeatureFlag、FlagRule、FlagSegment、FlagAuditLog の永続化
- **テーブル**:
  - `feature_flags` (flag_key, name, description, enabled, fail_mode, created_at, updated_at)
  - `flag_rules` (rule_id, flag_key, rule_type, rule_config JSONB, priority)
  - `flag_segments` (segment_key, description, conditions JSONB)
  - `flag_audit_logs` (log_id, flag_key, changed_by, old_value, new_value, changed_at)

#### Redis

- **用途**: フラグ評価結果キャッシュ（低レイテンシ応答）
- **キー設計**:
  - `ff:flag:{flag_key}` → フラグ定義 JSON（TTL: 60秒）
  - `ff:eval:{flag_key}:{entity_id}` → 評価結果キャッシュ（TTL: 30秒）
- **Kill Switch 即時反映**: `DEL ff:flag:{flag_key}` でキャッシュを即時削除

### インターフェース層 — REST API Endpoints

| エンドポイント | メソッド | 説明 | 認証 |
| --- | --- | --- | --- |
| POST /api/flags | POST | フラグ作成 | Admin JWT |
| GET /api/flags | GET | フラグ一覧取得 | Admin JWT |
| GET /api/flags/{flag_key} | GET | フラグ詳細取得 | Admin JWT |
| PUT /api/flags/{flag_key}/status | PUT | ON/OFF切り替え | Admin JWT |
| POST /api/flags/{flag_key}/kill-switch | POST | Kill Switch発動 | Admin JWT |
| PUT /api/flags/{flag_key}/rules/rollout | PUT | Percentage Rollout設定 | Admin JWT |
| PUT /api/flags/{flag_key}/rules/ip | PUT | IP制限設定 | Admin JWT |
| POST /api/flags/evaluate | POST | フラグ評価（内部API） | Service JWT |
| GET /api/flags/{flag_key}/audit | GET | 変更履歴取得 | Admin JWT |

## 5. 機能要件詳細

### 5.1 ON/OFF 切り替え

- Flipt UI または API から即時切り替え可能
- 変更は Redis キャッシュ無効化と同時に全インスタンスへ波及（60秒以内）
- 変更は FlagAuditLog に記録（誰が・いつ・何を変更したか）

### 5.2 エラーハンドリング（自動エラー率監視）

```
CloudWatch Metrics (ErrorRate per flag_key)
  ↓ 閾値超過（例: 5%超）
  ↓ CloudWatch Alarm → SNS → Lambda
  ↓ Lambda: POST /api/flags/{flag_key}/kill-switch {reason: AUTO_KILLSWITCH}
  ↓ FeatureFlag.enabled = false
  ↓ KillSwitchTriggered イベント発行 → Notification Service → 管理者通知
```

### 5.3 Kill Switch（自動/手動）

- **手動**: 管理者が API または Flipt ダッシュボードから即時実行
- **自動**: CloudWatch + Lambda 連携で閾値超過を検知して自動発動
- 発動後、フラグは手動で明示的に再有効化するまで OFF を維持（自動復旧しない）

### 5.4 IP制限（Firewall）

- CIDR 表記で許可 IP 範囲を指定
- 複数 CIDR の AND または OR 条件をサポート
- マッチしない IP からの評価リクエストは `enabled: false` を返す（403 ではなくフラグOFF として扱う）
- 利用ケース: 社内ネットワークからのみベータ機能を有効化

### 5.5 Percentage Rollout（段階的公開）

- 0〜100%の範囲でユーザーを均等にグループ分け
- 同一 user_id は常に同じグループに属する（決定論的ハッシュ）
- アルゴリズム: `hash(user_id + flag_key) % 100 < rollout_percentage`
- 段階的に 5% → 20% → 50% → 100% と拡大可能

## 6. コスト分析

| ソリューション | 年間コスト | Go SDK | CNCF準拠 | 自前運用 |
| --- | --- | --- | --- | --- |
| **OpenFeature + Flipt（採用）** | **$0** | ✅ | ✅ | 必要（Docker）|
| Unleash OSS | $0 | ✅ | ❌ | 必要 |
| Flagsmith OSS | $0 | ✅ | ❌ | 必要 |
| LaunchDarkly | $10,000+/年 | ✅ | ✅ | 不要 |
| Split.io | $7,000+/年 | ✅ | ❌ | 不要 |

Flipt は他 OSS と比較して軽量（単一バイナリ）でありながら、CNCF 標準の OpenFeature と組み合わせることで将来のツール移行コストを最小化できる。

## 7. デプロイ・インフラ

- **Flipt サーバー**: Docker コンテナ、ECS Fargate（最小: 256MB / 0.25vCPU）
- **永続化**: PostgreSQL（Flipt のバックエンドとして設定）
- **スケーリング**: Flipt は水平スケール対応（評価エンジンはステートレス）
- **モニタリング**: Prometheus メトリクス（Flipt 内蔵）→ CloudWatch

## 8. セキュリティ考慮事項

- Flipt 管理 UI へのアクセスは VPC 内に限定（パブリック公開しない）
- API 経由の操作は Admin JWT（Permission Service発行）で認証
- マイクロサービスからの評価リクエストは Service JWT で認証
- フラグ変更は全て FlagAuditLog に記録（変更者・日時・内容）
