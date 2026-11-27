# プロジェクト3（Phase 3: 収束・リファクタリング）10日間インクリメンタル開発計画書

**システム名**: 勤怠・シフト・給与管理システム (Kintai Management System)  
**リポジトリ**: `kintai-refactored`  
**目的**: プロジェクト1（実機バックエンド）およびプロジェクト2（5重多層AI監査・設計SSOT）の成果を統合し、日本の労働基準法に完全準拠したエンタープライズ品質の就職・面接用完成Web SaaSを構築する。  
**開発方針**: 1日1スプリント原則（1日1〜2コミット上限、実機ビルド・単体テスト・ローカルAI監査の4重検証を徹底）。

---

## 📅 10日間スプリント開発ロードマップ

| 日程 (Day) | ステータス | 対象ブランチ / ドメイン | 実装・リファクタリング内容 | 面接官へのアピールポイント |
|:---:|:---:|---|---|---|
| **Day 1** | **完了** | `main` (ベースライン) | プロジェクト2検証済みパッチ統合（確定給与上書き防御、労基法37条計算エンジン修正、単体テスト追加） | 設計・実装乖離の是正能力、多層AI監査による不具合早期摘発 |
| **Day 2** | **完了** | `feature/auth-security` | Spring Security 6 セッション認証、RBAC（OWNER/STAFF）ロール制御、IDOR脆弱性防御、CSRF保護強化、9大欠陥全数是正 | 実務水準のWebセキュリティおよびマルチテナント境界保護 |
| **Day 3** | 予定 | `feature/attendance-punch` | 4打刻（出勤・休憩開始・休憩終了・退勤）ステートマシン、非同期（Fetch）UI連動、未退勤デッドロック防止 | リアルタイム勤怠トランザクション処理と状態遷移バリデーション |
| **Day 4** | 予定 | `feature/shift-request` | FullCalendar連動 スタッフ希望シフト申請機能、最大16時間拘束バリデーション | 外部ライブラリカスタマイズと業務制約の実装力 |
| **Day 5** | 予定 | `feature/shift-confirm` | 店長によるシフト確定トランザクション、**悲観的ロック（`SELECT ... FOR UPDATE`）** による同時更新遮断 | 高度な並行性制御とレースコンディション防御 |
| **Day 6** | **先行反映・検証済** | `feature/labor-calc-engine` | **労働基準法第37条 6段階割増計算（深夜25%、時間外25%、重複50%、休日35%、休日深夜60%、月60h超25%追加）** | 現地労働法規に厳密準拠したコア金融・労務ドメイン構築力 |
| **Day 7** | 予定 | `feature/payroll-batch` | 月次給与自動集計（締日判定・未承認勤怠ガード・1円単位四捨五入 `HALF_UP`） | 金融・会計システムの厳密な端数処理および帳簿ロック管理 |
| **Day 8** | 予定 | `feature/payroll-excel` | Apache POI 5.2 による税理士・社労士提出用 公式給与台帳（Excel）自動生成 | 実務標準帳票の出力エンジニアリング |
| **Day 9** | 予定 | `feature/mod-workflow` | 打刻修正申請および店長承認・却下ワークフロー、監査証跡（Audit Trail） | 労使間トラブル防止と労基署監査対応の業務フロー設計 |
| **Day 10** | 予定 | `docs/final-dossier` | 多層AI（Codex/Claude/Qwen）全域最終交差検証、Zero-Korean完全監査、デモ・試演環境整備 | エンタープライズ品質保証と体系的ドキュメンテーション |

---

## 📋 5層AI検証パイプライン摘発欠陥バックログ管理キュー (Defect Queue)

多層AIパイプライン（Qwen 27B / Claude Sonnet 3.7 / OpenAI Codex）により特定・検証された全是正対象キュー。各スプリント着手時および基盤整備時に該当項目を解消する。

### [Infra: 検証パイプライン・リンター基盤] 7大インフラ欠陥是正キュー
- [ ] **DEFECT-INFRA-01**: `tools/scripts/call_codex.ps1` - プロンプト文字列内の空白・改行による引数誤認識（NativeCommandError）防止（`-Prompt` 受領時の一時ファイル安全バイパス化）。
- [ ] **DEFECT-INFRA-02**: `build.gradle` / `tools/scripts/scan_korean.ps1` - Zero-Korean検証におけるハングル字母分解Unicode（`\u1100-\u11FF`, `\u3130-\u318F`）の漏れなき完全網羅（サイレントパス遮断）。
- [ ] **DEFECT-INFRA-03**: `tools/scripts/run_kintai_pipeline.ps1` - 純粋 `git diff` 送信による呼び出し元トランザクション・ロック順序文脈の断絶防止（関連サービス文脈拡張機構の導入）。
- [ ] **DEFECT-INFRA-04**: `tools/scripts/run_kintai_pipeline.ps1` - `Start-Job` 並行実行時の監査領収書（ログ）書き込み競合・上書き防止および完全プロセスID分離。
- [ ] **DEFECT-INFRA-05**: `tools/scripts/run_kintai_pipeline.ps1` - 当日スプリント新規差分欠陥とレガシー・将来バックログ欠陥の自動トリアージ分類（開発者疲弊・過度なビルド遮断の防止）。
- [ ] **DEFECT-INFRA-06**: `tools/scripts/run_kintai_pipeline.ps1` - AI外部API／リモートGPUタイムアウト・オフライン時におけるL4ゲートの極端遮断（Blocked-Terminator）に対するフェイルオーバーポリシー明示。
- [ ] **DEFECT-INFRA-07**: `tools/scripts/call_ai.ps1` - Anthropic Claude 3.7 Sonnet の 8K 出力トークン上限超過（`CLAUDE_RESPONSE_TRUNCATED`）防止（Extended Thinking 抑制 / `budget_tokens` 制限および出力 JSON スキーマ軽量化）。

### [Day 1: ベースライン統合・初期重大欠陥是正] `main` (10大欠陥 全数是正完了)
- [x] **DEFECT-D1-01**: `PayrollService.java:105` - 休日割増35%/60%の計算ロジックがデッドコード化していた不具合の是正（DB DDL拡張および6引数 `calculateDailyPay` 完全結合）。
- [x] **DEFECT-D1-02**: `AttendanceTimeCalculator.java` / `PayrollService.java` - 分割勤務（日中複数回出勤）時に法定時間外労働が0分となる集計不具合の解消（日累計480分再配分）。
- [x] **DEFECT-D1-03**: `PayrollService.java:148-161` - 月中時給変更時、月60時間超25%追加割増が全スキップされる不具合の是正（発生日契約時給基準のクロノロジカル加算）。
- [x] **DEFECT-D1-04**: `PayrollApiController`, `AttendanceApiController` - セッション店舗ID未検証およびハードコードフォールバックによるIDOR脆弱性防御（`@AuthenticationPrincipal` 必須化）。
- [x] **DEFECT-D1-05**: `SecurityConfig.java:32-33` - `/api/**` に対する CSRF 保護全面無効化の是正（`CookieCsrfTokenRepository` 適用）。
- [x] **DEFECT-D1-06**: `audit/runs/` - `.gitignore` 除外による多層検証領収書の物理消失防止（Git追跡化）。
- [x] **DEFECT-D1-07**: `PayrollService.java:201-260` - 非ロック状態での給与確定によるレースコンディション是正（`findByIdForUpdate` 先行行ロック獲得）。
- [x] **DEFECT-D1-08**: `application.yaml:8-9` - DB パスワード平文露出の是正（環境変数 `${DB_PASSWORD:1234}` 化）。
- [x] **DEFECT-D1-09**: `README.md` / `sprint_roadmap_plan.md` - 設計ドキュメントと実機DDL・ポートの不一致解消。
- [x] **DEFECT-D1-10**: `SecurityConfig.java:44` - `/members/sample` の `permitAll` 設定による会員情報露出リスクの是正（`ROLE_OWNER` 専用化）。

### [Day 2: 認証・セキュリティ] `feature/auth-security` (本日対象 9大改善キュー - 全数是正完了)
- [x] **DEFECT-D2-01**: `SecurityConfig.java:62` - 同時ログインセッション制御の改善（`maxSessionsPreventsLogin(true)` による既存打刻セッション切断防止および後続重複ログイン遮断）。
- [x] **DEFECT-D2-02**: `SecurityConfig.java:70` - ログアウトハンドラにおける明示的な `clearAuthentication(true)` 追加およびセッション無効化の完全性担保。
- [x] **DEFECT-D2-03**: `build.gradle` - Zero-Korean検証タスクにおけるハングル字母拡張範囲（`[\uAC00-\uD7A3\u1100-\u11FF\u3130-\u318F]`）の網羅的適用。
- [x] **DEFECT-D2-04**: `application.yml` - 不活性セッションタイムアウトの明示的設定（`server.servlet.session.timeout=30m` 等による放置端末セッション乗っ取り防止）。
- [x] **DEFECT-D2-05**: `CustomAuthenticationEntryPoint.java` / `CustomAccessDeniedHandler.java` - AJAX/API（`application/json`）と一般画面遷移（HTML）のレスポンスContent-Type分岐の堅牢化。
- [x] **DEFECT-D2-06**: `CustomAuthenticationEntryPoint.java` - 401未認証エラーレスポンスにおける内部例外スタックトレース等のセキュリティ情報漏洩防止。
- [x] **DEFECT-D2-07**: `CustomAccessDeniedHandler.java` - 403認可拒否発生時における不正アクセス試行の監査ログ（IP、Staff ID、アクセス先URI）記録強化。
- [x] **DEFECT-D2-08**: `SecurityConfig.java` - 静的リソース（CSS/JS/Images）に対する無認証アクセス許可パターンの過不足検証と厳密化。
- [x] **DEFECT-D2-09**: `ShiftApiController.java` - スタッフAPIにおけるパス変数 `staffId` と認証セッション情報の照合（IDOR多重防御）の徹底。

### [Day 3: 勤怠打刻・ステートマシン] `feature/attendance-punch`
- [ ] **DEFECT-D3-01**: `AttendanceService.java:240, 251` - スタッフ悲観的ロック取得前の `PENDING` 状態検査によるTOCTOUレースコンディション防止（ロック取得後の再検証を義務化）。
- [ ] **DEFECT-D3-02**: `AttendanceService.java:163, 181` - `forceCloseAttendance` における店舗所属検証（`storeId` 照合）の欠落によるIDOR脆弱性防御。

### [Day 5: シフト確定・排他制御] `feature/shift-confirm`
- [ ] **DEFECT-D5-01**: `ShiftService.java:82, 88` - `confirmShift` における悲観的ロック獲得後のシフトステータス再検証欠落の解消（確定済みシフトの上書き防止）。
- [ ] **DEFECT-D5-02**: `ShiftService.java` - シフト一括確定トランザクションにおける店舗境界検証（IDOR）の厳格化。

### [Day 6: 労基法第37条計算エンジン] `feature/labor-calc-engine`
- [ ] **DEFECT-D6-01**: `PayrollCalculator.java` - 労働基準法第32条第1項・第37条に基づく「週40時間超」法定時間外割増の集計ロジック実装。
- [ ] **DEFECT-D6-02**: `PayrollCalculator.java` - 労基法第37条第1項但書に基づく「休日労働時間（35%割増）」の月60時間超割増計算対象からの厳格除外。

### [Day 7: 給与自動集計バッチ] `feature/payroll-batch`
- [ ] **DEFECT-D7-01**: `PayrollService.java:57, 255` - ロック獲得順序の不一致（デッドロック要因: スタッフ→給与 vs 給与→スタッフ）を `スタッフ → 給与` の単一順序へ統一。
- [ ] **DEFECT-D7-02**: `PayrollService.java` - 基発150号行政通達に準拠した日次端数処理と月間累計端数処理の整合性維持。

---

## 🎯 各スプリント（日次）標準作業リズム (Daily Rhythm)
1. **着手**: 当日スプリントの機能スコープ確認（1機能に集中）。
2. **実装 & リファクタリング**: Java/Spring Boot、MyBatis、Thymeleaf のコード修正。
3. **ローカルAI & 4重検証**:
   - ① `./gradlew compileJava`（ビルド検証）
   - ② `./gradlew test`（JUnit 5単体テスト検証）
   - ③ `audit_with_hermes.ps1`（ローカル27B監査官による客観的判定）
   - ④ `scan_korean.ps1`（Zero-Korean 100%日本語検証）
4. **マスタコミット**: 1日1〜2回の純粋なビジネス日本語コミット＆GitHubプッシュで安全にクローズ。
