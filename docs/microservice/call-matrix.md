# サービス間呼び出し 同期/非同期マトリクス

| 呼び出し元 | 呼び出し先 | 方式 | 同期/非同期 | 判断理由 |
|---|---|---|---|---|
| client | api-gateway | HTTP | 同期 | ユーザー応答を即時返却する必要がある |
| api-gateway | permission-svc | gRPC | 同期 | 認可結果がないと処理継続できない |
| api-gateway | storage-svc (presigned-url) | gRPC | 同期 | 署名 URL を即時返す必要がある |
| storage-svc | queue-port | Outbox Event | 非同期 | 変換処理はバックグラウンド実行 |
| media-transcoder | storage-svc | Event/Worker | 非同期 | CPU 高負荷処理のため分離 |
| album-svc | timeline-svc | Domain Event | 非同期 | Saga Choreography で連携 |
| album-svc | notifications-svc | Domain Event | 非同期 | 通知は遅延許容の非同期処理 |
| 全サービス | audit-svc | Audit Event | 非同期 | 監査は補助経路で業務処理をブロックしない |

## 判断基準
- 同期: ユーザー応答・認可判定など、処理継続に即時結果が必要。
- 非同期: 受付完了後に遅延実行できる処理（Outbox 経由）。
