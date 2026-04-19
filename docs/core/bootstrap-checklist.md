# Bootstrap Checklist (各リポジトリ共通)

**用途**: 新規リポ (または空リポ) の初期セットアップ項目を網羅的に定義。各リポの bootstrap meta-issue はこのチェックリストを参照する。

**対応 milestone**: Beta M0 — Foundations
**完了判定**: 全項目 ✅ で `tilt up` による起動が可能になる

---

## Phase 0: リポ基盤

- [ ] `README.md` (概要・起動手順・テスト手順・関連 docs リンク)
- [ ] `LICENSE` (private repo なら省略可)
- [ ] `.gitignore` (言語別 + IDE + OS)
- [ ] `.editorconfig`
- [ ] `CODEOWNERS` (`.github/CODEOWNERS`)
- [ ] `CONTRIBUTING.md` → [workflow.md](workflow.md) 参照

## Phase 1: GitHub メタ

- [ ] Branch protection: `main` を PR 必須 / 1 承認 / CI 必須 / linear history
- [ ] Issue template (`.github/ISSUE_TEMPLATE/`): feature / bug / chore / docs
- [ ] PR template (`.github/PULL_REQUEST_TEMPLATE.md`)
- [ ] 標準ラベル投入済 (type / priority / status / sprint / area / security)
- [ ] Milestone "Beta M0 — Foundations" 作成済
- [ ] Topics (GitHub Topics) 設定: `recerdo`, `microservice` / `client` 等

## Phase 2: CI / CD (GitHub Actions)

- [ ] `.github/workflows/lint.yml`
- [ ] `.github/workflows/test.yml`
- [ ] `.github/workflows/fmt.yml`
- [ ] `.github/workflows/build.yml` (Docker image)
- [ ] `.github/workflows/security.yml` (SAST + dep audit + secret scan + non-printable scan)
- [ ] `.github/workflows/release.yml` (tag trigger)
- [ ] `.github/workflows/deploy-beta.yml` (main push → beta)
- [ ] Required status checks 設定 (`lint`, `test`, `fmt`, `security`)

## Phase 3: Formatter / Linter

- [ ] 言語別 formatter 設定 ([workflow.md §8](workflow.md#8-コードフォーマッター) 参照)
- [ ] `.pre-commit-config.yaml`
- [ ] Makefile / Taskfile: `make fmt`, `make lint`, `make test`

## Phase 4: コード雛形 (Backend サービス限定)

- [ ] Clean Architecture ディレクトリ (`internal/domain`, `application`, `adapter`, `infra`)
- [ ] `cmd/main.go` エントリポイント
- [ ] `Dockerfile` (multi-stage, distroless base)
- [ ] `docker-compose.yml` (スタンドアロン起動用)
- [ ] proto 生成スクリプト (shared-proto 確定後)
- [ ] OTEL init
- [ ] Feature Flag 評価層 (OpenFeature)
- [ ] Health check endpoint (`/healthz`, `/readyz`)

## Phase 4': コード雛形 (Client サービス限定)

- [ ] ビルド設定 (Xcode / Flutter / Vite / Electron Forge)
- [ ] 環境別 config (dev / beta / prod) 切替
- [ ] API client 自動生成 (shared-proto から)
- [ ] Unit test スイート 1 件以上

## Phase 5: テスト基盤

- [ ] Unit test 実行コマンドが CI で動く
- [ ] Integration test (testcontainers 等) 1 ケース作成
- [ ] カバレッジ計測 + 下限 閾値 CI 組み込み

## Phase 6: セキュリティ

- [ ] Dependabot 有効化 (`.github/dependabot.yml`)
- [ ] Secret scanning 有効化 (repo settings)
- [ ] `gitleaks` CI 組み込み
- [ ] 非可読文字 scan CI 組み込み
- [ ] Trivy (コンテナイメージ scan) CI 組み込み

## Phase 7: 観測性

- [ ] OTEL exporter 設定 (dev: console, beta/prod: OTLP → Grafana/Loki)
- [ ] `/metrics` endpoint (Prometheus 形式)
- [ ] 標準ログ形式 (JSON, trace_id 付き)

## Phase 8: Tilt 対応 (recerdo-infra 側で集約)

- [ ] Dockerfile が Tilt の `docker_build` で利用可能
- [ ] Live Update 対応 (code change → container 反映)
- [ ] `resource_deps` 宣言で起動順序を定義
- [ ] UI ラベル (`backend` / `infra` / `client`)

## Phase 9: ドキュメント

- [ ] `README.md` 更新 (起動・テスト手順)
- [ ] docs 側 DD (`docs/microservice/<name>.md` or `docs/clean-architecture/<name>.md`) との整合確認
- [ ] 変更履歴を `CHANGELOG.md` で管理開始

---

## 進捗管理

- 各リポの bootstrap meta-issue に本チェックリストを転記し、進捗を更新する
- **Beta M0 完了条件**: 全リポで Phase 0-7 完了 + `tilt up` で Integration test pass
