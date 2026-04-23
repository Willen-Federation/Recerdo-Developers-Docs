# Runbook: notifications-svc

## 検知
- 配信キュー滞留
- FCM / SMTP エラー率上昇

## 即時対応
1. Queue 消費状況確認
2. 外部依存（FCM / SMTP）疎通確認
3. 必要時に通知送信を一時的に制限

## 復旧確認
- 滞留件数が閾値以下
- 配信成功率が通常値へ復帰
