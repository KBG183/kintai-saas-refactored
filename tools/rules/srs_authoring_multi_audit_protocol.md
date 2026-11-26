# 多層AI交差検証プロトコル

施行日: 2026-11-25

---

## 1. 5重多層AI交差検証アーキテクチャ (Role-Swap)

本プロトコルは、アルバイト勤怠・給与管理SaaS（KINTAI）の要件定義書および実装コードの多層検証を標準化する。常に「執筆者1者 ＋ 独立交差監査4者」による計5重パイプライン体制を維持する。

- **Fast Track**: 執筆［Antigravity］ ＋ 独立4重交差監査［①Codex, ②Claude, ③Qwen 27B, ④VerifySRS.exe］
- **Heavy Track**: 執筆［Codex］ ＋ 独立4重交差監査［①Antigravity（第1監査官）, ②Claude, ③Qwen 27B, ④VerifySRS.exe］

### 構成要素と役割
- **Antigravity (Gemini)**: 統括オーケストレーション、Fast Track執筆、Heavy Track第1監査（SSOT対照・コード精査）。
- **OpenAI Codex CLI (`call_codex.ps1`)**: Heavy Track初案執筆、Fast Track交差監査。
- **Anthropic Claude (`call_claude.ps1`)**: 労働基準法第34条（休憩）・第37条（割増）計算、端数処理、並行性例外分岐の深層交差監査。
- **ローカル Qwen 27B (`call_qwen.ps1`)**: 自社GPU（RTX 5070 Ti）を活用した高速整合性・状態遷移回帰チェック。
- **C# 決定論的リンター (`VerifySRS.exe v1.2`)**: 構文、書式、DoD（定義完了条件）の機械式Fail-Closed遮断。

---

## 2. 判定区分 (Verdict)

- **PASS**: 指摘事項なし、または軽微な情報（Info）のみ。
- **WARN**: 仕様記述の補足や業務ルールの明確化が推奨される事項。
- **FAIL**: 法令違反、データ破損リスク、並行性デッドロック、セキュリティ脆弱性（P0/P1）。

すべてのFAIL項目は、コード改修およびテストコードによる実証証跡が提出されるまで解消と見なされない（Fail-Closed原則）。
