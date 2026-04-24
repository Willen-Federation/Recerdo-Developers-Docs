# Post-Mortem Template

> SEV1/SEV2 は解消後 48 時間以内に作成必須 (workflow.md §15.2)。  
> エラーバジェットの 20% 以上消費した場合も作成。

---

## 1. Summary

| 項目 | 内容 |
|---|---|
| Incident ID | INC-YYYY-MMDD-NNN |
| Severity | SEV1 / SEV2 / SEV3 |
| 検知 (UTC) | YYYY-MM-DD HH:MM |
| 解消 (UTC) | YYYY-MM-DD HH:MM |
| Duration | HH 時間 MM 分 |
| 担当 IC (Incident Commander) | |
| 通知先 | Slack #incidents, 管理者 |

---

## 2. Impact

| 項目 | 内容 |
|---|---|
| 影響機能 | (例: 画像アップロード, タイムライン) |
| 影響ユーザー数 | (例: 全ユーザー / 一部) |
| エラー率ピーク | (例: 42%) |
| エラーバジェット消費 | (例: 月次バジェットの XX%) |
| ビジネス影響 | (例: アップロード不可, 通知遅延) |

---

## 3. Timeline (UTC)

| 時刻 | イベント |
|---|---|
| HH:MM | 異常検知 (アラート / ユーザー報告) |
| HH:MM | IC 任命・インシデント宣言 |
| HH:MM | 調査開始 |
| HH:MM | 仮説 X を確認 |
| HH:MM | Kill Switch / ロールバック 実施 |
| HH:MM | ユーザー影響解消確認 |
| HH:MM | 根本原因特定 |
| HH:MM | インシデントクローズ |

---

## 4. Root Cause

### 直接原因
(例: storage-svc の DB 接続プールが枯渇)

### 5 Whys 分析

1. なぜ障害が発生したか？
2. なぜ (1) が起きたか？
3. なぜ (2) が起きたか？
4. なぜ (3) が起きたか？
5. 根本要因:

### 寄与要因
- (例: 監視の閾値が不適切だった)
- (例: Runbook が古かった)

---

## 5. Trigger / Resolution

| 項目 | 内容 |
|---|---|
| Trigger | どの変更・イベントが引き金か |
| Detection Method | アラート / ユーザー報告 / 監視 |
| Resolution | 実施した対応 (Kill Switch, rollback, restart) |
| Kill Switch 使用 | フラグ名 / ON→OFF |
| 再発防止策 | |

---

## 6. Action Items

P0 アクションアイテムは最低 1 件必須 (Google SRE Error Budget Policy)。

| Priority | Action | 担当 | 期限 |
|---|---|---|---|
| P0 | | | YYYY-MM-DD |
| P1 | | | YYYY-MM-DD |
| P2 | | | |

---

## 7. Blameless Review Policy

> 「誰が悪いか」ではなく「なぜシステムが失敗を許したか」を問う。  
> 個人の行動を責めず、プロセス・ツール・設計の改善に焦点を当てる。  
> このドキュメントは公開される前提で作成すること。
