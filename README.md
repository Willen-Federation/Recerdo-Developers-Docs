# Netlify デプロイ手順

Recerdo Developer Docs を Netlify に公開するための手順書です。

**対象サイト**: `recerdo-developers-docs` (ID: `27ce33ac-e298-4d62-a01b-d10319734e49`)  
**URL**: https://recerdo-developers-docs.netlify.app

---

## 方法 A: ドラッグ&ドロップ（最速・手動）

1. https://app.netlify.com/projects/recerdo-developers-docs にアクセス
2. 「Deploys」タブを開く
3. `recerdo-site-deploy.zip` をドラッグ&ドロップ
4. デプロイ完了（約30秒）

---

## 方法 B: Netlify CLI（ターミナルから）

```bash
# Netlify CLIインストール（未インストールの場合）
npm install -g netlify-cli

# ログイン
netlify login

# デプロイ（このディレクトリで実行）
cd recerdo-docs
./deploy.sh <YOUR_NETLIFY_AUTH_TOKEN>
```

Personal Access Token の取得: https://app.netlify.com/user/applications#personal-access-tokens

---

## 方法 C: GitHub連携による自動デプロイ（推奨）

GitHubにプッシュするたびに自動デプロイされる設定です。

### Step 1: GitHubにプッシュ

```bash
cd recerdo-docs
git init
git add .
git commit -m "Add MkDocs Material documentation site"
git remote add origin https://github.com/Willen-Federation/Recerdo-Developers-Docs.git
git push -u origin main
```

### Step 2: Netlifyで連携設定

1. https://app.netlify.com/projects/recerdo-developers-docs → Site settings → Build & deploy
2. 「Link site to Git」をクリック
3. GitHub → `Willen-Federation/Recerdo-Developers-Docs` を選択
4. 以下を設定:
   - **Build command**: `pip install -r requirements.txt && mkdocs build`
   - **Publish directory**: `site`
   - **Python version**: `3.11`（Environment variables: `PYTHON_VERSION=3.11`）

---

## ビルドコマンド（参考）

```bash
# ローカルでビルド
pip install -r requirements.txt
mkdocs build

# ローカルプレビュー（ポート8000）
mkdocs serve
```
