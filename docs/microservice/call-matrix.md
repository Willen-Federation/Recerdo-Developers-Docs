# サービス間呼び出し 同期/非同期マトリクス

**参照**: `policy.md §4.2, §8.5, §8.6, §8.9` · `environment-abstraction.md §4.3`  
**最終更新**: 2026-04-24

## 判断基準

| 基準 | 同期 gRPC | 非同期 Outbox |
|---|---|---|
| ユーザー応答待ち | ✅ | ❌ |
| 認可/認証判定 | ✅ | ❌ |
| 長時間処理 (>1s) | ❌ | ✅ |
| Saga Choreography | ❌ | ✅ |
| 監査・ログ (auxiliary path) | ❌ | ✅ |

## 主要呼び出しマトリクス

| 呼び出し元 | 呼び出し先 | 方式 | 同期/非同期 | SLO | 判断理由 |
|---|---|---|---|---|---|
| client | api-gateway | HTTP/REST | 同期 | p99 < 500ms | ユーザー応答を即時返却 |
| api-gateway | permission-svc | gRPC | 同期 | p99 < 50ms | 認可結果がないと処理継続できない |
| api-gateway | core-svc | gRPC | 同期 | p99 < 200ms | ユーザー操作応答 |
| api-gateway | event-svc | gRPC | 同期 | p99 < 200ms | イベント作成応答 |
| api-gateway | storage-svc (presigned-url) | gRPC | 同期 | p99 < 100ms | 署名 URL を即時返す |
| api-gateway | feature-flag-svc | gRPC | 同期 | p99 < 30ms | フラグ評価 |
| storage-svc | queue-port | Outbox Event | 非同期 | 60s SLO | MediaUploaded Saga §8.5 |
| media-transcoder ← Outbox | storage-svc | Worker | 非同期 | 数分 | HLS/HEIC 変換、CPU高負荷 |
| timeline-svc ← event-svc | event-subscription | Outbox | 非同期 | 5s SLO | Saga Choreography §8.6 |
| album-svc ← storage-svc | event-subscription | Outbox | 非同期 | 60s SLO | MemoryPublished Saga §8.6 |
| notifications-svc ← album-svc | event-subscription | Outbox | 非同期 | 60s SLO | Push通知 §8.9 |
| notifications-svc ← event-svc | event-subscription | Outbox | 非同期 | 60s SLO | イベント招待通知 |
| audit-svc ← 全svc | AuditEvent | Outbox | 非同期 | best-effort | 監査は auxiliary path §4.3 |
| admin-system → core-svc | gRPC | 同期 | p99 < 500ms | 管理操作応答 |
| admin-system → audit-svc | gRPC | 同期 | p99 < 200ms | 監査ログ即時取得 |

## Saga フロー詳細 (§8.6)

### MediaUpload Saga
```
Client → api-gateway → storage-svc (gRPC 同期)
  → storage-svc publishes MediaUploaded (Outbox)
    → media-transcoder: HLS/HEIC 変換
    → album-svc: AlbumEntry 作成
    → notifications-svc: push 通知
    → audit-svc: UploadAction ログ
```

### EventCreation Saga
```
Client → api-gateway → event-svc (gRPC 同期)
  → event-svc publishes EventCreated (Outbox)
    → timeline-svc: フィード追加
    → notifications-svc: 招待通知
    → audit-svc: CreateEvent ログ
```

## Contract Test 戦略

### Level 1 (実装済み): buf breaking
Proto 破壊的変更を PR で自動検出。`.github/workflows/proto.yml` 参照。

### Level 2 (推奨): Prism Mock
```bash
npx @stoplight/prism-cli mock docs/api/openapi-template.yaml --port 4010
```
Consumer 側 integration test で `localhost:4010` に向けて HTTP リクエストを送信。

### Level 3 (M2 予定): Pact
Consumer-Driven Contract Test。Consumer が Pact ファイルを生成し、Provider が検証。

## Synthetic 監視 (本番)

| チェック | 間隔 | アラート閾値 |
|---|---|---|
| `GET api.recerdo.app/health` | 30s | 2回連続失敗 |
| `POST /api/v1/events` E2E | 5min | p99 > 2s |
| `GET /api/v1/timeline` E2E | 5min | p99 > 1s |
| Media upload → presigned → S3 | 15min | 失敗 |

設定: Grafana Synthetic Monitoring (recerdo-infra observability stack)
