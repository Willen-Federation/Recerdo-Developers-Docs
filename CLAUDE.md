# CLAUDE.md - Recerdo Developers Documentation

プロジェクト概要、開発環境、テスト方法、品質基準を定めています。

## プロジェクト概要

**Recerdo Developers Documentation** は、Recerdo プロジェクト全体の開発ドキュメント・リファレンスを統一的に管理するリポジトリです。

- **言語**: Markdown, Python (MkDocs)
- **ビルドツール**: MkDocs
- **ホスティング**: Netlify
- **対象読者**: エンジニア、デザイナー、プロダクトマネージャー

## 環境構築

### 必須要件
- Python 3.9 以上
- pip

### セットアップ手順

```bash
# リポジトリのクローン
git clone https://github.com/Willen-Federation/Recerdo-Developers-Docs.git
cd Recerdo-Developers-Docs

# 仮想環境の作成
python3 -m venv venv
source venv/bin/activate  # Linux/macOS
# または
venv\Scripts\activate  # Windows

# 依存関係のインストール
pip install -r requirements.txt
```

## ドキュメント執筆

### ローカル プレビュー

```bash
mkdocs serve
```

ブラウザで http://localhost:8000 にアクセスしてプレビュー

### ドキュメント構造

```
docs/
├── index.md          # ホームページ
├── getting-started/  # チュートリアル
├── architecture/     # アーキテクチャ設計
├── api-reference/    # API リファレンス
├── deployment/       # デプロイメント
└── troubleshooting/  # トラブルシューティング
```

### 執筆ガイドライン

1. **Markdown形式**: GitHub Flavored Markdown (GFM)
2. **言語**: 日本語/英語（プロジェクト方針に準ずる）
3. **構成**: 明確なヘッダー、コード例、スクリーンショット
4. **メンテナンス性**: リンクは相対パスで指定、外部リンクは定期確認

## ビルドとデプロイ

### ローカル ビルド

```bash
mkdocs build
```

`site/` ディレクトリに静的サイトが生成されます

### 本番環境へのデプロイ

Netlify の自動デプロイ (`deploy.sh` 参照):

```bash
./deploy.sh
```

## テストと品質チェック

### リンク確認

```bash
# 外部リンクの確認（必要に応じて別ツール使用）
mkdocs build && linkchecker site/
```

### ドキュメント品質

- **一貫性**: 用語、スタイル、フォーマットの統一
- **可読性**: 適切な見出し、短い段落、リスト形式
- **更新性**: 古い情報の定期確認・更新

## GitHub Actions CI/CD

`.github/workflows/` に以下のワークフローを実装:

- **build-and-test**: MkDocs ビルド成功確認
- **deploy**: main ブランチへのマージで自動デプロイ

## .env ファイル

ローカル開発時に必要な環境変数（例）:

```env
# なし（MkDocsの場合、通常は環境変数不要）
```

## トラブルシューティング

### ビルドエラー

```bash
# 仮想環境の再構築
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## コード品質基準

- **SKILL.md** を参照
- ドキュメントは英語で記述（国際的な読者対応）
- マークダウン構文の検証（markdownlint）
- 外部リンクの定期確認

## 貢献ガイドライン

1. フィーチャーブランチを作成
2. ドキュメント執筆 → ローカルテスト
3. Pull Request 作成
4. コードレビュー ✓
5. Merge → 自動デプロイ

## 連絡先・質問

ドキュメント改善に関する質問は GitHub Issues で報告してください。
