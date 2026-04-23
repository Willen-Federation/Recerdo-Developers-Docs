# TDD Red-Green プロセス

## 1. 基本フロー
1. Red: 先に失敗するテストを書く。
2. Green: 最小実装でテストを通す。
3. Refactor: 振る舞いを変えずに改善する。

## 2. PR 添付必須証跡
- Red log（修正前 FAIL）
- Green log（修正後 PASS）
- Coverage（Line / Branch）

## 3. 空テスト禁止ゲート
以下を CI で検出して fail とする。
- Skip 系（`t.Skip`, `it.skip`, `xdescribe` など）
- 空のテスト本体
- 恒真アサーションのみのテスト

## 4. 週次ミューテーションテスト
- Go: go-mutesting
- TypeScript: Stryker
- Survivor 率が閾値を超えた場合は改善 Issue を起票する。

## 5. AI エージェント適用ルール
- Red/Green/Coverage の 3 点が欠ける PR を完了扱いにしない。
- 新規実装で Red を省略する場合は理由を明記する。
