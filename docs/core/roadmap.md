# Recerdo 全リポジトリ開発ロードマップ

**最終更新**: 2026-04-24  
**参照**: [task-dependency-matrix.md](task-dependency-matrix.md) · [poc-beta-scope.md](poc-beta-scope.md) · [workflow.md](workflow.md)

---

## フェーズ概要

| フェーズ | マイルストーン | 目標 | 期間目安 |
|---|---|---|---|
| **Phase 0** | Beta M0 Foundations | リポ・CI・プロト・基盤ブートストラップ | Week 1 |
| **Phase 1** | Beta M1 MVP | コア機能・認証・gRPC・デプロイ | Week 2–4 |
| **Phase 2** | Beta M2 Public Beta | フルスタック・モニタリング・外部公開 | Week 5–8 |
| **Phase 3** | Beta M3 GA | OCI 移行・多地域・SLA 99.9% | Week 9+ |

---

## リポジトリ別ステータス (2026-04-24)

### インフラ・共通

| リポジトリ | Phase 1 | Phase 2 | Phase 3 | 備考 |
|---|---|---|---|---|
| `recerdo-infra` | ✅ 完了 | ✅ 完了 | 🔲 OCI Terraform | k3s deploy済み |
| `recerdo-shared-proto` | ✅ 完了 | ✅ 完了 | ✅ 完了 | Go/TS/Swift/Dart codegen |
| `recerdo-shared-lib` | ✅ 完了 | ✅ 完了 | 🔲 M3 GA | JWT/Rate limit/Idempotency |

### バックエンドサービス

| リポジトリ | Phase 1 | Phase 2 | Phase 3 | 備考 |
|---|---|---|---|---|
| `recerdo-core` | ✅ 完了 | ✅ 完了 | 🔲 OCI LB (#20) | API Gateway, Cognito |
| `recerdo-event` | ✅ 完了 | ✅ 完了 | ✅ 完了 | Outbox/Saga, testcontainers |
| `recerdo-album` | ✅ 完了 | ✅ 完了 | ✅ 完了 | Media, HEIC, HLS |
| `recerdo-timeline` | ✅ 完了 | ✅ 完了 | ✅ 完了 | Feed ranking |
| `recerdo-notifications` | ✅ 完了 | ✅ 完了 | ✅ 完了 | FCM, APNS, Email |
| `recerdo-storage` | ✅ 完了 | ✅ 完了 | 🔲 Cross-region (#17) | Garage S3, presigned |
| `recerdo-audit` | ✅ 完了 | ✅ 完了 | ✅ 完了 | Hash chain, Merkle |
| `recerdo-permission-management` | ✅ 完了 | ✅ 完了 | ✅ 完了 | RBAC, Delegation |
| `recerdo-feature-flag` | ✅ 完了 | ✅ 完了 | ✅ 完了 | Flipt, A/B testing |
| `recerdo-auth` | ✅ 完了 | ✅ 完了 | 🔲 M3 GA | Cognito JWKS |
| `recerdo-api-gateway` | ✅ 完了 | ✅ 完了 | 🔲 OCI migration | JWT, rate limit, routing |

### 管理・ツール

| リポジトリ | Phase 1 | Phase 2 | Phase 3 | 備考 |
|---|---|---|---|---|
| `recerdo-admin-system` | ✅ 完了 | ✅ 完了 | 🔲 M3 GA | Next.js 15 + shadcn/ui |
| `recerdo-admin-cli` | ✅ 完了 | 🔲 CLI scope | 🔲 M3 GA | Feature flag + deploy assist |

### クライアント

| リポジトリ | Phase 1 | Phase 2 | Phase 3 | 備考 |
|---|---|---|---|---|
| `recerdo-spa-webclient` | ✅ 完了 | 🔲 M2 | 🔲 M3 | React/Next.js SPA |
| `Recerdo-iOS` | ✅ 完了 | 🔲 M2 | 🔲 M3 | Swift/Combine |
| `recerdo-android` | ✅ 完了 | 🔲 M2 | 🔲 M3 | Kotlin/Jetpack Compose |
| `recerdo-desktop-electron` | ✅ 完了 | 🔲 M2 | 🔲 M3 | Electron |

---

## スプリント管理ルール

### ブランチ命名

```
feat/<issue-number>-<short-description>
fix/<issue-number>-<short-description>
chore/<issue-number>-<short-description>
```

### Issue → PR → マージ フロー (バイブコーディング)

```
1. Issue 確認 (AC, 技術要件, テスト計画)
2. ブランチ作成: feat/<n>-<name>
3. TDD: 失敗テスト → 実装 → グリーン
4. CI pass: fmt / lint / test / security
5. PR 作成 (Closes #N)
6. --admin merge (billing 制約で CI 実行不可の場合)
7. Issue 自動クローズ
8. Feature Flag OFF → 段階的 rollout
```

### PR 自動クローズ設定

PR body に以下を記載:
```
Closes #<issue-number>
```

GitHub が `main` マージ時に自動 close する。

### GitHub Projects ボード設定

| カラム | 説明 | 自動化 |
|---|---|---|
| Backlog | 未着手 Issue | 新規 Issue 作成時 |
| In Progress | ブランチ作成済み | PR オープン時 |
| Review | PR レビュー中 | PR レビューリクエスト時 |
| Done | マージ済み | PR merge 時 |

### ラベル体系

```bash
# 優先度
gh label create "priority:P0" --color "FF0000" --repo Willen-Federation/<repo>
gh label create "priority:P1" --color "FF6600" --repo Willen-Federation/<repo>
gh label create "priority:P2" --color "FFAA00" --repo Willen-Federation/<repo>
gh label create "priority:P3" --color "FFDD00" --repo Willen-Federation/<repo>

# タイプ
gh label create "type:feature"  --color "0075CA" --repo Willen-Federation/<repo>
gh label create "type:bug"      --color "D73A4A" --repo Willen-Federation/<repo>
gh label create "type:chore"    --color "E4E669" --repo Willen-Federation/<repo>
gh label create "type:docs"     --color "0075CA" --repo Willen-Federation/<repo>
gh label create "type:epic"     --color "6F42C1" --repo Willen-Federation/<repo>

# エリア
gh label create "area:backend"   --color "BFD4F2" --repo Willen-Federation/<repo>
gh label create "area:infra"     --color "BFD4F2" --repo Willen-Federation/<repo>
gh label create "area:security"  --color "F9D0C4" --repo Willen-Federation/<repo>
gh label create "area:qa"        --color "C2E0C6" --repo Willen-Federation/<repo>

# スプリント
gh label create "sprint:beta-m1" --color "1D76DB" --repo Willen-Federation/<repo>
gh label create "sprint:beta-m2" --color "1D76DB" --repo Willen-Federation/<repo>
gh label create "sprint:beta-m3" --color "1D76DB" --repo Willen-Federation/<repo>
```

---

## CI 共通品質基準

| 項目 | 基準 |
|---|---|
| テストカバレッジ (Go) | ≥ 80% |
| テストカバレッジ (TypeScript/Swift/Dart) | ≥ 80% |
| MariaDB 互換 | 10.11 (matrix: mysql:8.0 + mariadb:10.11) |
| フォーマット | gofumpt / prettier / swiftformat / dart format |
| Lint | golangci-lint / ESLint / SwiftLint |
| セキュリティ | gosec + gitleaks + trivy + semgrep |
| PR → Issue クローズ | `Closes #N` 記法 |

---

## 残タスク (M3 GA)

| リポジトリ | Issue | 内容 |
|---|---|---|
| `recerdo-core` | #20 | OCI Load Balancer backend migration |
| `recerdo-storage` | #17 | Cross-region replication (OCI Object Storage) |
| `recerdo-infra` | #24-#28, #33, #43 | OCI Terraform modules + DR + multi-region |
| `recerdo-admin-system` | #4 | M3 GA epic |
| `recerdo-infra` | #5 | M3 GA epic |
