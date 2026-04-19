# ローカル開発環境 — Tilt + Colima によるマイクロサービス構築

> **対象フェーズ**: 開発（PoC / Closed Beta / Open Beta / GA 準備）すべて
> **作成日**: 2026-04-20
> **最終更新**: 2026-04-20
> **ステータス**: 承認待ち
> **前提ドキュメント**: [デプロイメント戦略](deployment-strategy.md) / [環境抽象化 & Feature Flag](environment-abstraction.md) / [マイクロサービス一覧](../microservice/index.md)

!!! note "ポリシー準拠"
    本ドキュメントは最新インフラポリシーに準拠しています。ローカル開発環境は Beta 構成（**XServer VPS + CoreServerV2 CORE+X**）と同一スタックを開発者マシン上で再現することを目的とし、**Garage**（S3 互換 OSS）／**Redis + BullMQ・asynq**／**Postfix + Dovecot + Rspamd**／**Flipt**／**MySQL（MariaDB 10.11 互換スキーマ）** を統合する。AWS 依存は **Cognito JWKS のみ**（JWT 検証用のエミュレータでモック）。

!!! tip "操作手順は別ページ"
    本ページは **設計・方針** ドキュメントです。実際に `tilt up` でシステムを起動する **手順** は [ローカル開発 (Tilt 起動手順)](local-dev.md) を参照してください。両者は役割分担しており、Bootstrap 時は `local-dev.md` → 設計意図を深掘りするときに本ページを参照する導線を想定しています。

!!! warning "このドキュメントが指すリポジトリ"
    以降で登場する `Tiltfile` / `Makefile` / `deploy/dev/` / `deploy/k3s/` / `.env.local.enc` などの成果物は、本ドキュメントリポジトリ（`Recerdo-Developers-Docs`）ではなく、**アプリケーション本体リポジトリ（`Willen-Federation/recerdo-infra` ほか）** に配置される **将来の** 構成です。本ページはその設計図（SSOT）であり、まだ実装されていない参照は「将来の予定」として読み替えてください。現時点で動く手順は [ローカル開発 (Tilt 起動手順)](local-dev.md) に集約されています。

---

## 1. エグゼクティブサマリー

Recerdo は 9 個のマイクロサービス（auth / audit / album / events / timeline / storage / notifications / feature-flag / admin-console）と複数のミドルウェア（MySQL / Redis / Garage / Postfix / Flipt / Loki 等）で構成される。これらを開発者のマシン上で **本番と同等のトポロジ** で起動し、かつ **保存即反映（live reload）** できる環境を提供する。

| 課題                                               | 採用手段                                                      |
| -------------------------------------------------- | ------------------------------------------------------------- |
| 9 サービス + ミドルウェア の手動起動コスト         | **Tilt** による宣言的オーケストレーション                     |
| コード変更 → コンテナ再ビルド の待ち時間           | Tilt の **live_update**（差分 sync + 再起動）                 |
| Docker Desktop のライセンス制約（商用 250 人以上） | **Colima**（OSS・Apple Silicon 対応）を第一候補に             |
| 将来の Kubernetes 化（OKE 移行）                   | Colima 付属の **k3s** または **kind** を Tilt から直接ターゲット |
| Beta / 本番と同一のキュー・ストレージ実装          | Redis + BullMQ / asynq、Garage、Postfix を **そのまま起動**   |
| AWS Cognito への依存                               | **cognito-local** でモックし、オフラインで JWKS を提供        |

**原則**: ローカル環境用に **新しい実装を作らない**。[環境抽象化](environment-abstraction.md) の Adapter と環境変数だけで Beta 相当を再現し、本番切替時の乖離をゼロにする。

---

## 2. 背景と目的

### 2.1 なぜ Docker Compose 単体では不足か

既存設計書（例: [server-capacity-planning.md](server-capacity-planning.md)、[firewall-data-protection.md](firewall-data-protection.md)）で Beta は **Docker Compose** で運用する方針を示しているが、開発者マシンでは以下の追加要件がある：

- **編集 → 実行** のフィードバックループを数秒に収めたい（`docker compose up --build` は毎回イメージを再生成する）
- 9 サービスの **起動順序** と **ヘルスチェック** を宣言的に扱いたい（`depends_on` だけでは不足）
- サービスごとのログ・ビルド状況・ポートを **一元ダッシュボード** で確認したい
- **ローカル k3s** へ同じ定義で昇格できるようにし、将来の OKE 移行に備えたい

Tilt はこれらを同一 `Tiltfile` で表現でき、`docker-compose.yml` を "ソース" として読み込む互換モードも備えるため、既存資産を壊さずに導入できる。

### 2.2 なぜ Colima を採用候補に入れるか

| 項目                         | Docker Desktop                             | **Colima**                         | OrbStack                     | Rancher Desktop              |
| ---------------------------- | ------------------------------------------ | ---------------------------------- | ---------------------------- | ---------------------------- |
| ライセンス                   | 商用利用に制約（250 人超の企業は有料）     | **OSS（Apache-2.0）**              | 商用無料 / 業務は有料        | OSS                          |
| Apple Silicon (arm64) 対応   | ✅                                          | **✅（ネイティブ + Rosetta 切替）** | ✅                            | ✅                            |
| 仮想化バックエンド           | HyperKit / Apple Virtualization            | **Lima（QEMU / vz）**              | 独自                         | Lima / WSL2                  |
| Kubernetes 同梱              | ✅（単一ノード）                            | **✅（k3s / k8s 選択）**            | ✅                            | ✅（k3s）                     |
| リソース制御                 | GUI                                        | **CLI（`--cpu` / `--memory`）**    | GUI + CLI                    | GUI                          |
| x86_64 バイナリ実行          | Rosetta                                    | **Rosetta / qemu-x86_64 切替**     | Rosetta                      | qemu                         |
| Recerdo 採用方針             | 個人開発での継続は可、**組織成長時に危険** | **第一推奨（OSS・ロックイン無し）** | 個人での補助選択             | 代替の Kubernetes 実験用     |

Colima は **Docker CLI / Docker Compose / Docker Engine API** を互換提供するため、`DOCKER_HOST` を向けるだけで既存ワークフローを維持できる。Recerdo の AWS 利用は Cognito のみ・ストレージは Garage・キューは Redis と、いずれもロックインのない OSS に統一されているため、**コンテナランタイムも OSS に統一** することでポリシー全体と整合する。

### 2.3 将来性の担保（ランタイム可搬性）

ポリシー §4.1（[policy.md](policy.md)）の「単一コードベース」と同じ考え方を開発環境にも適用する。特定のコンテナランタイム（Docker Desktop）に依存した手順書を書かず、`DOCKER_HOST` と `CONTAINER_RUNTIME` の **環境変数 2 つ** で差し替え可能な構成にする。

```mermaid
flowchart LR
  Dev["開発者マシン (macOS / Linux / WSL2)"]
  subgraph Runtimes["コンテナランタイム (差し替え可能)"]
    Colima["Colima (第一推奨・OSS)"]
    Docker["Docker Desktop (個人利用)"]
    Orb["OrbStack (補助)"]
    Rancher["Rancher Desktop (k8s 実験)"]
  end
  Tilt["Tilt (宣言的オーケストレーション)"]
  Stack["Beta 相当スタック<br/>MySQL / Redis / Garage / Flipt / Postfix / 9 マイクロサービス"]

  Dev -->|DOCKER_HOST 設定| Runtimes
  Runtimes -->|Docker Engine API| Tilt
  Tilt -->|live_update / k8s_yaml| Stack
```

---

## 3. ローカル開発スタック構成

### 3.1 起動対象サービス

| 層                 | プロダクト                  | ポート            | 備考                                                                 |
| ------------------ | --------------------------- | ----------------- | -------------------------------------------------------------------- |
| API Gateway        | Traefik                     | 80 / 443 / 8080   | Beta と同じ設定。Let's Encrypt はステージング証明書をスキップしモック |
| 認証               | **cognito-local**           | 9229              | Cognito User Pool + JWKS のモック。本物の Cognito に接続する切替も可 |
| Auth Svc           | recuerdo-auth-svc           | 8001              | Go / Echo。`live_update` 対象                                        |
| Audit Svc          | recuerdo-audit-svc          | 8002              | Go。Outbox Publisher を含む                                          |
| Album Svc          | recuerdo-album-svc          | 8003              | Go。Garage / MySQL / Redis に依存                                    |
| Events Svc         | recuerdo-events-svc         | 8004              | Go                                                                   |
| Timeline Svc       | recuerdo-timeline-svc       | 8005              | Go。Fan-out ワーカー同居                                             |
| Storage Svc        | recuerdo-storage-svc        | 8006              | Go。FFmpeg / libheif を同一コンテナに同梱                            |
| Notification Svc   | recuerdo-notifications-svc  | 8007              | Go。FCM はエミュレータへ、SMTP は Postfix へ                         |
| Feature Flag Svc   | recuerdo-feature-flag-svc   | 8008              | Go。Flipt を内部で呼び出す                                           |
| Admin Console Svc  | recuerdo-admin-console-svc  | 8009              | Go もしくは Rails 実装                                               |
| Feature Flag 基盤   | **Flipt**                   | 8090              | OSS セルフホスト。Beta と同じ                                        |
| キュー基盤         | **Redis 7**                 | 6379              | BullMQ / asynq 共用                                                  |
| ダッシュボード     | **Bull Board / asynqmon**   | 3000 / 8085       | キュー状況の可視化                                                   |
| データベース       | **MySQL 8.0 / MariaDB 10.11** | 3306 / 3307    | 両方起動し、互換性テストを PR で常に回す                             |
| オブジェクトストレージ | **Garage**                | 3900 / 3901       | S3 互換 API。Album / Storage のバックエンド                          |
| メール             | **Postfix + Dovecot + Rspamd** | 25 / 587 / 143 | 本物と同じ構成。送信先は MailHog で捕捉                              |
| メール UI          | **MailHog**                 | 8025              | Postfix からリレーし、ブラウザで受信確認                             |
| FCM                | **fcm-emulator**（OSS）     | 5005              | Android / iOS の Push をローカル捕捉                                 |
| ログ集約           | **Grafana Loki + Promtail** | 3100              | Beta と同じ                                                          |
| 可視化             | **Grafana**                 | 3001              | ダッシュボード（RED メトリクス）                                      |

### 3.2 全体トポロジ

```mermaid
flowchart TB
  subgraph Dev["開発者マシン"]
    IDE["VS Code / JetBrains"]
    CLI["tilt CLI"]
  end

  subgraph Runtime["Colima (Lima VM) / Docker Desktop"]
    subgraph Net["Docker Network: recerdo-dev"]
      GW["Traefik (Gateway)"]
      subgraph SVC["マイクロサービス群"]
        Auth["auth-svc :8001"]
        Album["album-svc :8003"]
        Events["events-svc :8004"]
        Timeline["timeline-svc :8005"]
        Storage["storage-svc :8006"]
        Notif["notifications-svc :8007"]
        Audit["audit-svc :8002"]
        FF["feature-flag-svc :8008"]
        Admin["admin-console-svc :8009"]
      end
      subgraph Infra["Beta 相当ミドルウェア"]
        MySQL["MySQL 8.0 :3306"]
        MariaDB["MariaDB 10.11 :3307"]
        Redis["Redis :6379"]
        Garage["Garage (S3 互換) :3900"]
        Flipt["Flipt :8090"]
        Postfix["Postfix+Dovecot+Rspamd :25/587"]
        MailHog["MailHog :8025"]
        CognitoLocal["cognito-local :9229"]
        FCMEmu["fcm-emulator :5005"]
        Loki["Loki :3100"]
        Grafana["Grafana :3001"]
      end
    end
  end

  IDE -->|保存| CLI
  CLI -->|live_update| SVC
  CLI -->|compose/ k8s_yaml| Infra
  GW --> Auth & Album & Events & Timeline & Storage & Notif & Admin
  SVC -->|MariaDB 互換 SQL| MySQL & MariaDB
  SVC -->|enqueue| Redis
  Storage -- S3 API --> Garage
  Album -- S3 API --> Garage
  Notif -- SMTP 587 STARTTLS --> Postfix
  Postfix --> MailHog
  Notif --> FCMEmu
  Auth -.JWKS.-> CognitoLocal
  SVC -->|EvaluateFlag| FF
  FF --> Flipt
  SVC -.logs.-> Loki
  Loki --> Grafana
```

---

## 4. Tilt 採用根拠と使いどころ

### 4.1 Tilt が解く問題

| 問題                                                           | Tilt の機能                                                      |
| -------------------------------------------------------------- | ---------------------------------------------------------------- |
| 9 サービスの起動順序・依存制御                                 | `resource_deps`、`local_resource`、`trigger_mode`                |
| 編集 → 反映の遅延                                              | `live_update`（ファイル sync + 軽量 restart / run コマンド）     |
| サービスごとの状態可視化                                       | Tilt UI（`tilt up` で `http://localhost:10350` にダッシュボード） |
| 個別サービスだけ rebuild する                                  | Tilt UI から `Rebuild` ボタン、CLI `tilt trigger`                |
| Compose / Kubernetes の **二重運用**                            | `docker_compose()` と `k8s_yaml()` を同じ `Tiltfile` で両立      |
| CI / 手動開発の **統一**                                       | `tilt ci` で非対話モード、PR ごとのスモークテストが可能          |

### 4.2 Tiltfile 構成方針

リポジトリルートに単一の `Tiltfile` を置き、以下のモードを切替可能にする：

- `TILT_TARGET=compose`（既定）: Docker Compose ベース起動（Beta と同じ）
- `TILT_TARGET=k3s`: Colima 同梱 k3s にデプロイ（将来の OKE 移行リハーサル）

```python
# Tiltfile (抜粋) — アプリケーション本体リポジトリ (recerdo-infra など) に配置される想定
load('ext://restart_process', 'docker_build_with_restart')

target = os.environ.get('TILT_TARGET', 'compose')
# §4.3 で定義する 5 プロファイル (full / core / media / notify / admin)
profile = os.environ.get('TILT_PROFILE', 'full')

# 1) 共通ミドルウェアは compose から読み込み
docker_compose('./deploy/dev/docker-compose.infra.yml')

# 2) アプリは Go サービスごとに個別ビルド + live_update
# 4 要素目: そのサービスの依存先 (resource_deps に渡す他サービス名)
services = [
    ('feature-flag-svc',  8008, './services/feature-flag-svc',  []),
    ('auth-svc',          8001, './services/auth-svc',          ['feature-flag-svc']),
    ('audit-svc',         8002, './services/audit-svc',         ['feature-flag-svc']),
    ('album-svc',         8003, './services/album-svc',         ['auth-svc', 'feature-flag-svc']),
    ('events-svc',        8004, './services/events-svc',        ['auth-svc', 'feature-flag-svc']),
    ('timeline-svc',      8005, './services/timeline-svc',      ['auth-svc', 'feature-flag-svc']),
    ('storage-svc',       8006, './services/storage-svc',       ['auth-svc', 'feature-flag-svc']),
    ('notifications-svc', 8007, './services/notifications-svc', ['auth-svc', 'feature-flag-svc']),
    ('admin-console-svc', 8009, './services/admin-console-svc', ['auth-svc', 'feature-flag-svc']),
]

# プロファイルごとに含めるサービスを選択
profile_members = {
    'full':   {s[0] for s in services},
    'core':   {'auth-svc', 'audit-svc', 'feature-flag-svc'},
    'media':  {'storage-svc', 'album-svc', 'feature-flag-svc', 'auth-svc'},
    'notify': {'notifications-svc', 'feature-flag-svc', 'auth-svc'},
    'admin':  {'admin-console-svc', 'feature-flag-svc', 'auth-svc'},
}
enabled = profile_members[profile]

for name, port, path, deps in services:
    if name not in enabled:
        continue
    docker_build_with_restart(
        ref='recerdo/' + name + ':dev',
        context=path,
        dockerfile=path + '/Dockerfile.dev',
        entrypoint=['/app/bin/' + name],
        live_update=[
            sync(path + '/cmd',       '/app/cmd'),
            sync(path + '/internal',  '/app/internal'),
            sync(path + '/go.sum',    '/app/go.sum'),
            run('cd /app && go build -o /app/bin/' + name + ' ./cmd/' + name,
                trigger=[path + '/cmd', path + '/internal']),
        ],
    )
    # 起動順序 (Feature Flag → auth/audit → 他) は resource_deps で明示
    active_deps = [d for d in deps if d in enabled]
    if target == 'compose':
        dc_resource(name, resource_deps=active_deps, labels=['recerdo'])
    else:
        k8s_yaml('./deploy/k3s/' + name + '.yaml')
        k8s_resource(name, port_forwards=[port],
                     resource_deps=active_deps, labels=['recerdo'])
```

!!! tip "ビルド高速化のポイント"
    - `Dockerfile.dev` では **マルチステージを使わず** `golang:1.22-alpine` を直接使い、`go build` は `live_update` 側で実行する。
    - `go mod download` をイメージビルド時に済ませ、`GOCACHE` を volume に永続化する。
    - **BuildKit** を有効化（`DOCKER_BUILDKIT=1`）。Colima は既定で BuildKit 対応。

### 4.3 起動プロファイル

「全サービス起動」は重いため、用途別プロファイルを用意する。`TILT_PROFILE` で切替え：

| プロファイル | 起動対象                                                       | 用途                                        |
| ------------ | -------------------------------------------------------------- | ------------------------------------------- |
| `full`       | 全サービス + 全ミドルウェア                                    | 統合テスト・E2E                             |
| `core`       | auth / audit / feature-flag + MySQL / Redis / Flipt            | 認証・監査・Flag 系の単体改修               |
| `media`      | storage / album + Garage / Redis + FFmpeg                      | HLS / HEIC 変換の開発                       |
| `notify`     | notifications / feature-flag + Postfix / MailHog / fcm-emulator | 通知経路（Push-first + 条件付き Email）調整 |
| `admin`      | admin-console + feature-flag + auth + Flipt                     | 管理者コンソール UI 検証                    |

---

## 5. Colima 採用根拠と運用

### 5.1 インストールと起動

```bash
# macOS (Homebrew)
brew install colima docker docker-compose docker-buildx tilt-dev/tap/tilt

# Linux は distro のパッケージマネージャで colima を導入

# Recerdo 推奨プロファイル（Apple Silicon ネイティブ + Rosetta x86_64）
colima start recerdo \
  --cpu 6 \
  --memory 10 \
  --disk 80 \
  --arch aarch64 \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs \
  --kubernetes=false

# DOCKER_HOST の自動設定（Colima が docker context を作成）
docker context use colima-recerdo
```

!!! note "推奨スペックの根拠"
    Beta 基盤（[server-capacity-planning.md](server-capacity-planning.md)）は **6 core / 10 GB**。ローカルでも同等を確保することで、CPU 競合による「本番では再現しない性能差」を抑制する。メモリが 10 GB 未満のマシンでは `TILT_PROFILE=core`（約 3 GB で収まる）を既定にする。

### 5.2 k3s 併設モード（将来性）

本番の Beta → GA 移行で **OCI Container Instances → OKE（Kubernetes）** への昇格を想定している（[policy.md](policy.md) §1.2）。Colima の k3s を有効化し、同一 `Tiltfile` で Kubernetes モードに切り替えれば、移行リハーサルを開発者マシン上で行える。

```bash
colima start recerdo-k3s \
  --cpu 6 --memory 10 --disk 80 \
  --kubernetes \
  --kubernetes-version v1.30.3+k3s1

kubectl config use-context colima-recerdo-k3s
TILT_TARGET=k3s tilt up
```

### 5.3 複数ランタイムの切替

`DOCKER_HOST` と `docker context` を使うことで、**Tiltfile を変更せず** にランタイムを差し替える：

```bash
# Colima
docker context use colima-recerdo

# Docker Desktop（個人利用の開発者）
docker context use desktop-linux

# OrbStack
docker context use orbstack
```

!!! warning "運用上の決定事項"
    - **CI は Colima 固定**（OSS・再現性・ライセンス非依存）。
    - 個人開発者が Docker Desktop / OrbStack を使うことは妨げないが、**PR の検証は Colima で通ること** を条件にする。
    - 手順書・README・Makefile は **`colima` を第一推奨** として書く。Docker Desktop 固有の GUI 操作（`Kubernetes` タブ等）は参照しない。

---

## 6. 環境変数と Feature Flag

[環境抽象化](environment-abstraction.md) の `.env.local` パターンをそのまま使う。ローカル固有値は `deploy/dev/.env.local.example` にテンプレート化する。

### 6.1 ローカル規定値

| 変数                    | ローカル既定値                                 | 備考                                                               |
| ----------------------- | ---------------------------------------------- | ------------------------------------------------------------------ |
| `APP_ENV`               | `local`                                        | ログ識別用。動作分岐には使わない                                   |
| `QUEUE_PROVIDER`        | `redis-bullmq` / `redis-asynq`                 | Beta と同じ。`oci-queue` に切り替える場合は VPN で OCI へ接続      |
| `QUEUE_URL`             | `redis://redis:6379/0`                         | Compose 内ネットワーク名                                           |
| `STORAGE_PROVIDER`      | `garage`                                       | Garage をローカル起動                                              |
| `STORAGE_ENDPOINT`      | `http://garage:3900`                           | コンテナ間通信                                                     |
| `STORAGE_BUCKET_ALBUM`  | `recerdo-album-local`                          | 自動作成スクリプトで bootstrap                                     |
| `MAIL_PROVIDER`         | `postfix-smtp`                                 | Postfix を起動、配送先は MailHog                                   |
| `MAIL_SMTP_HOST`        | `postfix`                                      | Compose 内ホスト名                                                 |
| `MAIL_SMTP_PORT`        | `587`                                          | STARTTLS（自己署名。開発用）                                       |
| `AUTH_COGNITO_ENDPOINT` | `http://cognito-local:9229`                    | `cognito-local` の JWKS URL                                        |
| `AUTH_COGNITO_POOL_ID`  | `local_pool`                                   | モック値                                                           |
| `FEATURE_FLAG_URL`      | `http://feature-flag-svc:8008`                 | 内部 Port                                                          |
| `DATABASE_URL`          | `mysql://recerdo:recerdo@mysql:3306/recerdo`   | MySQL 8 側                                                         |
| `DATABASE_COMPAT_URL`   | `mysql://recerdo:recerdo@mariadb:3307/recerdo` | MariaDB 10.11 側（互換性チェック用に並走）                         |
| `DATABASE_COMPAT_MODE`  | `mariadb-10.6`                                 | policy.md §3.1 に準拠                                              |
| `MEDIA_TRANSCODER`      | `ffmpeg-hls`                                   | Beta と同じ                                                        |
| `OBSERVABILITY_BACKEND` | `loki`                                         | ローカルでも Loki を起動                                           |

!!! danger "ローカルでも遵守するポリシー"
    - `STORAGE_PROVIDER=aws-s3` / `STORAGE_PROVIDER=minio` は **設定しても動作しない**（Adapter 未実装）。
    - `QUEUE_PROVIDER=aws-sqs` / `MAIL_PROVIDER=aws-ses` / `MAIL_PROVIDER=sns` も同様。
    - Cognito 本物に接続する場合のみ `AUTH_COGNITO_ENDPOINT` を AWS の JWKS URL に差し替える。

### 6.2 シークレット（整備予定）

- **sops + age** で `.env.local.enc` をアプリ側リポに Git 管理し、開発者は `age` 公開鍵を交換する。
- `tilt up` 前に `make dev.decrypt` で復号して `.env.local` に展開する `Makefile` を提供する **予定**。成果物（`Makefile` / `.env.local.enc` / `deploy/dev/.env.local.example`）が揃うまでは、§7.1 の「現時点で動く代替手順」で `sops --decrypt` を直接叩くか、`.env.local` を手動作成する。
- `.env.local` は `.gitignore` 対象。

### 6.3 Flipt のシード

ローカル用に以下の Flag を起動時 Seed する（`deploy/dev/flipt-seed.json`）：

```json
{
  "flags": [
    { "key": "infra.queue.provider",   "variant": "redis-bullmq" },
    { "key": "infra.storage.provider", "variant": "garage" },
    { "key": "infra.mail.provider",    "variant": "postfix-smtp" },
    { "key": "infra.media.transcoder", "variant": "ffmpeg-hls" },
    { "key": "infra.dualWrite.enabled","boolean": false },
    { "key": "infra.readFrom",         "variant": "beta" }
  ]
}
```

---

## 7. 動作確認手順

### 7.1 初回セットアップ（設計上の最短経路）

アプリケーションリポジトリが揃った後の理想形を示す。`Brewfile` / `Makefile` / `.env.local.enc` は **現時点ではまだ存在せず**、アプリケーション本体リポジトリ側で順次整備する予定のため、現行で動かす場合は下の「現時点で動く代替手順」を使う。

```bash
# 将来の想定（Brewfile / Makefile が整備された後）
git clone git@github.com:Willen-Federation/recerdo-infra.git && cd recerdo-infra
brew bundle                              # Brewfile を追加後に有効化
colima start recerdo --cpu 6 --memory 10 --vz-rosetta
docker context use colima-recerdo
make dev.decrypt                         # .env.local を復号（sops + age のラッパ）
tilt up                                  # http://localhost:10350 でダッシュボード
```

**現時点で動く代替手順**（Brewfile / Makefile が無い前提）:

```bash
# 依存ツールを明示インストール（§5.1 と同じ）
brew install colima docker docker-compose docker-buildx tilt-dev/tap/tilt sops age

# VM 起動とコンテキスト切替
colima start recerdo --cpu 6 --memory 10 --vz-rosetta
docker context use colima-recerdo

# シークレット復号（Makefile 無しのフォールバック）
sops --decrypt deploy/dev/.env.local.enc > deploy/dev/.env.local   # ファイルが整備された後
# あるいは、初回は手元に `.env.local` を手動で作成（§6.1 のカタログを参照）

tilt up
```

初回は Garage / MySQL / MariaDB のボリューム初期化に 2〜3 分かかる。Tilt UI で各リソースが `Ready` になるのを確認する。

### 7.2 スモークチェック

```bash
# Cognito モックでトークン取得
curl -X POST http://localhost:9229/token -d 'username=dev&password=dev'

# Auth Svc のヘルスチェック（JWT 検証まで）
curl -H "Authorization: Bearer $TOKEN" http://localhost:8001/health

# Album 作成（MySQL + Redis + Garage + Flipt を経由）
curl -X POST http://localhost:8003/api/albums \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"name":"local-test"}'

# メール到達確認
open http://localhost:8025

# キュー状況
open http://localhost:3000    # Bull Board
open http://localhost:8085    # asynqmon

# メトリクス
open http://localhost:3001    # Grafana
```

### 7.3 MariaDB 互換テスト

`DATABASE_COMPAT_URL` を指すテストは `make test.compat` で MariaDB 10.11 側に対して同一 SQL を実行する（[policy.md](policy.md) §3.1、[environment-abstraction.md](environment-abstraction.md) §6.1 参照）。CI でも同等ジョブを実行する。

---

## 8. Docker Compose との共存（段階的移行）

既存の Beta 運用スクリプト（`recerdo-infra/deploy/beta/docker-compose.yml` 想定）を残しつつ、開発は Tilt 経由に移行する。Tilt 側の `docker_compose()` でミドルウェアを読み込み、アプリのみ Tilt 管理にすることで **Compose ファイル 1 セット** を両環境で維持する。

!!! info "パスはアプリ本体リポジトリが前提"
    以下の表や節 9 で参照する `deploy/` 配下のパスは、アプリケーション本体リポジトリ（`Willen-Federation/recerdo-infra` など）に配置される予定の構成です。本ドキュメントリポジトリには `deploy/` ディレクトリは存在しません。

| 構成要素             | Beta 運用（VPS）                     | ローカル開発                            |
| -------------------- | ------------------------------------ | --------------------------------------- |
| ミドルウェア定義     | `deploy/beta/docker-compose.yml`     | `deploy/dev/docker-compose.infra.yml`（Beta から派生） |
| アプリ起動方法       | `docker compose up -d`               | `tilt up`（live_update あり）           |
| ビルド              | CI で事前にイメージを push            | Tilt が `Dockerfile.dev` を用いて即時ビルド |
| 監視                 | Prometheus + Loki + Grafana          | 同左（ローカルでも同構成）              |
| Feature Flag         | Flipt（VPS）                          | Flipt（コンテナ）                       |

!!! note "Docker Compose だけでも動く保険"
    `docker compose -f deploy/dev/docker-compose.full.yml up` は Tilt 不使用でもフル起動できる "最低保証パス" として維持する。Tilt はその上に live_update / UI / 依存管理を乗せる位置づけ。

---

## 9. Kubernetes（k3s / OKE）への昇格パス

本番は OCI Container Instances を起点に、スケール要件に応じて OKE（Kubernetes）へ移行する方針（[policy.md](policy.md) §1.2）。`Tiltfile` は最初から **k8s_yaml 経路を実装** しておき、開発者が任意でローカル k3s に切り替えられるようにする。

### 9.1 マニフェスト配置

```
deploy/
├── dev/
│   ├── docker-compose.infra.yml   # ミドルウェア
│   └── docker-compose.full.yml    # 全サービス（Tilt 不使用時の保険）
├── beta/
│   └── docker-compose.yml         # XServer VPS 用
└── k3s/
    ├── namespace.yaml
    ├── auth-svc.yaml
    ├── album-svc.yaml
    ├── ...
    └── kustomization.yaml          # 本番 OKE 用 overlay の土台
```

### 9.2 Tilt からの切替

```bash
# Compose モード（既定）
tilt up

# k3s モード（Colima で k3s を起動した状態）
TILT_TARGET=k3s tilt up
```

k3s で動くことを CI で週次チェックすれば、**OKE 移行時に Manifest を書き起こす必要がない**。

---

## 10. リスクと緩和策

| リスク                                                      | 影響度 | 緩和策                                                                                     |
| ----------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------ |
| メモリ不足で全サービス起動が重い                            | 中     | `TILT_PROFILE=core/media/notify` のプロファイル運用を周知、README に冒頭で明記             |
| Colima VM の時刻ずれで JWT 検証失敗                         | 低     | `colima ssh -- sudo chronyd -q` を `make dev.up` に同梱                                    |
| Docker Desktop 依存の手順書が混入                           | 中     | CI に「`docker desktop` / `Docker Desktop` 文字列検出」の grep lint を追加                 |
| AWS Cognito に本物接続して課金が発生                        | 低     | 既定を `cognito-local` に固定、本物接続は環境変数切替で明示的に行う                        |
| `live_update` の差分同期が大量ファイルで遅い                 | 中     | `Dockerfile.dev` の `COPY` を最小化、`live_update` の `sync` パスをサービス内部に限定      |
| k3s モードでローカル DNS / PV が Compose モードと差異       | 中     | `k3s.io/local-path` と `traefik` v2 を固定、`README` の動作確認コマンドを両モードで検証    |
| Garage のローカル永続データが肥大化                         | 低     | `make dev.clean` で Garage / MySQL のボリューム削除                                        |
| 開発者マシンで Postfix のアウトバウンド 25/587 が封鎖される | 低     | MailHog にリレーするため外部送信不要。Postfix 設定で `relayhost = mailhog:1025` を固定      |

---

## 11. 運用 / リリースサイクルへの組み込み（目標）

現状のアプリケーション本体 CI は `mkdocs build --strict` のみで、Tilt / Colima を実行するワークフローはまだ無い。**将来の運用目標** として以下を設計する（対応するワークフロー追加を伴うため、本ドキュメントだけでは有効化されない）:

- **PR ごと**: `tilt ci` を GitHub Actions で実行し、`TILT_PROFILE=core` のスモークを 5 分以内に完了させる（要: アプリリポ側でワークフロー追加）。
- **夜間 (nightly)**: Colima 上の k3s で `TILT_TARGET=k3s` を起動し、[environment-abstraction.md](environment-abstraction.md) §6.1 の統合テストマトリクスを回す。
- **リリース直前**: [deployment-strategy.md](deployment-strategy.md) §5 の Beta → 本番マッピングどおりに環境変数を OCI 向けに差し替え、同じ `Tiltfile` で本番 staging（OKE）の手前まで同一定義で動くことを確認する。

!!! note "CI 連携は別 PR で段階導入"
    本ページは設計 SSOT であり、実際の GitHub Actions 設定追加は `recerdo-infra` 側で別 PR として提出する。本ページの変更だけで CI が自動的に Tilt を回し始めるわけではない点に注意する。

---

## 12. 参考文献

- [Tilt 公式ドキュメント](https://docs.tilt.dev/)
- [Tilt — live_update リファレンス](https://docs.tilt.dev/live_update_reference.html)
- [Tilt — Docker Compose サポート](https://docs.tilt.dev/docker_compose.html)
- [Colima — GitHub](https://github.com/abiosoft/colima)
- [Lima — Linux VMs on macOS](https://lima-vm.io/)
- [k3s — Lightweight Kubernetes](https://k3s.io/)
- [cognito-local — AWS Cognito ローカルエミュレータ](https://github.com/jagregory/cognito-local)
- [Garage Documentation](https://garagehq.deuxfleurs.fr/documentation/)
- [Flipt Documentation](https://www.flipt.io/docs)
- [MailHog — SMTP testing tool](https://github.com/mailhog/MailHog)
- [The Twelve-Factor App — Dev/prod parity](https://12factor.net/dev-prod-parity)

---

## 13. 関連ドキュメント

- [ローカル開発 (Tilt 起動手順)](local-dev.md) — **操作ガイド**。本ドキュメントと対の関係で、実際の `tilt up` / `colima start` 手順・兄弟リポ clone スクリプト・トラブルシューティングをカバー
- [デプロイメント戦略](deployment-strategy.md) — Beta（Docker Compose）／本番（OCI Container Instances / OKE）への接続点
- [環境抽象化 & Feature Flag](environment-abstraction.md) — 本ドキュメントが前提とする `.env.local` / Adapter の切替
- [サーバーキャパシティ計画](server-capacity-planning.md) — Colima 推奨 CPU/メモリの根拠
- [ファイアウォール & データプロテクション](firewall-data-protection.md) — Docker ネットワーク分離とローカル再現
- [キュー抽象化設計](../microservice/queue-abstraction.md) — Redis + BullMQ / asynq / OCI Queue の Port と Adapter
- [マイクロサービス一覧](../microservice/index.md) — 9 サービスの責務と依存関係

---

最終更新: 2026-04-20 初版（Tilt + Colima によるローカル開発環境の整備）
