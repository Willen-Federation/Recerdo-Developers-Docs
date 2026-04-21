# ADR-0003: admin-console-svc 実装リポの確定

**ステータス**: Accepted
**決定日**: 2026-04-20
**決定者**: @kackey621
**関連 Issue**: [#18](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/18)

---

## コンテキスト

docs/microservice/admin-console-svc.md で定義された **管理者コンソール (Rails 8)** の実装リポが、以下 3 候補で競合していた:

| 候補 repo | 説明 |
|---|---|
| `recerdo-admin-system` (旧 Recerdo-AdminSystem) | ADR-0001 命名規約に準拠、2026-04-13 作成 |
| `AdminPanel_Recerdo` | 2026-04-04 作成、命名不統一 (PascalCase + underscore + 単語順序逆) |
| `recerdo-admin-cli` (旧 recuerdo-admin-cli) | CLI ツール、admin-console-svc とは別責務 |

## 決定

以下のように役割分担を確定:

1. **`recerdo-admin-system`** = **admin-console-svc の Rails Web UI 実装** (docs/microservice/admin-console-svc.md の正本)
2. **`recerdo-admin-cli`** = 管理者用 CLI ツール (別責務、別 repo のまま維持)
3. **`AdminPanel_Recerdo`** = **archive** (本 ADR 採択と同時に実施)

## 論拠

- **`recerdo-admin-system`** は ADR-0001 命名規約 (`recerdo-<name>`) に準拠しており、運用開始時点で違和感がない
- **`AdminPanel_Recerdo`** は空リポ (246 B、README のみ) で、命名規約に大きく違反。歴史的価値も薄い
- **`recerdo-admin-cli`** は CLI 用途として独立した責務。Web UI と同居させると git log / CI が複雑化するため分離維持
- docs/microservice/admin-console-svc.md の設計 (Rails 8 + モデレーション + Feature Flag 管理画面) は web UI 前提

## 実施アクション

- [x] `AdminPanel_Recerdo` を archive する (`gh api --method PATCH /repos/Willen-Federation/AdminPanel_Recerdo -F archived=true`)
- [x] docs/microservice/admin-console-svc.md の「リポジトリ名」表記が `recerdo-admin-console` / `recerdo-admin-system` いずれに揃えるか確認
  - **決定**: docs では `recerdo-admin-system` を正式名とする (実 repo と一致)
  - docs/microservice/index.md の表も更新

## 参照

- [#18 admin-console placement](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/18)
- [docs/microservice/admin-console-svc.md](../../microservice/admin-console-svc.md)
- [ADR-0001](0001-naming-convention.md)
