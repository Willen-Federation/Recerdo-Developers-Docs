# サービス間タイムアウト標準

| 経路 | 推奨値 | 備考 |
|---|---|---|
| Gateway → Backend gRPC | 3s | ユーザー体感優先 |
| Backend ↔ Backend gRPC | 1s | 連鎖遅延を抑止 |
| Outbox Publisher → Queue | 5s | 再試行前提 |
| Cognito JWKS Fetch | 500ms | キャッシュ併用 |
| FCM / 外部通知 API | 3s | Circuit Breaker 併用 |

## 共通ルール
- タイムアウト超過はメトリクス化し SLO 監視対象とする。
- 再試行は指数バックオフ + ジッターで実装する。
