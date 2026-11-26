# KINTAI 開発・運用スクリプト カタログ仕様書

- 作成日: 2026-11-24
- 状態: STABLE (全27スクリプト検証済み)
- 適用対象: `tools/scripts/` 配下の全実行可能ファイルおよびエンジン群

---

## 1. 概要

`tools/scripts/` ディレクトリは、アルバイト勤怠・給与管理SaaS（KINTAI）の要件定義書（SRS）作成、多層AIハイブリッド交差検証、および決定論的リポジトリ無欠性保証を担う実行エンジン群を格納しています。
本カタログは、平坦に配置された全資産の責務境界と呼び出しインターフェースを明確化し、将来の保守性を担保するために策定されました。

---

## 2. ツール分類マトリクス

全資産を用途および実行レイヤーに応じて以下の4つのカテゴリに分類します。

| カテゴリ | ファイル一覧 | 主な責務・実行内容 | ガバナンス・実行権限 |
|---|---|---|---|
| **① 決定論的検証・リンター** | `VerifySRS.cs`, `VerifySRS.exe`, `verify_srs.ps1`, `verify_integrity.ps1`, `verify_repo_total_integrity.ps1`, `TestV52Suite_Regression.cs`, `TestV52Suite_Regression.exe` | 構文・書式・DoD・IDOR・全12ゲートをコンパイラレベルで機械的に検証（Fail-Closed） | CIおよびGit事前フックで自動実行 |
| **② マルチAIオーケストレーター** | `call_ai.ps1`, `call_codex.ps1`, `call_claude.ps1`, `call_qwen.ps1`, `run_quad_audit.ps1`, `hermes_controller.ps1`, `AuditVerdictHelper.psm1`, `route_audit.ps1`, `run_lab_benchmark.ps1` | OpenAI Codex、Anthropic Claude、ローカルQwen 27B（RTX 5070 Ti）のストリーミング呼び出し・交差監査調停 | 読み取り専用隔離・無出力ファイルラッパー |
| **③ SSOTパッチ・台帳運用** | `patch_ssot.ps1`, `patch_ssot_editorial.ps1`, `patch_ssot_literal.ps1`, `finalize_daily_ledgers.ps1`, `sync_dashboard.ps1`, `sync_all_mirrors.ps1`, `sync_domain_mirror.ps1`, `bundle_diff_context.ps1`, `extract_ddl_spec.ps1`, `pipeline_draft_and_integrate.ps1`, `gate_master_srs.ps1`, `gate_phase3.ps1`, `audit_srs.ps1` | SSOTへのアトミックパッチ適用、スプリント終了時の6大台帳整合性検証・自動登録 | 編集権限はチョークポイント経由に限定 |
| **④ フック・テスト・デモ** | `install_hooks.ps1`, `test_git_hooks.ps1`, `demo_offline_replay.ps1` | Git事前検証フックの導入・構文検証、APIキー不要の3秒オフライン回帰デモ再生 | 開発者ローカル環境の即時立ち上げ |

---

## 3. 主要カノニカルエントリポイント一覧

以下のスクリプトは、CI/CD、Gitフック、および運営憲法（`GEMINI.md`）から直接参照される中核エントリポイントであり、パス変更が厳禁とされています。

| カノニカルツール | コマンド実行例 | 期待される実行結果 |
|---|---|---|
| `VerifySRS.exe` | `.\tools\scripts\VerifySRS.exe config\srs_specification_ssot.md` | SSOT単一真実原書のテキスト・DoD・IDOR静的検証（0 FAIL PASS） |
| `verify_repo_total_integrity.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\verify_repo_total_integrity.ps1 -NoLog` | 全12大無欠性ゲート（Zero-Korean、CSV整合性、リンク等）全件パス |
| `run_quad_audit.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\run_quad_audit.ps1 -TargetFile config\srs_specification_ssot.md` | Codex / Claude / Qwen / VerifySRS による4重交差検証リレー実行 |
| `finalize_daily_ledgers.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\finalize_daily_ledgers.ps1 -Stage` | 6大台帳の整合性確認、CSV-004検証、およびGitステージング自動完了 |
| `test_git_hooks.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\test_git_hooks.ps1` | pre-commitフックのBash構文およびZero-Koreanポリシー適合性確認 |

---

## 4. 実行環境および依存仕様

- **PowerShellエンジン**: Windows PowerShell 5.1 または PowerShell 7+（UTF-8 No BOM、`$ErrorActionPreference = 'Stop'` 必須）。
- **C# Roslynコンパイラ**: `.NET Framework 4.0` 互換 `csc.exe`（CI環境での動的自動コンパイル対応）。
- **外部AI実行環境**: OpenAI Codex CLI（隔離サンドボックス）、Anthropic Claude API、Tailscale P2P経由の自社GPU Ollamaエンドポイント。
