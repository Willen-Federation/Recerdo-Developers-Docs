# Database Migration Playbook

## 適用方針
- 原則: forward-only migration
- 小規模変更: 通常 migration
- 大規模変更（大テーブル・ロック懸念）: online schema migration を使用

## Expand-Migrate-Contract
1. Expand: 互換性を維持した追加
2. Migrate: 新旧互換の読み書き
3. Contract: 旧構造の削除

## 実施ガード
- 互換期間を設定し、段階的に切替える。
- 失敗時は即時ロールフォワード用修正を適用する。
- MySQL / MariaDB 互換性検証を CI で実施する。
