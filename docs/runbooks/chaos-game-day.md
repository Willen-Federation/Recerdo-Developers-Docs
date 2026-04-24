# Chaos Engineering Game Day 計画

**参照**: `policy.md §8.7 Circuit Breaker` · `environment-abstraction.md §8.2 緊急ロールバック`  
**頻度**: 四半期に1回 (Beta M2 以降)

---

## ゴール

本番類似環境 (staging VPS) で故意に障害を注入し、以下を検証する:

1. Kill Switch・Circuit Breaker が期待通り動作するか
2. Runbook 手順が実際に機能するか
3. MTTR (Mean Time To Recover) の実測
4. アラートが正しく発火するか

---

## シナリオ一覧

### SEV1 シナリオ

| ID | シナリオ | 注入方法 | 期待動作 | Kill Switch |
|---|---|---|---|---|
| C-01 | MySQL 完全停止 | `docker stop mysql` | api-gateway 503 返却, リトライ3回後断念 | `db.read_replica.enabled: OFF` |
| C-02 | Redis 完全停止 | `docker stop redis` | セッションなし → Cognito フォールバック | `cache.session.enabled: OFF` |
| C-03 | storage-svc 停止 | `docker stop recerdo-storage` | 画像アップロード503, 既存閲覧は継続 | `storage.upload.enabled: OFF` |

### SEV2 シナリオ

| ID | シナリオ | 注入方法 | 期待動作 |
|---|---|---|---|
| C-04 | Outbox Consumer 停止 | `kill -9 <outbox-worker-pid>` | メッセージ蓄積、再起動後追いつく |
| C-05 | notifications-svc FCM 障害 | `iptables -A OUTPUT -p tcp --dport 443 -d fcm.googleapis.com -j DROP` | 通知失敗、5回リトライ後 DLQ |
| C-06 | CPU/メモリ高負荷 | `stress --cpu 4 --vm 2 --vm-bytes 512M` | Rate limiter 発動、p99 増加 |

### SEV3 シナリオ

| ID | シナリオ | 注入方法 | 期待動作 |
|---|---|---|---|
| C-07 | network latency 500ms | `tc qdisc add dev eth0 root netem delay 500ms` | Circuit Breaker 発動 |
| C-08 | packet loss 10% | `tc qdisc add dev eth0 root netem loss 10%` | 再試行増加、SLO 影響確認 |

---

## 実施手順

### 準備 (前日)

```bash
# 1. staging 環境確認
make beta-status

# 2. 観測基盤確認
curl -s http://localhost:3001/api/health  # Grafana

# 3. Kill Switch デフォルト確認
curl -s http://flipt:8080/api/v1/flags | jq '.flags[] | {key, enabled}'

# 4. ロールバックコマンド確認
make beta-rollback SVC=recerdo-storage VERSION=latest
```

### 実施 (Game Day 当日)

```bash
# 各シナリオ: 注入 → 観測 → 回復 → 記録
# 例: C-01
docker stop mysql
# → Grafana で mysql_up = 0 確認
# → api-gateway エラー率 確認
# → Kill Switch 発動: flipt flag update db.read_replica.enabled false
# → 回復: docker start mysql
# → MTTR 記録
```

### 後処理

```bash
# tc ルール削除
tc qdisc del dev eth0 root

# iptables ルール削除
iptables -D OUTPUT -p tcp --dport 443 -d fcm.googleapis.com -j DROP

# Kill Switch リセット
# 全フラグを元の状態に戻す
```

---

## 合格基準 (SLO)

| メトリクス | 目標 |
|---|---|
| MTTR (SEV1) | < 30 分 |
| MTTR (SEV2) | < 2 時間 |
| Kill Switch 発動 → 効果確認 | < 2 分 |
| アラート発火遅延 | < 2 分 |
| Runbook 手順完走率 | 100% |

---

## 結果記録テンプレート

```markdown
## Game Day YYYY-MM-DD

| シナリオ | 開始 | 回復 | MTTR | Kill Switch 使用 | 問題点 |
|---|---|---|---|---|---|
| C-01 | HH:MM | HH:MM | MM 分 | はい/いいえ | |

### アクションアイテム
- [ ] ...
```
