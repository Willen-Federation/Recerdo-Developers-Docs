# ADR-0004: audit-svc を単独リポで管理

**ステータス**: Accepted
**決定日**: 2026-04-20
**決定者**: @kackey621
**関連 Issue**: [#19](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/19)

---

## コンテキスト

`recerdo-core` の description に `API Gateway, Authentication, Audit and control all services` と記載されていたため、audit が core 内包の可能性があった。一方 docs/microservice/audit-svc.md は **単独マイクロサービス** として Draft 定義されていた。

## 決定

**Option A: 単独リポ `recerdo-audit` で管理する**。

## 論拠

- **ユーザーの既成事実**: 2026-04-19 に `recerdo-audit` repo が作成済 (旧 `-recerdo-audit` を ADR-0001 準拠で rename 済)
- **障害ドメイン分離**: audit の Append-Only 不変条件・GDPR Retention 要件は、Gateway/Auth (core 内) の責務と直交する
- **スケール特性**: 監査ログの書込頻度は全サービス合計であり、core と同じ deployment 単位だと hot-spot になる
- **core の description 修正**: 「Audit」を description から削除し、Gateway + Auth のみ担う方向で更新する (別 Issue / PR で実施)

### Option B (core 内包) を不採用とする理由
- core の障害 (Gateway / Auth) が audit 書込にも波及する
- core の責務が肥大化し、マイクロサービス設計原則に反する
- audit のみ独立 Retention Policy / GDPR 対応が必要で、運用単位が合わない

## 実施アクション

- [x] `recerdo-audit` bootstrap 開始 (既に issue #1 作成済)
- [ ] `recerdo-core` repo description から "Audit" を削除 (別 chore issue で対応)
- [ ] docs/microservice/audit-svc.md のステータスを Draft → Approved に昇格
- [ ] core 側から audit-svc への QueuePort 契約を確定

## 参照

- [#19 audit-svc placement](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/19)
- [#12 audit-svc repo proposal](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/12)
- [docs/microservice/audit-svc.md](../../microservice/audit-svc.md)
- [docs/clean-architecture/audit-svc.md](../../clean-architecture/audit-svc.md)
- [ADR-0002 repo layout](0002-repo-layout-per-service.md)
