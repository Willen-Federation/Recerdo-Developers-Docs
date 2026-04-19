#!/usr/bin/env bash
# Recerdo ファミリーのリポジトリ群から指定時間範囲の活動を集約して Markdown を標準出力に書き出す。
#
# 必須環境変数:
#   GH_TOKEN   repo スコープ付き GitHub Personal Access Token
#
# 任意環境変数:
#   ORG        GitHub 組織名 (既定: Willen-Federation)
#   SINCE_UTC  集約開始時刻 (ISO8601, UTC)。既定: 24時間前
#   REPOS_FILE 対象リポ一覧ファイル (既定: 本スクリプトと同階層の repos.txt)
set -euo pipefail

ORG="${ORG:-Willen-Federation}"
SINCE_UTC="${SINCE_UTC:-$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="${REPOS_FILE:-${SCRIPT_DIR}/repos.txt}"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN 環境変数が必要です (repo スコープ付き PAT)" >&2
  exit 1
fi

if [ ! -f "$REPOS_FILE" ]; then
  echo "ERROR: repos.txt が見つかりません: $REPOS_FILE" >&2
  exit 1
fi

# gh api で使うトークン (既定 secrets.GITHUB_TOKEN と衝突しないよう明示)
export GH_TOKEN

fetch_paginated_array() {
  local endpoint="$1"
  gh api --paginate "$endpoint" 2>/dev/null \
    | jq -s 'map(if type == "array" then . else [] end) | add' 2>/dev/null \
    || echo '[]'
}

# 各リポの活動を集約
TOTAL_ACTIVE_REPOS=0
TOTAL_COMMITS=0
TOTAL_PRS=0
TOTAL_RELEASES=0
BODY=""

while IFS= read -r line || [ -n "$line" ]; do
  # コメント・空行スキップ
  line="${line%%#*}"
  line="${line// /}"
  [ -z "$line" ] && continue

  repo="$line"

  # デフォルトブランチ取得 (存在しないリポは警告してスキップ)
  if ! default_branch=$(gh api "repos/${ORG}/${repo}" --jq '.default_branch' 2>/dev/null); then
    echo "WARN: ${ORG}/${repo} にアクセスできません (PAT スコープまたはリポ名を確認)" >&2
    continue
  fi

  # コミット (default branch, since 範囲)
  commits_json=$(fetch_paginated_array \
    "repos/${ORG}/${repo}/commits?sha=${default_branch}&since=${SINCE_UTC}&per_page=100")

  commits_md=$(echo "$commits_json" | jq -r '
    map(select((.parents | length) < 2))
    | .[]
    | "- [`\(.sha[0:7])`](\(.html_url)) \((.commit.message | split("\n")[0]) | gsub("[\\[\\]]";"")) <sub>by @\(.author.login // .commit.author.name // "unknown")</sub>"
  ' 2>/dev/null || echo "")
  commits_count=$(echo "$commits_json" | jq 'map(select((.parents | length) < 2)) | length' 2>/dev/null || echo 0)

  # マージ済みPR
  # merged_at >= SINCE_UTC のPR
  prs_json='[]'
  pr_page=1
  while :; do
    pr_page_json=$(gh api \
      "repos/${ORG}/${repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=${pr_page}" \
      2>/dev/null || echo '[]')
    pr_page_count=$(echo "$pr_page_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "$pr_page_count" -eq 0 ]; then
      break
    fi
    prs_json=$(jq -s '.[0] + .[1]' <(echo "$prs_json") <(echo "$pr_page_json"))
    pr_oldest_updated=$(echo "$pr_page_json" | jq -r '.[-1].updated_at // empty' 2>/dev/null || true)
    if [ -n "$pr_oldest_updated" ] && [[ "$pr_oldest_updated" < "$SINCE_UTC" ]]; then
      break
    fi
    pr_page=$((pr_page + 1))
  done

  prs_md=$(echo "$prs_json" | jq -r --arg since "$SINCE_UTC" '
    map(select(.merged_at != null and .merged_at >= $since))
    | .[]
    | "- [#\(.number)](\(.html_url)) \(.title | gsub("[\\[\\]]";"")) <sub>by @\(.user.login)</sub>"
  ' 2>/dev/null || echo "")
  prs_count=$(echo "$prs_json" | jq --arg since "$SINCE_UTC" 'map(select(.merged_at != null and .merged_at >= $since)) | length' 2>/dev/null || echo 0)

  # リリース
  releases_json=$(fetch_paginated_array \
    "repos/${ORG}/${repo}/releases?per_page=100")

  releases_md=$(echo "$releases_json" | jq -r --arg since "$SINCE_UTC" '
    map(select(.published_at != null and .published_at >= $since))
    | .[]
    | "- [\(.tag_name)](\(.html_url)) \(.name // .tag_name | gsub("[\\[\\]]";""))"
  ' 2>/dev/null || echo "")
  releases_count=$(echo "$releases_json" | jq --arg since "$SINCE_UTC" 'map(select(.published_at != null and .published_at >= $since)) | length' 2>/dev/null || echo 0)

  total=$((commits_count + prs_count + releases_count))
  if [ "$total" -eq 0 ]; then
    continue
  fi

  TOTAL_ACTIVE_REPOS=$((TOTAL_ACTIVE_REPOS + 1))
  TOTAL_COMMITS=$((TOTAL_COMMITS + commits_count))
  TOTAL_PRS=$((TOTAL_PRS + prs_count))
  TOTAL_RELEASES=$((TOTAL_RELEASES + releases_count))

  BODY+=$'\n### ['"${repo}"$']('"https://github.com/${ORG}/${repo}"$')\n'

  if [ "$prs_count" -gt 0 ]; then
    BODY+=$'\n**🔀 マージ済み PR** ('"${prs_count}"$'件)\n\n'"${prs_md}"$'\n'
  fi

  if [ "$releases_count" -gt 0 ]; then
    BODY+=$'\n**🚀 リリース** ('"${releases_count}"$'件)\n\n'"${releases_md}"$'\n'
  fi

  if [ "$commits_count" -gt 0 ]; then
    BODY+=$'\n**📝 コミット** ('"${commits_count}"$'件)\n\n'"${commits_md}"$'\n'
  fi
done < "$REPOS_FILE"

# サマリ出力
echo "**サマリ**: ${TOTAL_ACTIVE_REPOS} リポで活動 (マージPR ${TOTAL_PRS} / リリース ${TOTAL_RELEASES} / コミット ${TOTAL_COMMITS})"

if [ "$TOTAL_ACTIVE_REPOS" -eq 0 ]; then
  echo ""
  echo "_この期間に活動はありませんでした。_"
else
  echo "$BODY"
fi
