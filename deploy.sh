#!/usr/bin/env bash
# ============================================================
# Recerdo Developer Docs — Netlify Deploy Script
# Usage: ./deploy.sh <NETLIFY_AUTH_TOKEN>
# ============================================================
set -e

SITE_ID="27ce33ac-e298-4d62-a01b-d10319734e49"
SITE_NAME="recerdo-developers-docs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$1" ]; then
  echo "Usage: ./deploy.sh <NETLIFY_AUTH_TOKEN>"
  echo ""
  echo "Token取得: https://app.netlify.com/user/applications#personal-access-tokens"
  exit 1
fi

NETLIFY_AUTH_TOKEN="$1"

echo "📦 MkDocsをビルド中..."
pip install -r "$SCRIPT_DIR/requirements.txt" -q
cd "$SCRIPT_DIR"
mkdocs build

echo "🚀 Netlifyにデプロイ中 (site: $SITE_NAME)..."
npx -y netlify-cli deploy \
  --auth "$NETLIFY_AUTH_TOKEN" \
  --site "$SITE_ID" \
  --dir "$SCRIPT_DIR/site" \
  --prod \
  --message "MkDocs Material deploy $(date '+%Y-%m-%d %H:%M')"

echo ""
echo "✅ デプロイ完了！"
echo "🌐 URL: https://$SITE_NAME.netlify.app"
