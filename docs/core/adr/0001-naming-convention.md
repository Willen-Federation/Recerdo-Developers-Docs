# ADR-0001: リポジトリ命名規約

**ステータス**: Accepted
**決定日**: 2026-04-20
**決定者**: @kackey621
**関連 Issue**: [#17](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/17)

---

## コンテキスト

2026-04-19 時点で、Willen-Federation org 配下には 4 種類の命名規約が併存していた:

| # | パターン | 例 |
|---|---|---|
| 1 | `Recuerdo_Backend` | Backend monorepo (スペイン語正綴 + underscore) |
| 2 | `Recerdo-<Name>` | `Recerdo-iOS`, `Recerdo-Core`, `Recerdo-Album` (PascalCase + kebab) |
| 3 | `recuerdo-<name>-svc` | docs 仕様 (lowercase + kebab + `-svc` suffix) |
| 4 | `recerdo-<name>` | 新 4 repos (2026-04-19): `recerdo-notifications` 他 |

4 種類併存は以下の問題を引き起こしていた:

- 新規 repo 作成時の命名に迷いが生じる
- docs と実 repo 名が乖離し、参照の正当性が追えない
- 綴り `Recuerdo` vs `Recerdo` の混在により、検索・grep での全件把握が困難
- `-svc` suffix 有無によりエコシステム (Go module path, Dockerfile tag) が不統一

## 決定

**全リポジトリで `recerdo-<name>` (all lowercase, kebab-case, 'u' 抜き, `-svc` suffix なし) を採用する**。

### 規則
1. **綴り**: `recerdo` (英語式, 'u' を抜く)
2. **ケース**: all lowercase
3. **単語区切り**: ハイフン `-`
4. **サフィックス**: マイクロサービスでも `-svc` を付けない
5. **複合単語の分解**: 合成語は単語単位で `-` 区切り
   - `AdminSystem` → `admin-system`
   - `SPA-Webclient` → `spa-webclient`
   - `Android-Dart` → `android-dart`

### 例外
- **`Recerdo-Developers-Docs`**: docs リポは従来の PascalCase を維持する (歴史的 URL と mkdocs 設定のため)

### docs 内の表記
- 本 ADR 以降、docs 内の**リポジトリ名表記**は `recerdo-<name>` で統一する
- docs 内のファイル名 (`docs/microservice/*-svc.md`) は現時点では変更しない (内部リンクと mkdocs 設定への影響を避けるため、別途対応)

### 本 ADR のスコープ外

以下は本 ADR の対象外。別 ADR または Phase 2 rename PR で個別に検討する:

- **ブランド/プロダクト名 (`Recuerdo プラットフォーム` 等の prose)**: docs 内で "Recuerdo" は依然としてプラットフォーム名として使われる箇所がある。綴り統一 (`Recuerdo` vs `Recerdo`) はブランド・UX の判断を含むため、本 ADR では扱わない
- **Go module import path (`recuerdo/album/domain` 等)**: `go.mod` / `go.work` で定義される module path。`Recuerdo_Backend` の rename と同時に別 PR で一括更新する
- **Kubernetes namespace / Queue topic / DB name (`recuerdo` namespace, `recuerdo.album.*` topic, DB `recuerdo`)**: 実環境の識別子であり、docs のみの書換では drift を生むため、infra 変更と同時に更新する

## 背景・論拠

- 2026-04-19 にユーザー (@kackey621) が 4 新規 repos を `recerdo-*` 形式で作成: `recerdo-notifications`, `recerdo-feature-flag`, `recerdo-audit` (旧 `-recerdo-audit`), `recerdo-infra` (旧 `recerdo-infra-Terraform`)
- この行動が「将来の意図」を示しており、既存 `Recerdo-*` / `recuerdo-*-svc` を新基準に合わせる方が drift コストが低い
- `-svc` 削除理由: サービス以外のコンポーネント (iOS / SPA / infra) と一貫性を持たせるため
- OSS コミュニティの慣習 (kubernetes, istio, argoproj 等) も lowercase-kebab が主流

## 影響範囲

### Phase 1: 即リネーム (2026-04-20 実施済)

以下 13 リポを `recerdo-<name>` に rename 済:

| 旧 | 新 |
|---|---|
| `-recerdo-audit` | `recerdo-audit` |
| `recerdo-infra-Terraform` | `recerdo-infra` |
| `Recerdo-Desktop-Electron` | `recerdo-desktop-electron` |
| `Recerdo-Album` | `recerdo-album` |
| `Recerdo-Event` | `recerdo-event` |
| `Recerdo-Timeline` | `recerdo-timeline` |
| `Recerdo-Storage` | `recerdo-storage` |
| `Recerdo-Core` | `recerdo-core` |
| `Recerdo-Permission-Management` | `recerdo-permission-management` |
| `Recerdo-AdminSystem` | `recerdo-admin-system` |
| `Recerdo-SPA-Webclient` | `recerdo-spa-webclient` |
| `Recerdo-Android-Dart` | `recerdo-android-dart` |
| `recuerdo-admin-cli` | `recerdo-admin-cli` |

### Phase 2: 延期 (別 PR で対応)

内部コード参照の更新と同時に行う必要があるため、本 ADR 採択後に別途対応:

| 現在 | 計画 | 理由 |
|---|---|---|
| `Recerdo-iOS` | `recerdo-ios` | Xcode project 内の bundle identifier / 参照 URL を同時更新する必要がある |
| `Recuerdo_Backend` | `recerdo-backend` | `go.mod`, `go.work`, docker-compose, Makefile, CI 等の全 import path 更新と同時実施 |

### Phase 3: docs 全文置換 (本 PR)

docs 内の全 `recuerdo-*` 参照を `recerdo-*` に置換 (本 ADR と同じ PR に含む)。Phase 2 repo (`Recuerdo_Backend`) への参照は、repo rename と同時に別 PR で更新する。

## 運用ルール

- 新規リポ作成時は必ず本 ADR に従う
- 既存 repo の rename は、コード参照更新とセットの PR で行う
- 命名規約の変更提案は ADR を上書きせず、新 ADR (`0002-...`) として追加し本 ADR を `Superseded by` に更新する

## 参照

- Tracker: [#21 ProjectTrackerBoard](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/21)
- 関連議論: [#17 naming convention decision](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/17)
- 関連: [#14 recerdo-infra](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/14), [#20 monorepo split](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/20)
