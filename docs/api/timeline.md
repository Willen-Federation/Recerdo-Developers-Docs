# Timeline API

`recuerdo-timeline-svc` が提供するタイムライン・フィード取得APIです。

---

## ユーザータイムライン

### GET `/api/users/{user_id}/timeline`

指定ユーザーのタイムラインを取得します。

**クエリパラメータ**

| パラメータ | 型 | 説明 |
|---------|---|------|
| `limit` | int | 取得件数（デフォルト20） |
| `cursor` | string | カーソルベースページネーション |
| `from` | datetime | 取得開始日時（ISO 8601） |
| `to` | datetime | 取得終了日時（ISO 8601） |

=== "Response 200"

    ```json
    {
      "data": {
        "items": [
          {
            "timeline_item_id": "tli_01JXXXXXXXXX",
            "type": "event_created",
            "actor_id": "usr_01JXXXXXXXXX",
            "actor_name": "田中 花子",
            "ref_type": "event",
            "ref_id": "evt_01JXXXXXXXXX",
            "summary": "「2026年 同窓会」が作成されました",
            "created_at": "2026-04-14T00:00:00Z"
          },
          {
            "timeline_item_id": "tli_02JXXXXXXXXX",
            "type": "album_updated",
            "actor_id": "usr_02JXXXXXXXXX",
            "actor_name": "鈴木 次郎",
            "ref_type": "album",
            "ref_id": "alb_01JXXXXXXXXX",
            "summary": "アルバムに5枚の写真が追加されました",
            "created_at": "2026-04-13T22:00:00Z"
          }
        ],
        "next_cursor": "cursor_01JXXXXXXXXX",
        "has_more": true
      }
    }
    ```

---

## 組織タイムライン

### GET `/api/orgs/{org_id}/timeline`

組織全体のタイムラインを取得します。

パラメータ・レスポンス形式はユーザータイムラインと同様。

---

## ユーザーフィード

### GET `/api/users/me/feed`

ログインユーザーのパーソナライズフィードを取得します。  
フォローしている組織・友人のアクティビティを時系列で表示します。

---

## タイムラインアイテム種別

| `type` | 説明 |
|--------|------|
| `event_created` | イベントが作成された |
| `event_activated` | イベントがアクティブ化された |
| `album_created` | アルバムが作成された |
| `album_updated` | アルバムに写真が追加された |
| `media_uploaded` | メディアがアップロードされた |
| `member_joined` | メンバーが参加した |
| `reaction_added` | リアクションが追加された |
| `comment_posted` | コメントが投稿された |

---

## 内部API（サービス間通信）

!!! warning "Internal Use Only"
    以下のエンドポイントはサービス間通信専用です。外部クライアントからの呼び出し不可。

### POST `/api/timeline`

タイムラインアイテムを作成します（他サービスからの呼び出し）。

### DELETE `/api/timeline/{timeline_item_id}`

タイムラインアイテムを非表示にします。

---

## ファンアウト基盤

Timeline Service は他サービス（Events / Album / Storage / Reactions）からのイベントをキュー経由で受信し、フィードに集約します。

| 環境 | キュー | 永続化 |
| --- | --- | --- |
| Beta | Redis + BullMQ / asynq | MySQL（MariaDB互換） |
| 本番 | OCI Queue | OCI MySQL HeatWave |

キャッシュは Redis（Beta: 自前 / 本番: OCI Cache with Redis）を利用します。AWS サービスへの依存はありません（認証の Cognito を除く）。

---

最終更新: 2026-04-19 ポリシー適用
