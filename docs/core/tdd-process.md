# TDD Red→Green プロセス

> **ステータス**: Accepted  
> **版**: v1.0 (2026-04-22)  
> **適用範囲**: Willen-Federation org 配下の Recerdo 関連全リポジトリ  
> **出典**: [Issue #41](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/41), オーケストレーター決定 (2026-04-20)

---

## 1. 概要

Recerdo プロジェクトでは **Test-Driven Development (TDD)** を全 PR の必須プロセスとして採用する。  
「テストが PASS した」だけでは不十分 — **失敗 (Red) → 実装 (Green) → リファクタ (Refactor)** の証跡が全 PR に必須となる。

### なぜ TDD を強制するか

1. **AIエージェントの虚偽 Done 防止**: `go test ./... | grep PASS` のみで Done 判定される「動作していないのにパスを出す」リスクを排除する
2. **空テスト・スキップテストのゼロ tolerance**: 実際に動作を検証しないテストコードの混入を構造的に防ぐ
3. **カバレッジの意味的保証**: 数値達成ではなく「意味のある検証」を強制する

---

## 2. Red-Green-Refactor の 3 ステップ

```
Step 1: RED (先行テスト実装)
  ├── 実装コードを書く前にテストを書く
  ├── go test ./... を実行
  ├── FAIL ログを確認・記録
  └── GitHub Actions パーマリンクを取得

Step 2: GREEN (実装 → テスト通過)
  ├── テストを通過させる最小限の実装を行う
  ├── go test ./... を再実行
  ├── PASS ログ + カバレッジを確認・記録
  └── coverage ≥ 80% を確認 (line + branch)

Step 3: REFACTOR (リファクタリング)
  ├── コードをクリーンにする
  ├── テストを再実行し PASS を維持
  └── PR に Red ログ / Green ログ / Coverage レポートを添付
```

### 2.1 Bootstrap / 新規実装の場合

新規リポジトリ立ち上げ (Bootstrap Issue) では、修正前の Red ログが存在しない場合がある。  
その場合は PR に以下を明記すること:

```
Red log: N/A - 新規実装（修正前の失敗ログは存在しない）
```

---

## 3. PR テンプレートへの TDD 証跡添付義務

全 PR に以下セクションを含めること。テンプレートは各リポジトリの `.github/PULL_REQUEST_TEMPLATE.md` に設定される。

```markdown
## TDD 証跡（必須）

### Red log（修正前: 失敗確認）
<details><summary>失敗ログを貼付</summary>

\`\`\`
（該当テストが `FAIL` したログを貼付。Bootstrap 系 Issue は `N/A - 新規実装` と明記）
\`\`\`
</details>

### Green log（修正後: 成功確認）
<details><summary>成功ログを貼付</summary>

\`\`\`
（`PASS` + カバレッジ値を貼付）
\`\`\`
</details>

### Coverage
- Line coverage: __%（閾値: ≥ 80%）
- Branch coverage: __%（閾値: ≥ 70%）
```

### 3.1 CI による PR テンプレ必須フィールド検証

GitHub Actions `pr-checklist.yml` により、PR body に以下のキーワードが含まれない場合は自動 reject する:

| 必須要素 | 検出キーワード | 例外 |
|---|---|---|
| TDD証跡セクション | `## TDD 証跡` | なし |
| Red log | `Red log` | なし |
| Green log | `Green log` | なし |
| Coverage | `Line coverage:` | なし |

---

## 4. 空テスト禁止ガード (CI)

### 4.1 検出対象

以下のパターンを CI で検出し、検出した場合は **CI fail** とする:

#### Go
```bash
# 空のテスト関数 (body が空)
grep -rEn 'func Test[A-Z][A-Za-z0-9_]*\(t \*testing\.T\) \{[[:space:]]*\}' ./...

# t.Skip の無条件使用
grep -rn 't\.Skip(' ./... | grep -v '// allow-skip:'

# 恒真 assertion (assert(true) 等)
grep -rEn 'assert\.True\(t,\s*true\)|assert\.Equal\(t,\s*true,\s*true\)' ./...
```

#### TypeScript / JavaScript
```bash
# it.skip / describe.skip / xit / xdescribe
grep -rEn 'it\.skip|describe\.skip|xit\(|xdescribe\(' ./...

# 恒真 assertion
grep -rEn 'expect\(true\)\.toBe\(true\)|expect\(1\)\.toBe\(1\)' ./...
```

#### Swift
```bash
grep -rEn 'XCTSkip|func testDisabled_' ./...
```

#### Kotlin / Android
```bash
grep -rEn '@Ignore|assumeTrue\(false\)' ./...
```

### 4.2 例外の扱い

どうしてもスキップが必要な場合:

1. 別途 GitHub Issue を起票し、スキップ理由と再有効化条件を記録する
2. スキップするテストのコメントに `// allow-skip: #<Issue番号>` を追記する
3. PR レビュアーが Issue 番号の有効性を確認する

### 4.3 CI スクリプト (detect-empty-tests.sh)

スクリプトは `recerdo-infra/scripts/detect-empty-tests.sh` に配置される。  
各リポジトリの `test.yml` に以下のステップを追加する:

```yaml
- name: Detect empty/skip tests
  run: |
    curl -fsSL https://raw.githubusercontent.com/Willen-Federation/recerdo-infra/main/scripts/detect-empty-tests.sh | bash
  env:
    REPO_LANGUAGE: go  # go / typescript / swift / kotlin
```

---

## 5. カバレッジゲート

### 5.1 言語別閾値

| 言語 | ツール | Line Coverage 閾値 | Branch Coverage 閾値 |
|---|---|---|---|
| **Go** | `go test -coverprofile=coverage.out` | **≥ 80%** | **≥ 70%** |
| **TypeScript / JS** | `vitest --coverage` (c8/istanbul) | **≥ 80%** | **≥ 70%** |
| **Swift (iOS)** | `XCTest` + `xccov` | **≥ 80%** | — |
| **Kotlin (Android)** | `./gradlew jacocoTestReport` | **≥ 80%** | **≥ 70%** |

### 5.2 CI でのカバレッジ強制

```yaml
# coverage-gate.yml (抜粋)
- name: Check Go coverage
  run: |
    go test -coverprofile=coverage.out ./...
    COVERAGE=$(go tool cover -func=coverage.out | grep total | awk '{print $3}' | sed 's/%//')
    echo "Coverage: ${COVERAGE}%"
    if (( $(echo "$COVERAGE < 80" | bc -l) )); then
      echo "❌ Coverage ${COVERAGE}% is below the required 80%"
      exit 1
    fi
    echo "✅ Coverage ${COVERAGE}% meets the requirement"
```

### 5.3 カバレッジ閾値達成のための禁止行為

以下の方法でカバレッジを「水増し」することを禁止する:

- 実際のビジネスロジックを検証しない「dummy test」の追加
- 常に true を返す assertion (`assert(true)`, `expect(1).toBe(1)`)
- テスト対象のコードを coverage 除外 (`// nolint:testpackage` の乱用)
- モック過剰利用による実装コードの未テスト化

---

## 6. ミューテーションテスト (週次)

### 6.1 目的

テストの品質を「mutation score」で評価する。  
mutant が生き残る (surviving mutant) 率が高いテストは、実質的な検証を行っていない。

### 6.2 ツール

| 言語 | ツール | Surviving mutant 閾値 |
|---|---|---|
| Go | [go-mutesting](https://github.com/zimmski/go-mutesting) | **≤ 30%** |
| TypeScript | [Stryker Mutator](https://stryker-mutator.io/) | **≤ 30%** |
| Swift | [Muter](https://github.com/muter-mutation-testing/muter) | **≤ 30%** |

### 6.3 週次スケジュール

```yaml
# mutation-test.yml
on:
  schedule:
    - cron: '0 2 * * 1'  # 毎週月曜 02:00 UTC
  workflow_dispatch:

jobs:
  mutation-test-go:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install go-mutesting
        run: go install github.com/zimmski/go-mutesting/cmd/go-mutesting@latest
      - name: Run mutation tests
        run: |
          go-mutesting ./... --output=json > mutation-report.json
          SURVIVOR_RATE=$(jq '.survivorRate' mutation-report.json)
          echo "Survivor rate: ${SURVIVOR_RATE}%"
          if (( $(echo "$SURVIVOR_RATE > 30" | bc -l) )); then
            echo "❌ Mutation test survivor rate ${SURVIVOR_RATE}% exceeds 30%"
            exit 1
          fi
      - name: Upload mutation report
        uses: actions/upload-artifact@v4
        with:
          name: mutation-report
          path: mutation-report.json
```

---

## 7. AI エージェント (Claude 等) への適用ルール

本セクションは `docs/core/workflow.md §17 AI補助開発` と連動する。

### 7.1 必須義務

AIエージェントが PR を生成・提出する場合、以下を **必ず** 実行すること:

1. **先行テスト**: 実装コードを書く前にテストを記述し、`FAIL` を確認する
2. **Red ログ取得**: `go test ./...` (または相当コマンド) の FAIL 出力を PR body に記録する
3. **実装後 Green 確認**: 実装後に同じテストが `PASS` することを確認し、ログを記録する
4. **カバレッジ確認**: `go test -coverprofile=coverage.out ./...` を実行し、閾値 (≥ 80%) を確認する
5. **異常系テスト**: ネットワーク断 / タイムアウト / DB 接続失敗等のエラーパスを必ずテストする

### 7.2 禁止行為

- Red ログなしで「テスト済み」と主張すること
- `t.Skip()` や `it.skip()` を理由なく使用すること
- 空のテスト関数を含む PR を提出すること
- カバレッジ閾値を満たすために意味のない assertion を追加すること
- `go test ./... | grep -c PASS` のみで Done 判定すること

### 7.3 Bootstrap 系 Issue の特例

新規リポジトリの初期セットアップ (Bootstrap) では `FAIL` 前状態が存在しないため:

```markdown
Red log: N/A - 新規実装
理由: Bootstrap Issue のため修正前のコードが存在しない。
最初のテスト実装から開始し、Green log と Coverage を添付する。
```

---

## 8. 異常系テスト要件

通常の Happy path に加え、以下の異常系シナリオを **全 Phase1 以降の Issue** でテストすること:

### 8.1 ネットワーク障害 (toxiproxy)

```go
// toxiproxy を用いた DB 接続断テスト例
func TestRepository_DBConnectionFailure(t *testing.T) {
    proxy := toxiproxy.NewProxy("mysql", "localhost:13306", "localhost:3306")
    proxy.AddToxic("down", toxiproxy.ToxicTypeDown, ...)
    defer proxy.Delete()
    
    // 接続断時の Retry / fallback を検証
    _, err := repo.FindByID(ctx, "test-id")
    assert.Error(t, err)
    assert.ErrorIs(t, err, ErrServiceUnavailable)
}
```

### 8.2 タイムアウト

```go
// Context deadline exceeded のハンドリング検証
func TestUseCase_ContextTimeout(t *testing.T) {
    ctx, cancel := context.WithTimeout(context.Background(), 1*time.Millisecond)
    defer cancel()
    time.Sleep(10 * time.Millisecond)
    
    _, err := useCase.Execute(ctx, input)
    assert.ErrorIs(t, err, context.DeadlineExceeded)
}
```

### 8.3 DB 競合・重複

```go
// Idempotency Key の重複エラー検証
func TestRepository_DuplicateIdempotencyKey(t *testing.T) {
    // 1回目: 正常挿入
    err := repo.Insert(ctx, record)
    assert.NoError(t, err)
    
    // 2回目: 同じ Idempotency Key で409
    err = repo.Insert(ctx, record)
    assert.ErrorIs(t, err, ErrDuplicateEntry)
}
```

---

## 9. 証跡の保存と参照

### 9.1 GitHub Actions Artifacts

CI の `test.yml` は以下を artifact として保存する:

- `coverage.out` — Go カバレッジプロファイル
- `coverage.html` — カバレッジ HTML レポート
- `mutation-report.json` — 週次ミューテーションレポート

### 9.2 PR Body への必須リンク

PR body には以下の GitHub Actions パーマリンクを含めること:

```markdown
### CI Evidence Links
- Red log: [Actions Run #XXXX](https://github.com/Willen-Federation/recerdo-xxx/actions/runs/XXXX) (FAIL)
- Green log: [Actions Run #YYYY](https://github.com/Willen-Federation/recerdo-xxx/actions/runs/YYYY) (PASS)
- Coverage: XX.X% - [Coverage Report](https://github.com/Willen-Federation/recerdo-xxx/actions/runs/YYYY/artifacts)
```

---

## 参照

- [workflow.md §7 テスト戦略](workflow.md#7-テスト戦略)
- [workflow.md §16 QA](workflow.md#16-qa-品質監査)
- [workflow.md §17 AI 補助開発](workflow.md#17-ai-補助開発-claude-等)
- [policy.md §3.2 カバレッジ閾値](policy.md)
- [Issue #41 — TDD Blocker](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/41)
- [Kent Beck — Canon TDD](https://tidyfirst.substack.com/p/canon-tdd)
- [go-mutesting](https://github.com/zimmski/go-mutesting)
- [Stryker Mutator](https://stryker-mutator.io/)

---

最終更新: 2026-04-22