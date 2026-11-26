# KINTAI 品質検証パイプライン 運用規約 v3.00 (Core Constitution)

施行日: 2026-11-26  
適用対象: アルバイト勤怠・給与管理SaaS（KINTAI Refactored）の実装リファクタリングおよび5層ハイブリッドAI検証システム

---

## 1. 目的および5層ハイブリッド検証アーキテクチャ
本規約は、プロジェクトにおけるコード品質および労務計算の整合性を担保するための最上位基準である。特定AIモデルへの依存や単一障害点を防ぐため、`AGENTS.md` で定義された5層Fail-Closed検証体制を維持する：
- **Stage 1: 決定論的ゲート (`./gradlew check`)**: コンパイル検証、JUnit 5単体・統合テスト、ArchUnit（給与・サービス層の浮動小数点型禁止、レイヤ分離）、MyBatis `${}` SQLインジェクション静的検知、Zero-Korean検証を実行する。
- **Stage 2: ローカルファネルスクリーニング (`call_qwen.ps1`)**: 自社GPU（RTX 5070 Ti）上の `qwen3.8:27b` により、`git diff` 対象ファイルおよび関連サービスの一次スクリーニングを実施する。
- **Stage 3: クラウドAI交差監査 (`call_claude.ps1`, `call_codex.ps1`)**:
  - **Anthropic Claude**: 日本労働基準法第37条の割増率・50銭端数処理・例外分岐の推論監査。
  - **OpenAI Codex CLI**: Spring Boot 4 / MyBatisアーキテクチャ、悲観的ロック（`SELECT ... FOR UPDATE`）、IDOR防御の監査。
- **Stage 4: 実証引用検証 (Proof-First Citation Verifier)**: 監査レポート内の `[相対パス:行番号]` 引用と実コードの照合、および `PARSE_DRIFT` 検知を行う。
- **Stage 5: Fail-Closed判定および監査台帳保存**: 未解決のP0/P1重大欠陥またはパース不整合を検知した場合、パイプライン（`tools/scripts/run_kintai_pipeline.ps1`）を非ゼロ終了コードで遮断し、`audit/runs/` 配下に検証ログを保存する。

## 2. 情報優先順位およびSSOT原則
1. ユーザーからの最新指示 ＞ 2. 本規約および `AGENTS.md` ＞ 3. ドメイン専門監査プロンプト（`tools/prompts/`） ＞ 4. 実装コードおよびテスト ＞ 5. モデル内部知識。  
仕様の齟齬は独断で補完せずユーザーに確認する。Fail-Closedゲートは明示的承認なしに解除されない。

## 3. ドメイン専門監査プロンプトの適用
`tools/scripts/run_kintai_pipeline.ps1` は変更対象ファイルに応じて `tools/prompts/` 配下の専門プロンプトを自動結合する：
- **[労働基準法第37条]**: `tools/prompts/audit_labor_law_37.md`
- **[並行処理・排他制御]**: `tools/prompts/audit_concurrency_lock.md`
- **[認可・IDOR・SQL安全性]**: `tools/prompts/audit_idor_security.md`

## 4. 変更権限およびコミット承認ワークフロー (Fail-Closed)
読み取り、静的解析、`./gradlew check`、各AI監査は常時実行可能。外部CLIは無出力ストリーミングラッパー（`tools/scripts/call_codex.ps1` 等）経由で実行する。`git commit` および `git push` は日本語原文・韓国語対訳の事前提示後、ユーザーの明示的コミット指示を確認してから同期実行する。

## 5. 多言語ガバナンスおよびZero-Koreanゲート
GitHub公開成果物（`src/`, `README.md`, `AGENTS.md`, `GEMINI.md`, `.github/`, `tools/prompts/`, `docs/`）は正統なビジネス日本語（JA）または標準英語を正本とする。コミット直前にステージング全ファイルおよびコミットメッセージの韓国語（`[\uAC00-\uD7A3]`）を機械的にスキャンし、検知時は即時中断する。韓国語作業メモは `*_KO*` 命名によりローカルへ隔離する。

## 6. 客観的エビデンス主義および誇張表現の排除
工学的に成立しない絶対的保証や誇張・情緒的修飾語を排除する。記述は具体的コード、DB制約、JUnitテスト結果、実測メトリクス等の物理的証拠のみに基づく。

## 7. 事前検証および変更整合性
コード変更時は対応するJUnit 5単体・統合テストおよび `./gradlew check` の通過を必須とする。未実装の機能や未作成の成果物を完了済みとして先行記載することを禁止する。

## 8. インラインPowerShell実行制限 (INCIDENT-62)
複数行や変数展開を伴うPowerShellは、`scratch/` 配下にUTF-8物理スクリプト（`.ps1`）を作成し単一呼出で実行する。冒頭に `$ErrorActionPreference = 'Stop'` および UTF-8 宣言を必須とする。

## 9. 結果報告基準
報告は実測数値、変更ファイル、実行した検証コマンドとその結果に基づく簡潔なファクト報告とする。WARN/FAIL発生時は原因・影響範囲・残存リスクを明示する。

## 10. 作業開始と出力基準
3段階以上の作業は `update_steps` でチェックリストを画面上部に固定し、対話本文での機械的な進行予告やステップ番号の言及を抑制する。全作業完了時にのみ最終結果を単1回報告する。
