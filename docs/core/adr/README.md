# Architecture Decision Records (ADR)

Recerdo プロジェクトにおける意思決定の記録。

## 運用ルール
- 1 つの決定 = 1 ファイル (`NNNN-<slug>.md`、NNNN はゼロ埋め 4 桁の連番)
- 一度 Accepted になった ADR は**書き換えず**、上書き決定時は新 ADR を作成し該当 ADR を `Superseded by NNNN` に更新
- ステータス: `Proposed` / `Accepted` / `Deprecated` / `Superseded by ...`

## インデックス

| # | タイトル | ステータス | 決定日 |
|---|---|---|---|
| [0001](0001-naming-convention.md) | リポジトリ命名規約 (`recerdo-<name>`) | Accepted | 2026-04-20 |
| [0002](0002-repo-layout-per-service.md) | リポジトリレイアウト — per-service 採用 | Accepted | 2026-04-20 |
| [0003](0003-admin-console-placement.md) | admin-console-svc 実装リポの確定 | Accepted | 2026-04-20 |
| [0004](0004-audit-service-placement.md) | audit-svc を単独リポで管理 | Accepted | 2026-04-20 |
