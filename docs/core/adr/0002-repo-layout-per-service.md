# ADR-0002: リポジトリレイアウト — per-service 採用

**ステータス**: Accepted
**決定日**: 2026-04-20
**決定者**: @kackey621
**関連 Issue**: [#20](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/20)
**前提 ADR**: [ADR-0001 命名規約](0001-naming-convention.md)

---

## コンテキスト

バックエンドは現状 2 つの形態が併存:

1. **`Recuerdo_Backend`** (Go workspace monorepo) — `services/{auth,core,album,storage,metrics}` + `proto/` + `pkg/`
2. **per-service 空リポ** — `recerdo-core`, `recerdo-album`, `recerdo-event`, `recerdo-timeline`, `recerdo-storage`, `recerdo-notifications`, `recerdo-audit`, `recerdo-feature-flag`, `recerdo-permission-management`, `recerdo-admin-system`

このまま放置すると **二重管理** となり、どちらが正か不明瞭。

## 決定

**per-service 分割に本移行する (Option A)**。

- 各マイクロサービスは **独立リポ** (`recerdo-<name>`, ADR-0001 準拠) で開発・CI・release を独立管理
- `Recuerdo_Backend` の既存 `services/<name>/` は、各 per-service リポへ移植完了後に **archive** する
- `Recuerdo_Backend/proto/` は [ADR-0002a (shared-proto)](#) で新リポ `recerdo-shared-proto` へ抽出
- `Recuerdo_Backend/pkg/` は [ADR-0002b (shared-lib)](#) で新リポ `recerdo-shared-lib` へ抽出

## 論拠

- **ユーザーの既成事実**: 11 のマイクロサービス毎に独立リポを作成済 (2026-04-13 〜 04-19)。モノリス維持を選ぶなら、これらの repos は無用になる
- **マイクロサービス設計原則** (docs/microservice): サービス境界を repo 境界と一致させることで、責務分離を自然に強制
- **独立 CI / release cycle**: per-service repo だと build / deploy の blast radius が限定的
- **ADR-0001 との整合性**: 命名規約を per-service 前提で策定済

### Option B (monorepo 維持) を不採用とする理由
- 既存の 11 個 per-service 空リポを archive する方が、統合作業より可逆性が低い
- Go workspace は dev 体験には便利だが、独立 release を阻害する
- CI 時間が monorepo 肥大で線形に増加

### Option C (ハイブリッド) を不採用とする理由
- 境界設計が主観的になり、ADR で明文化しづらい
- "どのサービスは monorepo で、どれは独立か" の判断基準が揺らぐ

## マイグレーション計画

### Phase A: 依存分離 (blocking)
1. [ADR-0002a] `recerdo-shared-proto` リポ作成 → `proto/` 移植 → `buf lint` / `buf breaking` CI
2. [ADR-0002b] `recerdo-shared-lib` リポ作成 → `pkg/` 移植 (必要なパッケージのみ)
3. Go module path 更新: `recuerdo/*` → `github.com/Willen-Federation/recerdo-<name>/*`

### Phase B: サービス単位の移植
各サービスで順番に:
1. per-service repo で `go mod init github.com/Willen-Federation/recerdo-<name>` (まだ無い場合)
2. `Recuerdo_Backend/services/<name>/` のソースを移植
3. `cmd/main.go` エントリポイント確立
4. `Dockerfile` を per-service repo に持つ (monorepo 版は廃止)
5. CI (lint/test/fmt/build/security) を [workflow.md §6](../workflow.md#6-cicd-github-actions) 準拠で設定
6. docker-compose は `recerdo-infra/envs/beta/compose/` に集約 (本 ADR §§4 compose-files policy)
7. Tilt: `recerdo-infra/dev/Tiltfile` から各 repo の Dockerfile を `docker_build` で参照

移植順 (依存 bottom-up):
1. `recerdo-core` (auth 含む)
2. `recerdo-storage`
3. `recerdo-album`
4. `recerdo-event`
5. `recerdo-timeline`
6. `recerdo-permission-management`
7. `recerdo-notifications`
8. `recerdo-audit`
9. `recerdo-feature-flag`
10. `recerdo-admin-system`

### Phase C: 旧 monorepo archive
- 全サービス移植完了後、`Recuerdo_Backend` を **archive** (削除ではなく、read-only 化)
- `Recuerdo_Backend` 内の `recuerdo/...` import path 参照は Phase A/B で解消済のはず
- Phase 2 の repo rename (`Recuerdo_Backend` → `recerdo-backend` 案) は **不要** になる — archive により回避

## 影響

- **#15** (shared-proto 抽出): 本 ADR §Phase A で着手
- **#16** (shared-lib 抽出): 本 ADR §Phase A で着手
- **DD の "リポジトリ名" 列**: 既に PR #23 / PR #24 で `recerdo-<name>` に更新済
- **Tracker #21**: "Phase 2 Rename" セクションから `Recuerdo_Backend` → `recerdo-backend` を削除し、「archive 計画」に置換

## 参照

- [#20 Monorepo split decision](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/20)
- [#15 shared-proto](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/15)
- [#16 shared-lib](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/16)
- [ADR-0001](0001-naming-convention.md)
- [workflow.md §11 デプロイ戦略](../workflow.md#11-デプロイ戦略)
