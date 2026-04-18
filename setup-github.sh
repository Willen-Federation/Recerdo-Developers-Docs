#!/usr/bin/env bash
# ============================================================
# Recerdo Developer Docs — GitHub + Netlify 自動デプロイ セットアップ
# ============================================================
# 必要なもの:
#   - GitHub PAT (Fine-grained: contents:write + secrets:write)
#     取得: https://github.com/settings/personal-access-tokens
#   - Netlify Personal Access Token
#     取得: https://app.netlify.com/user/applications#personal-access-tokens
#
# 使い方:
#   chmod +x setup-github.sh
#   ./setup-github.sh <GITHUB_PAT> <NETLIFY_AUTH_TOKEN>
# ============================================================
set -e

GITHUB_PAT="${1:-$GITHUB_PAT}"
NETLIFY_TOKEN="${2:-$NETLIFY_AUTH_TOKEN}"

REPO="Willen-Federation/Recerdo-Developers-Docs"
NETLIFY_SITE_ID="27ce33ac-e298-4d62-a01b-d10319734e49"
BRANCH="main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 引数チェック ──────────────────────────────────────────
if [ -z "$GITHUB_PAT" ]; then
  echo "❌ GitHub PAT が必要です"
  echo "   Usage: ./setup-github.sh <GITHUB_PAT> <NETLIFY_AUTH_TOKEN>"
  echo "   PAT取得: https://github.com/settings/personal-access-tokens"
  echo "   必要なパーミッション: Contents=Read/Write, Secrets=Read/Write"
  exit 1
fi

if [ -z "$NETLIFY_TOKEN" ]; then
  echo "❌ Netlify Auth Token が必要です"
  echo "   取得: https://app.netlify.com/user/applications#personal-access-tokens"
  exit 1
fi

echo ""
echo "🚀 Recerdo Developer Docs — GitHub 自動デプロイ セットアップ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 リポジトリ: https://github.com/${REPO}"
echo "🌐 Netlify   : https://recerdo-developers-docs.netlify.app"
echo ""

# ── Step 1: git 初期化 ────────────────────────────────────
echo "📁 Step 1/4: Git リポジトリを初期化中..."
cd "$SCRIPT_DIR"

if [ ! -d ".git" ]; then
  git init
  git checkout -b "$BRANCH"
  echo "   ✅ git init 完了"
else
  echo "   ℹ️  既存の git リポジトリを使用"
fi

# ── Step 2: 初回コミット ──────────────────────────────────
echo ""
echo "📝 Step 2/4: コミット作成中..."
git config user.email "a.kusama@private.willen.jp" 2>/dev/null || true
git config user.name "Akira Kusama" 2>/dev/null || true
git add -A

if git diff --cached --quiet; then
  echo "   ℹ️  変更なし — 既存コミットを使用"
else
  git commit -m "feat: Add MkDocs Material documentation site

- API Reference (Auth/Events/Album/Storage/Timeline/Audit)
- Microservice Design Documents (6 services)
- Clean Architecture Design Documents (7 services)
- Netlify auto-deploy via GitHub Actions
- 3-tab navigation with Material theme"
  echo "   ✅ コミット完了"
fi

# ── Step 3: GitHub へプッシュ ─────────────────────────────
echo ""
echo "⬆️  Step 3/4: GitHub へプッシュ中..."
REMOTE_URL="https://x-access-token:${GITHUB_PAT}@github.com/${REPO}.git"

if git remote get-url origin &>/dev/null; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

git push -u origin "$BRANCH" --force
echo "   ✅ プッシュ完了: https://github.com/${REPO}/tree/${BRANCH}"

# ── Step 4: GitHub Secrets を設定 ────────────────────────
echo ""
echo "🔑 Step 4/4: GitHub Secrets を設定中..."

# gh CLI が使えるか確認
if command -v gh &>/dev/null; then
  export GH_TOKEN="$GITHUB_PAT"

  gh secret set NETLIFY_AUTH_TOKEN \
    --repo "$REPO" \
    --body "$NETLIFY_TOKEN"
  echo "   ✅ NETLIFY_AUTH_TOKEN を設定"

  gh secret set NETLIFY_SITE_ID \
    --repo "$REPO" \
    --body "$NETLIFY_SITE_ID"
  echo "   ✅ NETLIFY_SITE_ID を設定 (${NETLIFY_SITE_ID})"

else
  # gh CLI がない場合は GitHub API を直接使用
  echo "   gh CLI が見つかりません。GitHub API で設定します..."

  # Public key を取得
  KEY_RESPONSE=$(curl -sS \
    -H "Authorization: token $GITHUB_PAT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/secrets/public-key")

  KEY_ID=$(echo "$KEY_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['key_id'])")
  PUBLIC_KEY=$(echo "$KEY_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['key'])")

  # libsodium で暗号化して登録
  python3 - <<PYEOF
import base64, json
from nacl import encoding, public

def encrypt_secret(public_key_b64, secret_value):
    pk = public.PublicKey(public_key_b64.encode(), encoding.Base64Encoder())
    box = public.SealedBox(pk)
    encrypted = box.encrypt(secret_value.encode())
    return base64.b64encode(encrypted).decode()

# PyNaCl がなければインストール
try:
    from nacl import encoding, public
except ImportError:
    import subprocess
    subprocess.run(["pip", "install", "PyNaCl", "--break-system-packages", "-q"], check=True)
    from nacl import encoding, public

pub_key = "$PUBLIC_KEY"
key_id = "$KEY_ID"

secrets = {
    "NETLIFY_AUTH_TOKEN": "$NETLIFY_TOKEN",
    "NETLIFY_SITE_ID": "$NETLIFY_SITE_ID"
}

import urllib.request, urllib.error
for name, value in secrets.items():
    encrypted = encrypt_secret(pub_key, value)
    payload = json.dumps({"encrypted_value": encrypted, "key_id": key_id}).encode()
    req = urllib.request.Request(
        f"https://api.github.com/repos/$REPO/actions/secrets/{name}",
        data=payload,
        headers={
            "Authorization": "token $GITHUB_PAT",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
        method="PUT"
    )
    try:
        resp = urllib.request.urlopen(req)
        print(f"   ✅ {name} を設定しました")
    except urllib.error.HTTPError as e:
        print(f"   ❌ {name} の設定に失敗: {e.code} {e.reason}")
PYEOF
fi

# ── 完了 ─────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップ完了！"
echo ""
echo "🔄 自動デプロイの流れ:"
echo "   git push → GitHub Actions 起動 → MkDocs ビルド → Netlify デプロイ"
echo ""
echo "📊 Actions ログ確認:"
echo "   https://github.com/${REPO}/actions"
echo ""
echo "🌐 サイトURL:"
echo "   https://recerdo-developers-docs.netlify.app"
echo ""
echo "📋 今後のデプロイ方法:"
echo "   git add . && git commit -m 'docs: update' && git push"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
