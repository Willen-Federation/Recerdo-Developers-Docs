#!/usr/bin/env bash
# クローン済み Wiki リポジトリのカレントディレクトリで実行する前提。
# 日次ダイジェストファイルを受け取り、Wiki の以下を更新する:
#   - Home.md             : 初回のみスタブ作成 (既存は触らない)
#   - Changelog.md        : 先頭に当日セクションを差し込み (当日既存なら置換)
#   - Daily-YYYY-MM-DD.md : 当日の詳細ページ
#   - _Sidebar.md         : 直近30日分へのリンク一覧
#
# 必須引数:
#   $1  ダイジェスト本文の Markdown ファイルパス
#
# 必須環境変数:
#   DATE_JST  YYYY-MM-DD (JST)
#   TIME_JST  人間可読のタイムスタンプ
set -euo pipefail

DIGEST_FILE="${1:?digest file path required}"
: "${DATE_JST:?DATE_JST required}"
: "${TIME_JST:?TIME_JST required}"

if [ ! -f "$DIGEST_FILE" ]; then
  echo "ERROR: ダイジェストファイルが見つかりません: $DIGEST_FILE" >&2
  exit 1
fi

export DATE_JST TIME_JST DIGEST_FILE

# ---- Home.md: 未作成の場合のみスタブ生成 ----
if [ ! -f Home.md ]; then
  cat > Home.md <<EOF
# Recerdo Developer Docs Wiki

Recerdo ファミリーの全リポジトリの活動を自動集約する Wiki です。
設計ドキュメントは [Recerdo Developer Docs (MkDocs)](https://github.com/Willen-Federation/Recerdo-Developers-Docs) を参照してください。

## 目次

- [活動ログ (Changelog)](Changelog) — 直近の更新まとめ (自動生成)
- サイドバーに直近30日分の日次ダイジェストへのリンクを表示しています
EOF
fi

# ---- Daily-YYYY-MM-DD.md: 当日の詳細ページ ----
{
  echo "# ${DATE_JST} の活動ダイジェスト"
  echo ""
  echo "最終更新: ${TIME_JST}"
  echo ""
  cat "$DIGEST_FILE"
  echo ""
  echo "---"
  echo ""
  echo "_このページは GitHub Actions \`wiki-sync\` により自動生成されています。_"
} > "Daily-${DATE_JST}.md"

# ---- Changelog.md: 先頭に当日セクションを差し込み + 当日重複は置換 + 直近90件に制限 ----
python3 <<'PYEOF'
import os, re, pathlib

date_jst = os.environ["DATE_JST"]
time_jst = os.environ["TIME_JST"]
digest_body = pathlib.Path(os.environ["DIGEST_FILE"]).read_text(encoding="utf-8")

header = f"""# 活動ログ (Auto-generated Changelog)

Recerdo ファミリーの全リポジトリの活動 (コミット・マージ済み PR・リリース) を毎日 9:00 JST に自動集約しています。

最終更新: {time_jst}

各日付の詳細は `Daily-YYYY-MM-DD` ページを参照してください (サイドバー経由で遷移可)。

---
"""

today_section = f"""## [{date_jst}](Daily-{date_jst})

{digest_body.rstrip()}
"""

path = pathlib.Path("Changelog.md")
if path.exists():
    content = path.read_text(encoding="utf-8")
    # ヘッダを除去: 最初の "---\n" より後を本文とする (無ければ全体を本文とみなす)
    parts = content.split("\n---\n", 1)
    body = parts[1] if len(parts) == 2 else content

    # 日付セクションで分割
    pattern = re.compile(r"^## \[(\d{4}-\d{2}-\d{2})\]", flags=re.MULTILINE)
    matches = list(pattern.finditer(body))

    sections = []
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
        section_date = m.group(1)
        section_text = body[start:end].rstrip() + "\n"
        sections.append((section_date, section_text))

    # 当日の既存セクションを除外
    sections = [(d, t) for (d, t) in sections if d != date_jst]

    # 当日を先頭に追加
    sections.insert(0, (date_jst, today_section.rstrip() + "\n"))

    # 直近90件に制限
    sections = sections[:90]

    new_body = "\n".join(t for _, t in sections)
else:
    new_body = today_section

path.write_text(header + "\n" + new_body + "\n", encoding="utf-8")
PYEOF

# ---- _Sidebar.md: 直近30日の Daily ページへのリンクを一覧化 ----
python3 <<'PYEOF'
import pathlib

daily_pages = sorted(
    [p for p in pathlib.Path(".").glob("Daily-*.md")],
    key=lambda p: p.stem,
    reverse=True,
)[:30]

lines = [
    "## 📚 固定ページ",
    "",
    "- [Home](Home)",
    "- [活動ログ (Changelog)](Changelog)",
    "",
    "## 📅 日次ダイジェスト (直近30日)",
    "",
]
for p in daily_pages:
    date = p.stem.replace("Daily-", "")
    lines.append(f"- [{date}]({p.stem})")

pathlib.Path("_Sidebar.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
PYEOF
