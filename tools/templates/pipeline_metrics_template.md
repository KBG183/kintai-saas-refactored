# 📊 多層パイプライン検証メトリクス ＆ 監査ダッシュボード

最終更新: {{TODAY}} | システムバージョン: v1.02

---

## 🚦 1. パイプライン総合稼働状態 (Summary)
* **確定要件定義**: 単一真実原書（`config/srs_specification_ssot.md`）全{{TOTAL_REQ_COUNT}}要件
* **最新統合監査判定**: `{{LAST_STATUS}}`（`enterprise_audit_ledger.csv` {{LAST_BATCH_ID}} 準拠: {{LAST_NOTES}}）
* **C# 決定論的リンター**: `ONLINE`（`VerifySRS_Deterministic.cs` ＋ `VerifySRS_Integrity.cs` Fail-Closed 確定論的構文・無欠性検証）
* **Codex 独立交差監査**: `ONLINE`（無損失UTF-8バイトストリーム・GPT-6.2 Astra自動ルーティング対応）
* **ローカル Qwen 27B**: `ONLINE`（Ollama REST API・自社GPU RTX 5070 Ti P2P高速化）
* **Claude 深層法規監査**: `ONLINE`（Anthropic Claude Sonnet 5.5 労基法第37条・不変性深層検証）
* **最終検証ゲート**: `ACTIVE`（C#決定論的回帰テストスイート連動）

---

## 2. 要件完全性検証スコア (SSOT 全{{TOTAL_REQ_COUNT}}要件 - {{LAST_BATCH_ID}} 4層交差監査連動)
| ID | 要件項目 | C# リンター | Qwen 27B | Codex 監査 | Claude 5.5 | 最終判定 |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
{{MATRIX_TABLE}}

---

## 3. 監査・障害対応履歴
* **実運用障害・再発防止台帳**: [`incident_history_ledger.md`](../../logs/incident_history_ledger.md)（全30件の技術課題・恒久対策を記録）
* **監査実行台帳**: [`enterprise_audit_ledger.csv`](../../logs/enterprise_audit_ledger.csv)
* **クラウドトークン消費台帳**: [`cloud_api_token_ledger.csv`](../../logs/cloud_api_token_ledger.csv)
