# Wiki Auto Sync

Recerdo ファミリーの全リポジトリのコミット・マージ済み PR・リリース情報を、毎朝 9:00 JST に自動集約して、本リポジトリの [GitHub Wiki](https://github.com/Willen-Federation/Recerdo-Developers-Docs/wiki) に反映します。

## 動作概要

1. `scripts/wiki-sync/repos.txt` に列挙された Recerdo リポジトリ群を対象に、直近 24 時間の活動を取得
2. マージ済み PR / リリース / コミット (マージコミット除く) を Markdown に整形
3. Wiki をクローンし、以下のページを自動更新:
   - `Home.md` — 初回のみスタブを作成 (以降は人間編集優先)
   - `Changelog.md` — 当日セクションを先頭に差し込み (既存当日分は置換、直近90件を保持)
   - `Daily-YYYY-MM-DD.md` — 当日の詳細ページ
   - `_Sidebar.md` — 直近 30 日分のリンク一覧
4. Wiki にコミット & push

## 事前設定 (初回のみ)

### 1. Wiki の初期化

GitHub Wiki は最初の 1 ページが Web UI 経由で作成されるまで、`.wiki.git` が存在しません。以下から最初のページ (例: `Home`) を作成してください:

<https://github.com/Willen-Federation/Recerdo-Developers-Docs/wiki/_new>

内容は空でも `Welcome` のような短文でも可。workflow は以降 `Home.md` に手を加えません (スタブ作成は未存在時のみ)。

### 2. PAT (Personal Access Token) の登録

Recerdo 配下の非公開リポを読み取り、Wiki を push するために、repo スコープ付き PAT をリポジトリシークレットに登録します。

**Classic PAT (推奨: 簡易)**
- <https://github.com/settings/tokens/new>
- スコープ: `repo` (フル)
- Resource owner: `Willen-Federation` (SSO 認可)
- 有効期限: 必要に応じて (最長 1 年 or 無期限)

**Fine-grained PAT (推奨: セキュア)**
- <https://github.com/settings/personal-access-tokens/new>
- Resource owner: `Willen-Federation`
- Repository access: `repos.txt` に列挙した全リポ
- Repository permissions:
  - `Contents`: Read and write (Wiki push のため)
  - `Metadata`: Read
  - `Pull requests`: Read
  - `Administration`: Read (※ Wiki のため必要な場合あり)

取得したトークンをシークレットに登録:
- リポジトリ: `Willen-Federation/Recerdo-Developers-Docs`
- Settings → Secrets and variables → Actions → **New repository secret**
- Name: `WIKI_SYNC_TOKEN`
- Secret: (コピーした PAT)

### 3. 初回実行 (テスト)

Actions タブから `Wiki Auto Sync` を選び、**Run workflow** で手動実行:

<https://github.com/Willen-Federation/Recerdo-Developers-Docs/actions/workflows/wiki-sync.yml>

成功すると Wiki に `Daily-YYYY-MM-DD`, `Changelog`, `_Sidebar` などが反映されます。

## ローカル検証 (任意)

```bash
# PAT を環境変数で渡して、標準出力にダイジェストを出す
export GH_TOKEN=ghp_xxxxx
export ORG=Willen-Federation
export SINCE_UTC=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)  # macOS
# export SINCE_UTC=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)  # Linux
bash scripts/wiki-sync/generate-digest.sh
```

## 対象リポの追加・削除

[`repos.txt`](repos.txt) を編集して PR。`#` 始まりはコメント、空行はスキップ。

## トラブルシューティング

| 症状 | 原因・対応 |
|------|-----------|
| `WIKI_SYNC_TOKEN が未設定` | リポジトリシークレット `WIKI_SYNC_TOKEN` を登録 |
| `Repository not found` (clone 時) | Wiki が未初期化。GitHub Web UI で最初のページを手動作成 |
| 特定リポで `403 / 404` 警告 | PAT のスコープ・SSO 認可を確認 (organization 選択) |
| `main`/`master` 以外のデフォルトブランチが無視される | `generate-digest.sh` は API から `default_branch` を動的取得するので基本問題なし |
| Wiki に更新が出ない | 直近 24h に該当リポで活動が無い場合は "活動なし" 扱いで差分無しコミットをスキップ |

## スケジュール変更

`.github/workflows/wiki-sync.yml` の `schedule.cron` を編集。
- 毎朝 9:00 JST: `0 0 * * *` (UTC 00:00)
- 毎週月曜 9:00 JST: `0 0 * * 1`
- 毎時: `0 * * * *`
