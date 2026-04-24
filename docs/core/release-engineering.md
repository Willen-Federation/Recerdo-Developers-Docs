# リリースエンジニアリング自動化

**参照**: `environment-abstraction.md §8.1` · `policy.md §8.9 SLI/SLO` · `workflow.md §10, §12`  
**最終更新**: 2026-04-24

---

## 1. カナリアデプロイ ステップ定義

設定ファイル: `recerdo-infra/deploy/rollout-config.yaml`

| ステップ | トラフィック比率 | 最小滞留時間 | 昇格条件 | 自動ロールバック条件 |
|---|---|---|---|---|
| canary-5 | 5% | 15 分 | 5xx < 0.1% かつ p95 < SLO | 5xx > 0.5% (5 分間) |
| canary-20 | 20% | 30 分 | 5xx < 0.1% かつ p95 < SLO | 5xx > 0.5% (5 分間) |
| canary-50 | 50% | 30 分 | 5xx < 0.1% かつ p95 < SLO | 5xx > 0.5% (5 分間) |
| full | 100% | — | — | 5xx > 1.0% (5 分間) |

SLO 閾値 (policy.md §8.9):

| エンドポイント | p95 SLO |
|---|---|
| `GET /api/users/me/timeline` | < 500ms |
| `POST /api/media/presigned-url` | < 2s |
| JWKS 検証 | p99 < 50ms |

---

## 2. 自動ロールバック (`scripts/canary-judge.sh`)

```bash
# 使用例
bash scripts/canary-judge.sh --step canary-5 --duration 900 --threshold 0.5
# 0 = 昇格可, 1 = ロールバック要
```

**判定ロジック**:
1. Prometheus から `rate(http_requests_total{status=~"5.."}[5m])` を取得
2. エラー率 > `--threshold` % が `--duration` 秒継続 → exit 1 (ロールバック)
3. 滞留時間経過後にエラー率正常 → exit 0 (昇格)

Flipt ramp-up:
```bash
bash scripts/flipt-ramp.sh --flag feature.xxx --percentage 20
```

---

## 3. エラーバジェット枯渔時 Release Freeze

**Prometheus Recording Rule** (recerdo-infra/observability/):

```yaml
# 30 日ウィンドウ エラーバジェット消費率
- record: job:error_budget_consumed:ratio
  expr: |
    1 - (
      sum(rate(http_requests_total{status!~"5.."}[30d]))
      / sum(rate(http_requests_total[30d]))
    )
```

**Freeze 発動条件**: `job:error_budget_consumed:ratio > 0.20` (20% 消費)

GitHub Actions での Freeze 制御:

```yaml
# deploy-beta.yml / deploy-prod.yml 冒頭
- name: Check error budget
  id: budget
  run: |
    BUDGET=$(curl -sf "$PROMETHEUS_URL/api/v1/query?query=job:error_budget_consumed:ratio" \
      | jq -r '.data.result[0].value[1]')
    echo "budget=$BUDGET" >> $GITHUB_OUTPUT
    
- name: Freeze check
  if: |
    steps.budget.outputs.budget > 0.20 &&
    !contains(github.event.pull_request.labels.*.name, 'priority:P0') &&
    !contains(github.event.pull_request.labels.*.name, 'type:security')
  run: |
    echo "Release Freeze: error budget consumed > 20%"
    exit 1
```

Slack 通知 (Freeze 発動 / 解除):
```bash
curl -X POST "$SLACK_WEBHOOK" \
  -d '{"text":"🚨 Release Freeze: error budget consumed > 20%. P0/security only."}'
```

---

## 4. Flipt パーセンテージ ランプアップ (`scripts/flipt-ramp.sh`)

```bash
#!/bin/bash
# Usage: bash scripts/flipt-ramp.sh --flag <key> --percentage <0-100>
FLIPT_URL="${FLIPT_URL:-http://localhost:8080}"
# ...flagのrollout ruleをPATCHする
curl -X PUT "$FLIPT_URL/api/v1/flags/$FLAG/rules/$RULE_ID" \
  -H "Content-Type: application/json" \
  -d "{\"percentage\": $PERCENTAGE}"
```

Grafana Annotation を記録（根本原因調査用）:
```bash
curl -X POST "http://grafana:3000/api/annotations" \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"Rollout $FLAG to ${PERCENTAGE}%\",\"tags\":[\"deploy\",\"$FLAG\"]}"
```

---

## 5. リリースノート自動生成

採用ツール: **`release-please`** (Google OSS、Go/TS/Rust 対応)

```yaml
# .github/workflows/release.yml
- uses: google-github-actions/release-please-action@v4
  with:
    release-type: go  # or node, simple
    config-file: release-please-config.json
```

`release-please-config.json` (recerdo-infra 参照) でコミットプレフィックス → CHANGELOG セクション対応。

---

## 6. Beta → 本番パイプライン

```
Beta (k3s / XServer VPS)
  ↓ make beta-deploy VERSION=v1.2.3
  ↓ canary-judge.sh 5% → 20% → 50% → 100%
  ↓ (success) promote manifest to prod overlay

Prod (OCI Container Instances)
  ↓ same rollout-config.yaml
  ↓ same canary-judge.sh logic
  ↓ same OCI Image SHA (no rebuild)
```

**同一 Image SHA の CI 検証**:
```yaml
- name: Verify image SHA consistency
  run: |
    BETA_SHA=$(docker inspect ghcr.io/willen-federation/$SVC:$VERSION --format '{{.Id}}')
    PROD_SHA=$(docker inspect ghcr.io/willen-federation/$SVC:$VERSION --format '{{.Id}}')
    [ "$BETA_SHA" = "$PROD_SHA" ] || (echo "Image SHA mismatch" && exit 1)
```
