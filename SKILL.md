# SKILL.md - Code Quality Guidelines

Recerdo プロジェクト全体における高品質なコード生成と開発の指針を定めています。

## 1. 実装プロセスと設計

- **要件分解**: 要件を最小単位のタスクに分解し、アーキテクチャ設計を明確化
- **フレームワーク選定**: 最新LTS版フレームワークを採用。1年以上更新のないOSSは使用禁止
- **言語慣習**: Idiomatic Code（言語固有の慣習に従ったコード）と英語コメントを徹底
- **大規模開発ベストプラクティス**: スケーラブルで保守性の高いコード設計

## 2. 品質保証とCI/CD

### 例外処理
- 網羅的な例外処理を実装し、エラー時の原因特定を容易に
- スタックトレース、コンテキスト情報を含む詳細なログ出力

### テストケース
- 正常系（Happy Path）、異常系（Error Cases）、エッジケースをカバー
- GitHub Actions等でテストがパスするまで自己検証ループを実行

### コード品質
- ESLint等の標準フォーマッタで統一的に整形
- Pre-commit hooks で自動チェック
- CI/CDパイプラインで品質ゲートを設定

## 3. セキュリティ

- **OWASP Top 10** を遵守（Injection、XSS、CSRF、認証脆弱性等）
- **CVE・CWE** への対応と監視
- **Nデイ攻撃**、**意図しない外部接続**、**権限奪取**等の脆弱性を徹底排除
- **Dependency Scanning**: サプライチェーン攻撃への防御
- **Secret Scanning**: 認証情報の漏洩防止

## 4. 成果物（出力形式）

### Code
- フォーマット済みのソースコード一式
- 適切なファイル構成と命名規則
- IDEで即座に実行可能な状態

### CI/CD
- GitHub Workflow ファイル（.github/workflows/）
- テスト、ビルド、デプロイ パイプラインの自動化
- ブランチ保護ルール、コードレビュー必須化

### Documentation
- **README.md**: セットアップ、環境変数、最小スペック、ビルド手順、保守ドキュメント
- **CONTRIBUTING.md**: 貢献ガイドライン
- **ARCHITECTURE.md**: システム設計図（必要に応じて）

## 5. 制約と注意事項

- **不明点への対応**: 不明確な点は、プロンプト実行者に質問してから実装
- **自動実行モード時**: 大規模開発案件を複数検索、候補を検討
  - 選定基準: 近似度、保守性、設計難易度、可読性
- **過度な抽象化を避ける**: 必要なレベルの設計に留める
- **テスト駆動開発（TDD）**: 実装前にテストケースを定義

## 適用対象

このガイドラインは、Recerdo プロジェクトの全レポジトリに適用されます：

- Backend Services (Go, Node.js)
- Frontend Applications (TypeScript, Dart)
- Infrastructure & DevOps (Terraform, Bash)
- Shared Libraries & Protocol Buffers
- Documentation & Developer Experience
