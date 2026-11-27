# KINTAI SaaS 障害・不具合是正履歴台帳 (Incident History Ledger)

本台帳は、本プロジェクトのリファクタリングおよびAI自動検証運用において発生したインシデント、原因、恒久対策、および物理的検証結果を記録・管理する公式台帳です。

---

## 🏛️ インシデント管理記録 (Incident Records)

### 2026-11-27 — INCIDENT-KT-01 — Codex CLI 引数空白分割による NativeCommandError 障害
- **障害事象 (Symptoms)**:
  - `tools/scripts/call_codex.ps1` 実行時、改行・空白を含むプロンプト文字列が引数分割され、`NativeCommandError: 'Sprint' イン数を許可するパラメーターが見つかりません` で異常終了した。
- **根本原因 (Root Cause)**:
  - PowerShell から外部 CLI 実行時、`-Prompt` 文字列のダブルクォート解釈が崩れ、空白区切りで個別パラメータとして誤認識された。
- **解決措置 (Remediation)**:
  - プロンプトを一時ファイル（`$env:TEMP\codex_prompt_$PID.txt`）に退避し、`-PromptFile` 経由で引き渡す安全バイパス機構を実装。
- **ステータス**: `RESOLVED / DEFECT-INFRA-01_FIXED`

---

### 2026-11-27 — INCIDENT-KT-02 — Claude Sonnet 5.5 Thinking API パラメータ仕様不一致 (HTTP 400)
- **障害事象 (Symptoms)**:
  - `tools/scripts/call_ai.ps1` 経由で `claude-sonnet-5-5` を呼び出した際、`invalid_request_error: thinking.type.enabled is not supported for this model. Use adaptive` エラー（HTTP 400）が発生し、監査が遮断された。
- **根本原因 (Root Cause)**:
  - Claude 3.7 Sonnet 形式の `"type": "enabled"` 設定が、Claude Sonnet 5.5 の公式パラメータ仕様（`"thinking": {"type": "adaptive"}`）と乖離していた。
- **解決措置 (Remediation)**:
  - `call_ai.ps1` 内のパラメータを `"thinking": {"type": "adaptive"}` に恒久修正し、単独呼出テスト（所要時間4.8秒、HTTP 200 PASS）により検証完了。
- **ステータス**: `RESOLVED / PIPELINE_PATCHED`

---

### 2026-11-27 — INCIDENT-KT-03 — インライン複数行PowerShell実行制限および物理スクリプト呼出原則の確立
- **障害事象 (Symptoms)**:
  - `run_command` において複数行や変数展開（`$`）を含むPowerShellコマンドをインライン（`powershell -Command "..."`）で実行した際、変数が消失するか構文エラーとなり、バックグラウンド無応答・ハング障害が発生した。
- **根本原因 (Root Cause)**:
  - Windows PowerShell 5.1 のコマンドライン引数エスケープ規則の不整合および標準入出力パイプラインのEOF未終了。
- **解決措置 (Remediation)**:
  - 単一行ネイティブコマンドを除くすべての処理は、必ず `scratch/` 配下に UTF-8 物理スクリプト（`.ps1`）を作成し、`powershell -ExecutionPolicy Bypass -File "絶対パス"` の単一呼出で実行する憲法規則を制定・定着。
- **ステータス**: `RESOLVED / CODIFIED_IN_CONSTITUTION`

---

### 2026-11-27 — INCIDENT-KT-04 — ドキュメント同期ドリフト、行数虚偽報告および決定論的パリティゲート新設
- **障害事象 (Symptoms)**:
  1. `docs/technical_audit_dossier.md`（実測212行）および `sprint_roadmap_plan.md`（実測46行）を「それぞれ1,000〜1,100行に達する大規模文書」と誤認・虚偽報告し、同期処理遅延の根本原因分析を誤導した。
  2. `sprint_roadmap_plan.md` の欠陥管理キュー（Defect Queue）において、Day 1 の10大是正欠陥（`DEFECT-D1-01`〜`10`）が脱落・未登録のまま放置された。
  3. 日本語正本実証書（Dossier）と韓国語対照本実証書の間で、第11項の欠陥是正履歴テーブルの行数および内容に不一致（D2欠陥の反映漏れ）が発生していた。
- **根本原因 (Root Cause)**:
  - エージェントの主観的注意および口頭報告のみに依存し、ドキュメント間の一致を機械的・決定論的に検証する静的解析ゲート（Linter）が存在しなかったこと。
- **解決措置 (Remediation)**:
  1. `sprint_roadmap_plan.md` および `sprint_roadmap_plan_KO.md` に `[Day 1]` 是正欠陥10件を正式追記し、全34件の欠陥キュー体系を完全確立。
  2. `technical_audit_dossier.md` および `technical_audit_dossier_KO.md` の第11項テーブルに `DEFECT-D1-01`〜`10` および `DEFECT-D2-01`〜`09`（計20行）を1:1完全一致で同期。
  3. `build.gradle` に決定論的整合性ゲート `verifyDocumentParity` を新設し、`./gradlew check` の必須依存タスクとして統合。
     - ロードマップ JA vs KO の欠陥ID完全一致（34件）
     - ロードマップ JA vs KO の完了数 `[x]` 完全一致（19件）
     - 実証書（Dossier）第11項テーブル行数の JA vs KO 完全一致（20行）
     - ロードマップ完了欠陥の実証書テーブル実在検証（ID未存在時は即座にビルド遮断）
- **物理的検証証拠 (Evidence)**:
  - `./gradlew verifyDocumentParity`: PASS (`BUILD SUCCESSFUL`)
  - `./gradlew check`: 全7タスク正常通過（`verifyDocumentParity`, `verifyZeroKorean`, `verifyMyBatisSqlSafety`, JUnit 5 22テスト全数通過）
- **ステータス**: `RESOLVED / DETERMINISTIC_GATE_ESTABLISHED`
