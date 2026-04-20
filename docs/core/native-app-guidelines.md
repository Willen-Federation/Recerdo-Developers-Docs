# ネイティブアプリ方針（iOS / macOS / Android / Desktop）

> **対象フェーズ**: Closed Beta 〜 GA 全体
> **最終更新**: 2026-04-20
> **位置づけ**: クライアントアプリのプラットフォーム選定と署名配布方針の SSOT。
> [基本的方針 (Policy)](policy.md) と矛盾した場合は本ドキュメントではなく policy.md を優先する（本ドキュメントはその下位の実装指針）。

---

## 1. プラットフォームごとの技術選定

| プラットフォーム | 採用技術 | リポジトリ | 不採用 |
| --- | --- | --- | --- |
| **iOS**（iPhone / iPad） | **Swift + SwiftUI** によるネイティブアプリ | [Recerdo-iOS](https://github.com/Willen-Federation/Recerdo-iOS) | **Flutter / React Native / Kotlin Multiplatform は採用しない** |
| **macOS** | **Swift + SwiftUI (+ 必要に応じて AppKit)** によるネイティブアプリ（iOS と同一ターゲットで Mac Catalyst も可） | Recerdo-iOS（マルチプラットフォームターゲット）または専用リポジトリを後日切り出し | **Electron / Flutter は採用しない** |
| **Android** | **Kotlin + Jetpack Compose** によるネイティブアプリ | [recerdo-android-dart](https://github.com/Willen-Federation/recerdo-android-dart)（リポジトリ名に `dart` を含むが **Dart/Flutter は使わない**。将来的にリネーム予定） | **Flutter / Dart / React Native / KMM は採用しない** |
| **Desktop (Windows / Linux)** | Electron + TypeScript（Web クライアント資産の再利用目的に限定） | [recerdo-desktop-electron](https://github.com/Willen-Federation/recerdo-desktop-electron) | macOS に対する Electron ビルドは **提供しない**（macOS はネイティブを利用） |
| **Web** | SPA（既存 `recerdo-spa-webclient`） | [recerdo-spa-webclient](https://github.com/Willen-Federation/recerdo-spa-webclient) | — |

!!! danger "Flutter 不採用の明文化"
    Recerdo のモバイル / デスクトップアプリで **Flutter / Dart は一切採用しない**。過去資料やリポジトリ名に残っている `dart` / `flutter` の記述は、本ガイドラインに沿って段階的に置換する（リポジトリリネームは別途調整）。

### 1.1 共通方針

- ビジネスロジックの共有は **gRPC / HTTP + JSON のサーバー API 契約**（[`recerdo-shared-proto`](https://github.com/Willen-Federation/recerdo-shared-proto)）経由で行い、クライアント間でクロスコンパイル・コード共有（KMM / Flutter / RN）は **行わない**。
- UI は各 OS の設計指針（Apple HIG / Material 3）に準拠する。
- 認証は AWS Cognito（Hosted UI、OAuth 2.0 / PKCE）、プッシュ通知は FCM。これらは [policy.md §1](policy.md#11-beta-フェーズclosed-beta--open-beta) の通り。

---

## 2. コード署名の方針

### 2.1 基本方針

!!! tip "方針: 有償のコード署名証明書は原則利用しない"
    プラットフォームが強制するもの（iOS の App Store 配布など）を除き、**有償の商用コード署名証明書（DigiCert / Sectigo 等）は購入しない**。代わりに、以下で列挙する **無料 / 安価な代替手段** で必要十分な信頼を担保する。

### 2.2 プラットフォーム別の選択肢

| プラットフォーム | 配布経路 | 署名の要否 | 推奨する安価 / 無料手段 |
| --- | --- | --- | --- |
| iOS（App Store / TestFlight） | Apple App Store | **必須**（Apple が強制） | **Apple Developer Program**（¥14,800 / 年、**個人**枠）。これ以外の選択肢は無い。 |
| iOS（社内配布・検証） | 開発機での直接実行 | Free provisioning で可 | **Xcode の Free Provisioning**（無料 Apple ID、7 日有効 / 3 アプリ制限）を Beta 内部検証でのみ使用。 |
| macOS（DMG / zip 直接配布） | 自サイト配信 | 任意（Gatekeeper 警告は出る） | **ad-hoc 署名（`codesign --sign -`）** + 初回のみ「右クリック → 開く」でユーザー許可。公証は **行わない**。 |
| macOS（Homebrew Cask） | `brew install --cask` | 任意 | Cask 側でハッシュ検証されるため **未公証でも問題なく配布可能**。 |
| Android（Google Play） | Play Console | **必須**（自己署名） | **自己署名（keytool + apksigner）**。証明書費用 ¥0。Google Play 登録料 **$25（一度きり）** のみ。 |
| Android（野良 APK / F-Droid） | 自サイト or F-Droid | 自己署名で可 | 上記と同じ自己署名鍵。F-Droid は GPG 署名も併用（無料）。 |
| Windows（EXE / MSI） | 自サイト配信 | 任意（SmartScreen 警告は出る） | **未署名配布** + インストール時の「詳細情報 → 実行」で回避、または **SignPath.io Foundation** 経由で OSS 署名を無料取得、または **Azure Trusted Signing**（$9.99 / 月、2026 時点）で安価代替。 |
| Windows（Microsoft Store） | MS Store | 任意 | ストア側の署名を利用するため自前証明書不要。開発者登録 **$19（個人、一度きり）**。 |
| Linux（AppImage / deb / rpm） | 自サイト or OBS | 不要（GPG 署名が慣習） | **GPG 鍵で自己署名**（無料）。Snap / Flatpak なら各ストア側で管理。 |

### 2.3 Apple Developer Program の扱い

- iOS を App Store 配信する以上、**Apple Developer Program（個人 ¥14,800 / 年）は唯一避けられない固定費**。
- macOS のみの配布であれば、Apple Developer Program に加入せず **ad-hoc 署名のみで配布可能**（2.4 を参照）。
- Beta フェーズでは **個人枠のみ**とし、組織枠（Organization、$299 / 年）への移行は GA 直前に検討する。
- Apple Developer Program から発行される開発者証明書・Distribution 証明書・APNs 証明書は **本プログラム範囲内で無料** のため、「コード署名証明書を利用しない」方針とは矛盾しない（外部 CA から買わないという意味）。

### 2.4 macOS 未公証配布のユーザー導線

macOS を Apple Notarization なしで配布する場合、初回起動時に Gatekeeper によりブロックされる。以下の導線を README / ダウンロードページに明記する:

1. `.app` をアプリケーションフォルダへ移動。
2. **Finder で右クリック → 開く**（or `xattr -d com.apple.quarantine /Applications/Recerdo.app`）。
3. 「開発元が未確認」ダイアログで「開く」を選択。

これにより **Apple Developer Program 非加入 + 公証なし** でも macOS アプリの配布が可能。Beta 期間の macOS クライアント配布は原則この方式を採る。

### 2.5 Android の自己署名運用

- 鍵は `keytool -genkey -v -keystore recerdo-release.jks -keyalg RSA -keysize 4096 -validity 25000`（約 68 年有効）で生成。
- 鍵と `keystore` パスワードは **sops + age** で暗号化し、`recerdo-infra` リポジトリ内の `secrets/android/` に保管。GitHub Actions からは OIDC → sops 復号で取得。
- Play App Signing（Google の鍵管理サービス）を **有効化**することで、署名鍵紛失リスクを回避する。初回アップロード時の Upload Key は上記自己署名。

### 2.6 Windows の未署名配布運用

- まずは **未署名配布** + SmartScreen 警告で Beta を進める。README に「詳細情報 → 実行」導線を記載。
- OSS ライセンスが確定したら **SignPath Foundation** に応募（要件: OSS ライセンス + GitHub 公開）。採択されれば **EV コード署名が無料で利用可**。
- OSS 不成立・急ぎで署名が必要な場合は **Azure Trusted Signing**（$9.99 / 月）を限定的に採用。DigiCert 系 EV（$400〜 / 年）は **不採用**。

### 2.7 禁止・避ける事項

- **DigiCert / Sectigo / GlobalSign / SSL.com の商用コード署名証明書**: 年額 1〜5 万円規模。費用対効果が悪いため **購入しない**。
- **Windows の自己署名 CA を配布先 PC にインストールさせる方式**: ユーザー操作負荷が高く、かつセキュリティリスクがある。
- **iOS の Enterprise Program（$299 / 年）**: ストア外配布のみ可能でありガイドライン違反リスクが高い。Recerdo では採用しない。

---

## 3. CI / リリースパイプラインへの反映

| プラットフォーム | ビルド | 署名 | 配布 |
| --- | --- | --- | --- |
| iOS | GitHub Actions (self-hosted macOS runner、Apple Silicon mini) or Xcode Cloud 最小枠 | Fastlane `match` + Apple Developer Program 証明書 | TestFlight → App Store Connect |
| macOS | 同上 | `codesign --sign -`（ad-hoc）※ 有償証明書不使用 | GitHub Releases の `.dmg` / Homebrew Cask |
| Android | GitHub Actions (Linux) | apksigner + sops で復号した keystore | Play Internal Testing → Closed Testing → Production |
| Windows | GitHub Actions (Windows) | 未署名（当面）／ SignPath Foundation 採択後に自動署名 | GitHub Releases の `.exe` / `.msi` |
| Linux | GitHub Actions (Linux) | GPG 署名（`gpg --detach-sign`） | GitHub Releases / OBS |

- 各パイプラインは **AWS を経由しない**（[policy.md §1.3](policy.md#13-aws-利用ポリシー)）。アーティファクト保管は GitHub Releases + OCI Object Storage（本番）。
- シークレットは Beta = `sops + age`、本番 = OCI Vault（[policy.md §5](policy.md#5-セキュリティ)）。

---

## 4. 既存ドキュメント / リポジトリへの適用チェックリスト

既存資料に以下のキーワードが残っていれば **本ガイドラインへの追従が必要**。発見時は本ドキュメントを引用しつつ修正 PR を起票する。

- [ ] `Flutter` / `Dart` の採用記述（macOS / iOS / Android のいずれでも不採用）
- [ ] `recerdo-android-dart` を Flutter プロジェクトとして説明している箇所
- [ ] macOS 向け Electron ビルドの記述
- [ ] 有償のコード署名証明書（DigiCert / Sectigo 等）を前提としたコスト試算
- [ ] Apple Enterprise Program ($299/年) 利用の前提
- [ ] iOS / Android のクロスプラットフォーム共通コード（KMM / RN）前提

上記に該当する記述を見つけ次第、[changelog.md](../changelog.md) にも差分を記録する。

---

## 5. 関連ドキュメント

- [基本的方針 (Policy)](policy.md)
- [コストパフォーマンス分析](cost-performance-analysis.md) — Beta 固定費に本ガイドラインの方針が反映されること
- [デプロイメント戦略](deployment-strategy.md)
- [PoC / Beta スコープ](poc-beta-scope.md)

---

## 6. 参考

- [Apple Developer Program — 個人 / 組織 料金体系](https://developer.apple.com/jp/support/compare-memberships/)
- [Android App Signing（公式）](https://developer.android.com/studio/publish/app-signing)
- [SignPath Foundation — Free Code Signing for Open Source](https://signpath.org/)
- [Azure Trusted Signing](https://learn.microsoft.com/azure/trusted-signing/)
- [Gatekeeper と macOS の公証について](https://support.apple.com/ja-jp/guide/security/sec7c917bf14/web)

---

最終更新: 2026-04-20 ネイティブアプリ方針とコード署名代替案を明文化
