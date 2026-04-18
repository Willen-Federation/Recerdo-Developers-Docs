# コアプラットフォーム

Recerdo のインフラストラクチャ、運用計画、セキュリティに関する横断的なアーキテクチャドキュメントです。

## ドキュメント一覧

| ドキュメント | 概要 |
|---|---|
| [デプロイメント戦略](deployment-strategy.md) | Beta（セルフホストVPS+レンタル）→ 本番（OCIファースト）への移行戦略・マルチクラウド設計 |
| [環境抽象化 & Feature Flag](environment-abstraction.md) | ハードコード排除・環境変数/Feature Flag/アダプタの3層切替設計 |
| [コストパフォーマンス分析](cost-performance-analysis.md) | Firebase / AWS / セルフホスト比較、PoC/Beta向けコスト最適化 |
| [PoC/Beta スコープ定義](poc-beta-scope.md) | バイブコーディングで実現可能なMVP機能セット |
| [サーバーキャパシティ計画](server-capacity-planning.md) | マイクロサービスのリソース見積もり・スケーリング戦略 |
| [ファイアウォール & データプロテクション](firewall-data-protection.md) | ネットワークセキュリティ・WAF・暗号化・DDoS対策 |
