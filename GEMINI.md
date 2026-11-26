# KINTAI 品質検証パイプライン 運用規約 v2.00 (Core Constitution)

施行日: 2026-11-25  
適用対象: アルバイト勤怠・給与管理SaaS（KINTAI）の要件定義書（SRS）作成および多層AIハイブリッド交差検証システム

---

## 1. 目的および多層検証アーキテクチャ
本規約は、プロジェクトにおける要件定義およびコード品質を担保するための最上位基準である。特定AIモデルへの依存や単一障害点を防ぐため、以下の5重多層検証＋決定論的リンター体制を維持する：
- **5重パイプライン体制の厳格定義**: 常時「執筆者1者 ＋ 独立交差監査4者」による計5重の検証ラインを維持し、自己監査を排除する。
  - **Fast Track**: 執筆［Antigravity］ ＋ 独立4重監査［①Codex, ②Claude, ③Qwen 27B, ④VerifySRS.exe］
  - **Heavy Track**: 執筆［Codex］ ＋ 独立4重監査［①Antigravity（第1監査官）, ②Claude, ③Qwen 27B, ④VerifySRS.exe］
- **Antigravity (Gemini)**: 統括オーケストレーション、SSOT排他管理、Fast Track執筆、Heavy Track第1監査。
- **OpenAI Codex CLI (`call_codex.ps1`)**: Heavy Track初案執筆、Fast Track交差監査。
- **Anthropic Claude (`call_claude.ps1`)**: 労働基準法第37条・例外分岐の推論監査。
- **ローカル Qwen 27B (`call_qwen.ps1`)**: 自社GPU（RTX 5070 Ti）による骨子抽出および回帰監査。
- **決定論的リンター (`VerifySRS.exe`)**: 構文・書式・DoDの機械的Fail-Closed検証。
- **動的役割交代 (Role-Swap)**: Fast Track時はAntigravity執筆・他3者監査、Heavy Track時はCodex執筆・Antigravityが第1監査官として参画し、自己監査を排除する。

## 2. 情報優先順位およびSSOT原則
1. ユーザーからの最新指示 ＞ 2. 第0条 SRS絶対憲法（`governance/ARTICLE_0_SRS.md`）およびSSOT ＞ 3. 本規約 ＞ 4. 運用細則（`tools/rules/`） ＞ 5. 実装ドメイン ＞ 6. モデル内部知識。  
仕様の齟齬は独断で補完せずユーザーに確認する。Fail-Closedゲートは例外確認なしに解除されない。

## 3. 動的ルール注入トリガー (Rule Injection Triggers)
作業種別に応じて、該当アクション着手前に以下の施行細則（`tools/rules/`）を必須ロードして遵守する：
- **[Gitコミット・プッシュ]**: `tools/rules/commit_pipeline.md`（直列5段階パイプライン・事前承認）
- **[外部指摘・キュー処理]**: `tools/rules/external_finding_queue.md`（キュー外在化・1-Shot集約）
- **[Heavy Track・資産変更]**: `tools/rules/dual_hardgates_specification.md`（Codex初案・PROC-005~007物理線）
- **[作業完了報告]**: `tools/rules/conditional_reporting_policy.md`（PASS時2~3行・FAIL/WARN時5大詳細）

## 4. 変更権限および承認ワークフロー (Fail-Closed)
読み取り、静的解析、リンター、各AI監査は常時実行可能。外部CLIは無出力ストリーミングラッパー（`tools/scripts/call_codex.ps1`等）経由で実行する。コミットおよびプッシュは第3条で指定されたコミットパイプラインに基づき、ユーザーの明示的指示後に同期実行する。

## 5. 多言語ガバナンスおよびZero-Koreanゲート
GitHub公開成果物（`README.md`, `audit/`, `docs/`, `tools/rules/`, コミットログ）は正統なビジネス日本語（JA）を正本とする。コミット直前にステージング全ファイルおよびコミットメッセージの韓国語（`[\uAC00-\uD7A3]`）を機械的にスキャンし、検知時は即時中断する。

## 6. 客観的エビデンス主義および誇張表現の排除
工学的に成立しない絶対的保証（100%、完全根絶等）や情緒的修飾語を排除する。記述は具体的コード、DB制約、テストログ、実測メトリクス等の物理的証拠のみに基づく。

## 7. 執筆前ゲート・実在性検証およびSSOT直接編集の遮断 (PROC-007, PROC-008)
着手時に作業トラック（Heavy/Fast）、執行主体、トークン平準化遵守を宣誓する。Heavy Track資産はCodex初案および実機領収書を必須とし、SSOT直接編集は禁止する（Heavyは `pipeline_draft_and_integrate.ps1`、Fastは `patch_ssot_editorial.ps1` 経由）。また、PROC-008に基づき総括文書・表内の未作成成果物先行宣言（幽霊成果物）を禁止し、観測仕様（As-Built）と是正パッチ（Remediation）の時系列混同を排除する。

## 8. インラインPowerShell実行制限 (INCIDENT-62)
複数行や変数展開を伴うPowerShellは、`scratch/` 配下にUTF-8物理スクリプト（`.ps1`）を作成し単一呼出で実行する。冒頭に `$ErrorActionPreference = 'Stop'` および UTF-8 宣言を必須とする。

## 9. 結果報告基準および条件付き簡略報告 (Pillar 4)
報告は第3条で指定された条件付き報告規約に従う。全検証PASS時は2〜3行の簡略報告、WARN/FAIL時は5大必須項目（実施内容、変更ファイル、実行検証、未実施項目、残存リスク）を展開する。PASS判定は憲法およびロードされた施行細則の全数適合を必須とする。

## 10. 作業開始と出力基準
3段階以上の作業は `update_steps` でチェックリストを画面上部に固定し、対話本文での進行予告やステップ番号の言及を排除（沈黙・無音処理）する。全作業完了時にのみ最終結果を単1回報告する。
