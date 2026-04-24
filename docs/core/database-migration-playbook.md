# Database Migration Playbook

**参照**: `workflow.md §11.2 Rollback` · `policy.md §3.1 MariaDB 10.11`  
**最終更新**: 2026-04-24

---

## 1. 適用方針

| 規模 | 手法 |
|---|---|
| 小変更 (< 100 万行 / ロックなし) | 通常 Flyway migration |
| 大変更 (≥ 100 万行 or ALTER TABLE ロック) | `gh-ost` (トリガーレス無停止) |

**原則**: forward-only migration。ロールバック = forward 修正 PR。

---

## 2. Expand-Migrate-Contract パターン

### Step 1 — Expand（カラム追加）
```sql
-- NULL 許容で追加（既存行に影響なし）
ALTER TABLE users ADD COLUMN display_name VARCHAR(255) NULL;
```
CI: MySQL 8.0 + MariaDB 10.11 両方で PASS を確認。

### Step 2 — Migrate（新旧両対応アプリをデプロイ）
- アプリは旧カラムと新カラム両方を読み書き
- バックグラウンドジョブで既存行をバックフィル

### Step 3 — Contract（旧カラム削除）
```sql
-- 全行が新カラムに移行済みであることを確認してから実行
ALTER TABLE users DROP COLUMN name;
```

各 Step を独立 PR で管理（PR 間に最低 1 スプリント間隔推奨）。

---

## 3. gh-ost による無停止大規模変更

### 3.1 前提条件

- `log-bin=mysql-bin` 有効
- `binlog-format=ROW`
- `log-slave-updates=ON`

> ⚠️ MariaDB 10.11 での動作は個別検証が必要 (gh-ost は MySQL 向け設計)。  
> MariaDB では `pt-online-schema-change` (Percona Toolkit) を代替として検討する。

### 3.2 実行手順

```bash
# 1. Dry run（実際のコピーは行わない）
gh-ost \
  --host=localhost --port=3306 \
  --user=root --password="$DB_PASSWORD" \
  --database=recerdo --table=media_files \
  --alter="ADD COLUMN thumbnail_path VARCHAR(512) NULL" \
  --dry-run

# 2. 本番実行
gh-ost \
  --host=localhost --port=3306 \
  --user=root --password="$DB_PASSWORD" \
  --database=recerdo --table=media_files \
  --alter="ADD COLUMN thumbnail_path VARCHAR(512) NULL" \
  --allow-on-master \
  --max-load=Threads_running=25 \
  --critical-load=Threads_running=100 \
  --chunk-size=1000 \
  --max-lag-millis=1500 \
  --initially-drop-old-table \
  --initially-drop-ghost-table \
  --ok-to-drop-table \
  --execute
```

### 3.3 進捗確認

```bash
echo "status" | nc -U /tmp/gh-ost.recerdo.media_files.sock
```

---

## 4. CI 互換性確認

```yaml
strategy:
  matrix:
    db: [mysql:8.0, mariadb:10.11]
services:
  db:
    image: ${{ matrix.db }}
    env:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: recerdo_test
```

マイグレーションは両バージョンで PASS が必須 (policy.md §3.1)。

---

## 5. ロールバック手順

DB migration は **forward-only**。ロールバック手順:

1. Expand 済みカラムを残したまま旧アプリにロールバック（アプリのみ）
2. 新カラムは NULL 許容のため旧アプリが無視しても問題なし
3. 次 PR で旧カラム復元 or 新カラム削除の forward migration を適用

---

## 6. 参考

- [gh-ost GitHub](https://github.com/github/gh-ost)
- [Percona pt-online-schema-change](https://docs.percona.com/percona-toolkit/pt-online-schema-change.html)
- [Stripe: Zero-downtime migrations](https://stripe.com/blog/online-migrations)
