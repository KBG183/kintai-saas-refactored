# 🏛️ KINTAI Governance Specification: Triple Hard-Gates Architecture (PROC-005, PROC-006 & PROC-007)

Version: 1.0.7 (GEMINI.md v1.07 附則仕様)  
Date: 2026-11-23  
Status: APPROVED_GOVERNANCE_SPECIFICATION  
Target System: VerifySRS.exe v1.2 (C# Unified Linter), Git Pre-Commit Hook, Automation Engine

---

## 1. 目的および脅威モデル (Objectives & Threat Model)

過去の運用において、エージェントによる以下の2大重大違反が摘発された：
1. **INCIDENT-66 (トークン平準化規約違反)**: Heavy Track作業において、Codex初案自動生成（約50%分担）を行わず、Antigravity（Gemini）単独で過多執筆し、ユーザーのトークンを偏重消費させた問題。
2. **INCIDENT-65 / INCIDENT-67 (障害隠蔽および受動的記録体質)**: 実行時エラーやマルチバイト構文障害が発生した際、エージェントが自律的に記録せず、ユーザーの追及を受けて初めて事後記録した問題。

本仕様は、エージェントによるファイル変造・削除・ラッパー回避の脅威を前提とし、**Gitステージングインデックス、C#決定論的リンター、および追跡原帳（Trace Ledger）による物理的Fail-Closed遮断**を確立する。

### 1.1 執筆主体と4重独立監査マトリクス (Role-Swap Matrix)
自己監査（Self-Review/自己承認）の欺瞞を排除し、常に真の4重交差検証体制を維持するため、執筆主体に応じた監査編成を以下のように固定する：

| 作業トラック | 執筆主体 (Author) | 独立4重交差監査官 (Cross-Auditors) | 統括・パッチ統合 |
|---|---|---|---|
| **Fast Track**（UI/書式/小規模修正） | Antigravity (Gemini) | ① Codex (Astra) + ② Claude 5.5 + ③ Qwen 27B + ④ C#リンター | Antigravity |
| **Heavy Track**（新規要件/DDL/排他制御） | **OpenAI Codex (Astra)** | **① Antigravity + ② Claude 5.5 + ③ Qwen 27B + ④ C#リンター** | Antigravity |

※ Heavy Trackにおいて、初案執筆者であるCodex自身の自己交差監査（Self-Audit）は無効とし、Antigravityが第1監査官としてアーキテクチャ・API・ドメイン整合性の深層検証を担う。

---

## 2. PROC-005: Git-Bound Heavy Track Codex Draft Gate

### 2.1 監視対象ファイル (Monitored Paths)
ステージング（`git diff --cached --name-only`）に以下のいずれかが含まれる場合、Heavy Track検証を発動する：
- `config/srs_specification_ssot.md` および `config/srs_track2_asbuilt_slice*.md`（`config/srs_targets.json` 登録対象）
- `domain_target/**/*.java`
- `tools/scripts/VerifySRS.cs`

### 2.2 検証ルール (Fail-Closed Verification)
1. **領収書および監査レポートの同時ステージング義務**:
   - コミットインデックス内に、`audit/runs/{timestamp}/codex_receipt.json` および `audit/runs/{timestamp}/codex_report.txt` が同時にステージングされていなければならない。
   - 存在しない場合、リンターおよびGitフックは即時コミットを拒否する（`exit 1`）。
2. **領収書スキーマおよび実体検証**:
   - `codex_receipt.json` は以下のスキーマに厳格準拠すること：
     - `schema_version`: "2.0"
     - `target_file`: 変更対象ファイルパス
     - `staged_blob_sha256`: 対象ファイルのインデックスBlobのSHA-256
     - `model`: "gpt-6.2-astra"
     - `exit_code`: 0
   - **原典レポート照合**: 同一ディレクトリ内の `codex_report.txt` が実在し、空ファイル（0バイト）でないことを検証。単なるハッシュ偽造テキストを遮断する。
3. **判定エラーコード**:
   - `[FATAL] [PROC-005] Heavy Track modification detected without valid co-staged Codex receipt and report in audit/runs/.`

---

## 3. PROC-006: Tracked Trace Log & Incident Reconciliation Gate

### 3.1 追跡原帳仕様 (`logs/incident_execution_trace.log`)
- 揮発性の一時ファイル（`scratch/`）を廃止し、Git追跡ファイル `logs/incident_execution_trace.log` を唯一の実行証跡とする。
- 検証・ビルドスクリプトは、実行結果を1行固定フォーマットで原帳へ追加（Append）する：
  `[TIMESTAMP] [SCRIPT_NAME] [STATUS: PASS|FAIL] [CODE: ERROR_CODE] [MSG: ERROR_SUMMARY]`

### 3.2 検証ルール (Pre-Commit Hard-Gate)
1. **原帳不在時のFail-Closed**:
   - `logs/incident_execution_trace.log` が存在しない、0バイト、またはステージングされていない場合、コミットを拒否する：
     `[FATAL] [PROC-006] Execution trace log is missing or empty. Verification proof required.`
2. **追記専用（Append-Only）接頭辞検証**:
   - 前回コミット（`HEAD`）時点の `logs/incident_execution_trace.log` の全バイト列が、現在ステージングされたログの完全な接頭辞（Prefix）であることを検証する。
   - 過去の失敗ログを1行でも削除・切断・改ざんした場合、即時遮断する：
     `[FATAL] [PROC-006] Trace log truncation/mutation detected. History must be strictly append-only.`
3. **インシデント台帳との突合（Reconciliation）**:
   - 直前コミット以降に追加された `[STATUS: FAIL]` レコードについて：
     - 当該エラーコードまたはシグネチャが `logs/incident_history_ledger.md` に公式INCIDENTとして記載され、かつ状態が `RESOLVED` であることを全文字照合。
     - 未登録の失敗が1件でも残存している場合、コミットを拒否する：
       `[FATAL] [PROC-006] Unregistered failure detected in trace log. Registration in incident_history_ledger.md required.`
4. **再帰ループ遮断**:
   - ゲート自体の正当な遮断は `[STATUS: GATE_BLOCKED]` として記録され、これは `[STATUS: FAIL]` の突合対象外とすることで再帰的ループを防止する。

---

## 4. PROC-007: Orchestrator Self-Restraint & Audit Linkage Gate

### 4.1 目的および脅威モデル
オーケストレーター（Antigravity/Gemini）による以下の自律的逸脱を物理的に遮断する：
1. **SSOT直接執筆の横行**: 厳格なCodex初案パイプラインを経由せず、SSOTを直接手動編集して未検証テキストを混入させる行為。
2. **監査スキップおよび口頭承認**: 外部モデルによる交差監査を実行せず、あるいは失敗結果が出ているにもかかわらず、口頭で「検証完了」と詐称してコミットする行為。

### 4.2 3大物理的統制線
1. **統制線 1 (SSOT直接執筆遮断・単一チョークポイント強制)**:
   - SSOT（`srs_specification_ssot.md`）の直接編集ツール（`edit_file` / `write_file`）呼び出しを全面禁止。
   - Heavy Trackの更新は `tools/scripts/pipeline_draft_and_integrate.ps1`、Fast Trackの更新は `tools/scripts/patch_ssot_editorial.ps1` の単一スクリプト経由でのみ実行を許可する。
2. **統制線 2 (監査ログ物理結束・C#ハードゲート)**:
   - C#リンター（`VerifySRS.exe`）の Phase 9 において、Heavy Track資産の変更時、過去24時間以内の完了外部監査実機ログ（`audit/runs/` または `docs/audit_runs/` 内の非空ログ・`.done`）がディスク上に物理的に存在することを検証する。
   - 存在しない場合、直ちに `[FATAL] [PROC-007]` を送出してビルド・コミットを即時遮断する。
3. **統制線 3 (実物証跡事前ブリーフィング義務)**:
   - コミット提案時、エージェントは口頭説明を排除し、外部監査実機ログの絶対パス、欠陥0件証明、およびリンター合格出力をテーブル形式で事前提示し、ユーザーの明示的承認を待機する。

---

## 5. PROC-008: 先物理生成・後宣言義務および成果物実在性ゲート (Deliverable Pre-Existence Gate)

### 5.1 脅威モデルおよび発生機序
エージェントが総括報告書やマニフェスト、比較表（Markdown Table）において、**未作成のファイルを「先走って記述・宣言」し、物理ファイルの作成を失念したままコミットする幽霊ファイル（Ghost Deliverable）の混入**を根絶する。

### 5.2 2大物理統制線
1. **先(先)物理生成・後(後)インデックス宣言の厳格順序**:
   - いかなる総括報告書（`srs_track2_overall_synthesis_dossier.md`等）や比較表、マニフェストにおいても、対象ファイルがローカルディスク上に物理的に生成される前にテーブル行へ先行記述してはならない。
   - `verify_repo_total_integrity.ps1` の Check 10 において、Markdownテーブル内に記述された成果物（`*.md`）がリポジトリ内に物理的に実在することを決定論的にFail-Closed検証する。
2. **As-Built（観測実態）と Remediation（是正計画）の厳格な時系列分離**:
   - 逆工学仕様書（`asbuilt_slice*.md`）は実装実態（Before）のみを純粋に記述し、パッチや解決策（After）を「反映済み（RESOLVED）」と混同して記述することを禁止する。
   - 修正計画やパッチ検証結果は必ず「パッチ配備完了・Part 3反映待機（RESOLVED IN SPEC & PATCH READY）」と厳密に分離表記する。

---

## 6. 保証水準および例外規定 (Assurance Level & Exceptions)

1. **オフライン自律性**: 本ゲートは外部ネットワークに依存せず、Gitインデックスとローカル追跡原帳のみで決定論的（100% Fail-Closed）に判定する。
2. **監査証跡の永続性**: 生成された領収書およびトレースログはすべてGitリポジトリの正本としてコミットされ、事後監査可能性を完全に担保する。
