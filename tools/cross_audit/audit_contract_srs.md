# 要件定義交差監査契約仕様書 (Audit Contract Spec)

---

## 1. 監査入力仕様
- 監査対象ファイル: `config/srs_specification_ssot.md`
- 関連スキーマ: `domain_target/02_database_schema_ssot/schema.sql`
- ドメインサービス: `domain_target/03_core_domain_services/`

## 2. 必須検証観点
1. **労働基準法第37条準拠性**: 深夜業（22:00〜05:00）、時間外労働（1日8時間超）、休日割増の算定ロジック。
2. **端数処理の整合性**: 昭和63年基発第150号に基づく月間合算処理および日次計算方針。
3. **並行性およびデッドロック防止**: 親行ロック順序整列（`store_staff -> payroll`）および二重打刻防止。
4. **セキュリティ境界**: IDOR脆弱性排除、セッションPrincipal検証、RBAC分離。
