# Runbook: auth-svc

## 検知
- 認証失敗率上昇
- JWKS 取得失敗アラート

## 即時対応
1. 依存先（Cognito/JWKS）疎通確認
2. キャッシュ更新失敗ログ確認
3. 必要時に関連 Feature Flag で縮退運転

## 復旧確認
- `/healthz` 正常
- 認証 API 成功率復帰
