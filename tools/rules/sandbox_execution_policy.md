# Codex・Antigravity 共通運用および交差監査規約

施行日: 2026-11-16

---

## 1. 基本原則（分業と相互牽制）

- **Antigravity (統括)**: プロジェクト全体の文脈把握、ファイル入出力制御、ユーザーインターフェース担当。
- **Codex CLI (監査官)**: ファイル書き込み権限のない `--sandbox read-only` モードで隔離実行され、要件定義書やコードの曖昧性、境界条件（Edge Case）の欠落、セキュリティ脆弱性、規約違反を独立して交差検証する。
- **ローカル Qwen 27B (生成器)**: GPU資源を活用し、要件定義ドラフトやユースケースシナリオの骨子を追加コスト0円で高速生成する。

---

## 2. 交差監査の実行手順

1. Antigravityが作成したSRSドラフトを一時ワークスペースに配置。
2. `tools/scripts/call_codex.ps1` を呼び出し、標準監査契約に基づき検証を実行。
3. Codexの出力から重大度（P0/P1/P2）を解析し、監査レポートに反映。
4. 指摘事項を `queue/srs_pending_findings.json` に登録・補正した後、C#決定論的リンター（`VerifySRS.exe`）および `verify_repo_total_integrity.ps1` による検証を実施。

---

## 3. 連動更新プロトコル

作業完了時、Antigravityはユーザーに対して以下の定型ブロックを提示する：

```markdown
### 📦 連動更新対象ファイルパッケージ
1. `config/srs_specification_ssot.md` (要件ID確定反映)
2. `logs/pipeline_metrics.md` (検証合格メトリクス最新化)
3. `logs/incident_history_ledger.md` (技術課題および再発防止記録)
4. `logs/CURRENT_STATUS.md` (プロジェクトステータス更新)
```
