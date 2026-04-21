# 開発ワークフロー (Comprehensive Procedure)

**ステータス**: Proposed → Accepted 予定
**版**: v1.0 (2026-04-20)
**適用範囲**: Willen-Federation org 配下の Recerdo 関連全リポジトリ

---

## 1. 概要

Recerdo は **Scrum / Agile** で開発する。Sprint は原則 2 週間、Milestone を M0 (基盤) / M1 (MVP) / M2 (Beta Public) / M3 (GA) の 4 段階で定義する。**全機能はマイクロサービス単位で独立開発**し、Feature Flag で本番反映を制御する。

### 基本原則
1. **1 Issue = 1 目的 = 1 PR = 1 Feature Flag** (原則)
2. **仕様書がないコードは書かない** (`docs/` の DD が単一真実源)
3. **テスト・フォーマッター・セキュリティ検査を CI で強制** (PASS なしマージ禁止)
4. **マージ後は Feature Flag OFF で出荷** → 段階的 rollout で ON

---

## 2. Milestone / Sprint 運用

| Milestone | 目的 | 完了基準 |
|---|---|---|
| **Beta M0 — Foundations** | 全リポ共通基盤 (CI/CD, Tilt, docker-compose, shared-proto, feature-flag, 認証) | `tilt up` で全サービス起動, 主要 RPC 疎通 |
| **Beta M1 — MVP** | album / event / timeline の最小 E2E | iOS から写真アップロード → アルバム → タイムライン表示 |
| **Beta M2 — Public Beta** | 通知 / 監査 / 管理コンソール / DM | 招待制 Beta ユーザーに公開 |
| **Beta M3 — GA Readiness** | OCI 移行, SLO 達成, 決済 | 本番昇格判定 |

**Sprint**: 2 週間。各 Sprint 冒頭に Planning、中間 Mid-Sprint Check、末に Review + Retrospective。

**Label での sprint 管理**:
- `sprint:beta-m0` / `sprint:beta-m1` / `sprint:beta-m2` / `sprint:beta-m3`
- 次 sprint 候補は `sprint:backlog`

---

## 3. Issue ライフサイクル

```
[Proposal] → [Refined] → [Ready] → [In Progress] → [In Review] → [Done]
    ↓           ↓           ↓            ↓              ↓           ↓
  生成         DD 紐付    見積完了     branch/PR     Review     merge
                                                    CI通過
```

### 3.1 Issue 作成時 (Proposal)
- **タイトル**: `[<type>] <short imperative>` (例: `[feature] album: add bulk upload endpoint`)
- **本文テンプレ必須**: Context / User Story / Design Link / Acceptance Criteria / Out of Scope / Feature Flag
- **ラベル**: `type:*`, `priority:P0-P3`, `area:*`, `sprint:*`
- **Milestone**: 適切な M0-M3 に紐付け
- **仕様書参照**: `docs/microservice/*.md` または `docs/features/*.md` へのリンクを**必須**

### 3.2 Refinement (設計詰め)
- Acceptance Criteria を検証可能な粒度まで分解
- DD に不足がある場合は **docs の PR** を先行させる
- 影響範囲: 関連サービス・クライアント・データ移行を明記

### 3.3 Ready (着手可能)
- 見積サイズ: `size:S` (< 1d) / `M` (1-3d) / `L` (3-5d) / `XL` (> 5d, 要分割)
- `XL` は自動的に Epic 化し sub-issue に分割

### 3.4 In Progress
- 担当者 assign
- **branch 作成** (§4 参照)
- progress 更新は Issue comment で日次

### 3.5 In Review
- PR open 時に自動遷移
- PR 本文から `Closes #NNN` で Issue 紐付け

### 3.6 Done
- PR merge で自動 close
- Feature Flag 作成済 + デフォルト OFF 確認

---

## 4. Branch 戦略

**Trunk-based development** + 短命 feature branch。

| Branch | 用途 | 保護 |
|---|---|---|
| `main` | 常にデプロイ可能 | Protected: PR 必須 / CI 必須 / 1 承認必須 |
| `feature/<issue-num>-<slug>` | 機能開発 | 1 Issue = 1 branch |
| `fix/<issue-num>-<slug>` | バグ修正 | 同上 |
| `chore/<issue-num>-<slug>` | 雑用 (CI 調整, deps bump 等) | 同上 |
| `docs/<slug>` | docs のみ | 同上 |
| `release/v<x.y.z>` | リリース準備ブランチ (hotfix 用) | tag cut 後削除 |

- **squash merge のみ**。`main` の history を linear に保つ
- branch 寿命 ≤ 5 営業日 (超える場合は分割 or stacked PR)
- **main へ直 push 禁止** (GitHub branch protection で enforce)

---

## 5. PR プロセス

### 5.1 PR 作成
- タイトル規約 (Conventional Commits):
  - `feat(album): add bulk upload endpoint`
  - `fix(auth): resolve JWKS cache TTL bug`
  - `chore(ci): bump golangci-lint to v1.60`
  - `docs: update album-svc DD`
- PR テンプレ必須項目:
  - Summary (3 行以内)
  - Linked Issue (`Closes #NNN`)
  - Test plan (実行した検証)
  - Feature Flag key + default (OFF)
  - Rollback 手順

### 5.2 CODEOWNERS
- `/.github/CODEOWNERS` に最低 1 名以上の所有者を定義
- 変更範囲に応じ自動 reviewer assign

### 5.3 Review 基準
- 仕様書 (DD) と実装が一致するか
- テストが Acceptance Criteria を網羅するか
- Feature Flag で挙動切替可能か
- 観測性 (log / metric / trace) が実装されているか
- セキュリティ要件 (JWT 検証 / 入力バリデーション / PII 取扱) が満たされているか

### 5.4 マージ後
1. Issue 自動 close (`Closes #NNN`)
2. Feature Flag が OFF の状態でデプロイ (本番)
3. 段階的 rollout (1% → 10% → 50% → 100%)
4. 問題なければ Feature Flag を削除 (次回リリースで clean-up issue 作成)

---

## 6. CI/CD (GitHub Actions)

全リポで共通に **以下 7 workflow** を必須とする。テンプレは `recerdo-infra/ci-templates/` に配置予定。

| Workflow | Trigger | 内容 |
|---|---|---|
| `lint.yml` | PR, push | 言語別 linter (後述) |
| `test.yml` | PR, push | unit + integration test |
| `fmt.yml` | PR | formatter diff check (違反時 fail) |
| `build.yml` | PR, push | Docker image build (push は main のみ) |
| `security.yml` | PR, weekly cron | SAST + dep audit + secret scan + non-printable char scan |
| `release.yml` | tag push | image tag push + changelog 生成 |
| `deploy-beta.yml` | main push | Beta (XServer VPS) へ自動デプロイ |

### 6.1 Required checks (branch protection)
- `lint`, `test`, `fmt`, `security` を **必須 status check** に設定
- **Green 未達の PR は merge 不可**

---

## 7. テスト戦略

| Layer | 対象 | 目標カバレッジ | ツール |
|---|---|---|---|
| **Unit** | 関数・メソッド | ≥ 80% | Go: `testing` + `testify`, TS: `vitest`, Swift: `XCTest`, Dart: `test` |
| **Integration** | サービス内層間 | 主要ユースケース | Go: `dockertest` + testcontainers, TS: `supertest` |
| **Contract (gRPC/API)** | サービス間 | 全 RPC | `buf breaking` + `prism` mock |
| **E2E** | ユーザーシナリオ | Happy path + 主要エラー | Playwright (SPA), XCUITest (iOS) |
| **Load** | 主要エンドポイント | p95 ≤ SLO | k6 (GitHub Actions scheduled) |

- **テスト無しコードはマージ不可** (カバレッジ低下を reject する CI 設定)
- **DB テストはモック禁止** → `testcontainers` で real MySQL を立てる

---

## 8. コードフォーマッター { #8-コードフォーマッター }

| 言語 | Formatter | Linter | 設定ファイル |
|---|---|---|---|
| Go | `gofumpt` + `goimports` | `golangci-lint` | `.golangci.yml` |
| TypeScript / JS | `prettier` | `eslint` (typescript-eslint) | `.prettierrc`, `eslint.config.js` |
| Swift | `swiftformat` | `swiftlint` | `.swiftformat`, `.swiftlint.yml` |
| Dart (Flutter) | `dart format` | `flutter analyze` | `analysis_options.yaml` |
| Terraform | `terraform fmt` | `tflint` + `tfsec` | `.tflint.hcl` |
| Markdown / YAML / JSON | `prettier` | `markdownlint` | `.prettierrc`, `.markdownlint.json` |
| Shell | `shfmt` | `shellcheck` | `.editorconfig` |

- **pre-commit hook** (`.pre-commit-config.yaml`) で CI 同等のチェックをローカル実行可能にする
- 違反時は自動修正可能なものは修正、不可なものは **PR で reject**

---

## 9. セキュリティ

### 9.1 CI 必須チェック
- **SAST**: Go `gosec`, TS `semgrep`, Swift `swiftlint` security rules
- **依存性監査**: `govulncheck`, `pnpm audit`, Swift Package Audit
- **Secret scan**: `gitleaks` (GitHub native secret scanning も有効化)
- **非可読文字 / Trojan Source 検出**:
  - 不可視 Unicode (BiDi, ZWJ, 制御文字) を grep で検出
  - `python -c 'import unicodedata; ...'` ベースの scan script (`recerdo-infra/scripts/scan-non-printable.sh`)
- **コンテナイメージスキャン**: `trivy` (CRITICAL/HIGH は block)

### 9.2 PR セキュリティレビュー
以下を含む PR は**必須で security:review ラベル + レビュワー 2 名**:
- 認証・認可・セッション
- 暗号化・署名・鍵管理
- 外部入出力 (API / queue / file upload)
- PII を扱う処理
- SQL / NoSQL クエリ生成
- FFmpeg / libheif 等のメディア変換 (供給鏈脆弱性)

### 9.3 GDPR / PII
- ログに PII を書き込まない (`id` のみ可、email/phone/name は禁止)
- 削除要請は audit-svc 経由で匿名化 (元ログは append-only 保持)

---

## 10. Feature Flag ライフサイクル

**Flipt + OpenFeature** を採用 (recerdo-feature-flag)。

```
[Create with default=OFF] → [Merge PR] → [Staged Rollout] → [100%] → [Clean-up Issue]
                                1% → 10% → 50% → 100%                (flag 削除)
```

### 10.1 Flag 命名規約
- `<area>.<feature>.<scope>` (例: `album.bulk_upload.enabled`, `notifications.push.ios`)
- all-lowercase / dot 区切り

### 10.2 運用ルール
- 新機能は **必ず** flag 経由でリリース (boolean / percentage / cohort)
- flag 寿命 ≤ 3 ヶ月 → clean-up Issue 作成 → 削除
- Kill Switch 用 flag は `kill-switch:*` label を付けて専用管理

---

## 11. デプロイ戦略

| 環境 | 実行基盤 | 方式 | 起動コマンド |
|---|---|---|---|
| **dev (ローカル)** | Docker Desktop / Colima | Tilt | `cd recerdo-infra/dev && tilt up` |
| **Beta** | XServer VPS + CoreServerV2 | docker-compose + k3s | `make beta-deploy` (`recerdo-infra`) |
| **Prod** | OCI Container Instances | Terraform + OCI CLI | `make prod-deploy` (`recerdo-infra`) |

### 11.1 デプロイ順序
1. `shared-proto` (変更時)
2. Backend services (依存 graph に従い bottom-up)
3. Gateway (api-gateway)
4. Clients (SPA / iOS / Android / Desktop)

### 11.2 Rollback
- 各 service image は **直近 5 tag** を保持
- `make rollback SVC=<name> VERSION=<tag>` で即切替
- DB migration は **forward-only** (down migration は書かない) → データ事故時は snapshot リストア

---

## 12. Release / Tagging

- **SemVer**: `MAJOR.MINOR.PATCH`
- **Monorepo 分割前 (Recuerdo_Backend)**: repo 全体の単一 tag
- **Monorepo 分割後 (#20 決定時)**: 各 repo 独立 tag
- **Changelog**: `CHANGELOG.md` 自動生成 (`release-please` or `semantic-release`)

---

## 13. 観測性 (Observability)

全サービスで **OTEL + W3C Trace Context** を透過的に伝播。Prometheus / Loki / Grafana (Beta), OCI Monitoring (Prod)。

- **RED metrics** (Rate / Errors / Duration) を全エンドポイントに設定
- **SLI / SLO**: 主要 UX パス (upload / timeline / notification / auth) に p95/p99 + error budget
- **Alerting**: Grafana Alertmanager → Slack / Discord

---

## 14. ドキュメント要件

### 14.1 必須ドキュメント
全リポジトリに以下を配置 (`recerdo-infra/templates/` 雛形参照):

- `README.md` — 概要・起動・テスト手順
- `CONTRIBUTING.md` — 本 workflow への参照
- `CODEOWNERS` (`.github/CODEOWNERS`)
- `.github/ISSUE_TEMPLATE/` — feature / bug / chore / docs
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/workflows/` — §6 の 7 workflow
- `.pre-commit-config.yaml`
- `LICENSE` (private なら省略可)

### 14.2 変更時の docs 更新
- 仕様変更を伴う PR は **docs の PR とセット** で提出 (2 PR 並行、先に docs)
- ADR は accepted 後は**上書き禁止**。変更時は新 ADR + 旧 ADR を `Superseded by` 更新

---

## 15. インシデント対応

### 15.1 重大度
- **SEV1**: サービス全停止・データ損失・重大セキュリティ侵害
- **SEV2**: 主要機能停止・SLO 超過
- **SEV3**: 一部機能低下
- **SEV4**: UX 劣化

### 15.2 対応フロー
1. 検知 (Grafana / FCM エラー / ユーザー報告)
2. Kill Switch flag で該当機能を OFF に即時切替 (SEV1/2)
3. Incident issue 作成 (`type:incident` label, SEV を `priority` に反映)
4. 根本原因分析 + 時系列記録
5. 修正 PR + 回帰テスト追加
6. Postmortem (SEV1/2 は必須)

---

## 16. QA (品質監査)

### 16.1 自動 QA (CI 内)
- 全 workflow green 必須
- カバレッジ下限達成必須
- contract test (buf breaking) pass 必須

### 16.2 手動 QA (merge 前 / release 前)
- **Release checklist** (`recerdo-infra/qa/release-checklist.md`) を消化
- **対応エラー時**: デバッグ → fix → CI 再実行 → 全 green までループ
- **自動編集ポリシー**: CI 失敗の自動修正は lint / fmt のみ許可。テスト / ロジックの自動修正は禁止 (人間 review 経由)

---

## 17. AI 補助開発 (Claude 等)

- AI が生成したコードでも**上記の全プロセスに従う** (ラベル / PR / レビュー / テスト)
- AI 生成と明示するため PR の body に `Generated with <tool>` を任意記載可
- **AI による自動 rename / 大規模リファクタは事前に人間承認必須**

---

## 参照

- [ADR-0001 命名規約](adr/0001-naming-convention.md)
- [Bootstrap Checklist](bootstrap-checklist.md) — 各リポの初期セットアップ
- [ProjectTrackerBoard](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/21)
- [Policy](policy.md)

---

最終更新: 2026-04-20
