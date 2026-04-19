# ローカル開発セットアップ (Tilt でシステム起動)

**Recerdo 全体を `tilt up` 一発で起動**するためのガイド。

対応 Issue: [#22](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/22) · ADR: [ADR-0002](adr/0002-repo-layout-per-service.md)

---

## 1. 前提 (必要なツール)

| ツール | 用途 | インストール |
|---|---|---|
| **Tilt** ≥ 0.37 | オーケストレーター | `brew install tilt-dev/tap/tilt` |
| **Docker Desktop** または **Colima** | コンテナランタイム | [Docker Desktop](https://www.docker.com/products/docker-desktop/) / `brew install colima` |
| **gh** (GitHub CLI) | リポ clone | `brew install gh` |
| **Go** ≥ 1.24 | recerdo-core ビルド | `brew install go` |
| Node / pnpm (任意) | SPA client | `brew install pnpm` |

### 動作確認

```bash
tilt version            # v0.37.1 以上
docker version          # Server が動いていること
gh auth status          # Willen-Federation にアクセス可能
go version              # 1.24 以上
```

---

## 2. 兄弟リポの Clone (一発スクリプト)

Tilt は **兄弟ディレクトリに複数リポが揃っている前提** で動きます。1 箇所 (例: `~/Development/GitHub/`) に全 repo を並べて clone:

```bash
mkdir -p ~/Development/GitHub && cd ~/Development/GitHub

# private repo にアクセスするため (初回のみ)
export GOPRIVATE=github.com/Willen-Federation/*

for R in recerdo-infra recerdo-core recerdo-shared-proto recerdo-shared-lib \
         recerdo-album recerdo-event recerdo-timeline recerdo-storage \
         recerdo-notifications recerdo-audit recerdo-feature-flag \
         recerdo-permission-management recerdo-admin-system recerdo-admin-cli \
         recerdo-spa-webclient recerdo-android-dart recerdo-desktop-electron \
         Recerdo-iOS Recuerdo_Backend; do
  if [ ! -d "$R" ]; then
    gh repo clone Willen-Federation/$R
  fi
done
```

!!! warning "旧 PascalCase ディレクトリがある場合"
    以前 `Recerdo-Album` / `Recerdo-Core` などの PascalCase で clone 済の場合、[ADR-0001](adr/0001-naming-convention.md) 準拠の新名 `recerdo-album` / `recerdo-core` に **ローカルでもリネーム** するか再 clone してください。Tilt は新名 (lowercase) を参照します。

    ```bash
    # 例: 一括リネーム
    cd ~/Development/GitHub
    for OLD in Recerdo-Album Recerdo-Event Recerdo-Timeline Recerdo-Storage \
               Recerdo-Core Recerdo-AdminSystem Recerdo-SPA-Webclient \
               Recerdo-Android-Dart Recerdo-Desktop-Electron \
               Recerdo-Permission-Management; do
      NEW=$(echo "$OLD" | tr 'A-Z' 'a-z' | sed 's|adminsystem|admin-system|; s|webclient|-webclient|' )
      [ -d "$OLD" ] && mv "$OLD" "$NEW"
    done
    ```

---

## 3. Docker Daemon 起動

```bash
# Docker Desktop の場合
open -a Docker

# Colima の場合 (よりマシン負荷低)
colima start --cpu 4 --memory 8 --disk 60
```

確認:

```bash
docker ps   # エラーなく動くこと
```

---

## 4. Tilt で起動

```bash
cd ~/Development/GitHub/recerdo-infra/dev
tilt up
```

起動後:

| URL | 内容 |
|---|---|
| [http://localhost:10350](http://localhost:10350) | **Tilt UI** (全サービスのログ / ヘルス / build 状況) |
| [http://localhost:3000](http://localhost:3000) | Nginx API Gateway |
| [http://localhost:3000/swagger](http://localhost:3000/swagger) | Swagger UI (OpenAPI 仕様) |

Tilt UI でサービスを個別に restart / trigger rebuild / log 確認ができます。

停止:

```bash
Ctrl+C            # fore-ground 停止
tilt down         # コンテナも削除してクリーンアップ
```

---

## 5. プロファイル切替

大量のサービスを起動するとローカル負荷が高いので、目的別に絞れます:

```bash
tilt up -- --profile=minimal       # core + infra のみ (db, redis, nginx, recerdo-core)
tilt up -- --profile=backend-only  # Backend 全サービス (clients 除外)
tilt up -- --profile=default       # すべて (デフォルト; 省略可)
```

詳細は `recerdo-infra/dev/Tiltfile` の `profile` セクション参照。

---

## 6. 移行状況 (2026-04-20 時点)

[ADR-0002](adr/0002-repo-layout-per-service.md) Phase B の per-service 移植状況により、Tiltfile の挙動が異なります:

| サービス | Tilt 挙動 | 状態 |
|---|---|---|
| `recerdo-core` | `local_resource` + Live Update | ✅ 移行済 |
| `recerdo-storage` | Recuerdo_Backend compose 経由 | ⏳ Phase B 対象 |
| `recerdo-album` | Recuerdo_Backend compose 経由 | ⏳ Phase B 対象 |
| `auth` (legacy) | Recuerdo_Backend compose 経由 | deprecated (Cognito 移行中) |
| `metrics` | Recuerdo_Backend compose 経由 | ⏳ 未決定 |
| Infra (db / redis / nginx / swagger-ui) | compose | ✅ |
| Clients (SPA / iOS / Android / Desktop) | Tiltfile placeholder | 🔧 未有効化 |

Phase B が進むたびに `recerdo-infra/dev/Tiltfile` の該当行を `local_resource` + `dc_resource` override に切替えます。

---

## 7. Live Update (ファイル変更の自動反映)

現在 Live Update 対応済: **recerdo-core のみ**。

兄弟 repo `recerdo-core/cmd/` または `internal/` 配下を編集すると、数秒以内にコンテナ内の binary が置換されます (Tilt UI でステータスを確認)。

他サービスは移行完了後に対応します。

---

## 8. よくあるトラブル

### `no such file or directory: ../../../recerdo-core`
Tiltfile は `recerdo-infra/dev/Tiltfile` からの相対パスで `../../recerdo-core` など兄弟リポを参照します。前述の [§2 clone スクリプト](#2-clone) を実行して同一親ディレクトリに全 repo を配置してください。

### `go: module github.com/Willen-Federation/recerdo-shared-lib: cannot find module`
private repo へのアクセス設定が必要です:

```bash
export GOPRIVATE=github.com/Willen-Federation/*
# SSH 認証を使用する場合
git config --global url."git@github.com:".insteadOf "https://github.com/"
# HTTPS + PAT の場合
gh auth setup-git
```

### Docker daemon not running
```bash
open -a Docker          # Docker Desktop
colima start            # Colima
```

### ポート競合
既存プロセスが占有している場合:

```bash
lsof -i :3000           # 何が使っているか確認
```

`recerdo-infra/envs/beta/compose/docker-compose.yml` の ports セクションで変更可能。

---

## 9. 次のステップ

- **Bootstrap 進捗**: 各 repo の `[tracker] Bootstrap` issue を参照
- **新サービス移行時**: Tiltfile の該当行を更新する PR を submit
- **CI 連携**: 本番反映は `recerdo-infra/envs/{beta,prod}/` の compose / terraform 経由 ([デプロイメント戦略](deployment-strategy.md))

## 参照

- [開発 Workflow](workflow.md)
- [Bootstrap Checklist](bootstrap-checklist.md)
- [ADR-0001 命名](adr/0001-naming-convention.md) / [ADR-0002 per-service](adr/0002-repo-layout-per-service.md)
- [Tracker #21](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/21)
- [`recerdo-infra/dev/Tiltfile`](https://github.com/Willen-Federation/recerdo-infra/blob/main/dev/Tiltfile)
- [`recerdo-infra/dev/README.md`](https://github.com/Willen-Federation/recerdo-infra/blob/main/dev/README.md)
