# 📊 KINTAI グローバル・エンティティ状態管理台帳 (Entity State Ledger)

> **対象エンティティ**: `member`, `store_staff`, `attendance`, `payroll`, `payroll_daily_detail`

---

## 1. エンティティ整合性マトリクス

| エンティティ | 主キー | 不変性条件 (Immutability) | 外部キー制約 | 排他制御方式 |
| :--- | :--- | :--- | :--- | :--- |
| `member` | `member_id` | 登録後の氏名変更は履歴追跡 | なし | 楽観的ロック (`version`) |
| `store_staff` | `staff_id` | 契約期間の重複禁止 | `store_id`, `member_id` | 複合ユニーク制約 |
| `attendance` | `attendance_id`| 月次確定後は更新禁止 | `staff_id`, `store_id` | 行レベル悲観的ロック |
| `payroll` | `payroll_id` | 確定 (`CONFIRMED`) 後の再計算不可 | `staff_id`, `store_id` | `SELECT ... FOR UPDATE` |
| `payroll_daily_detail` | `detail_id` | 日別支給スナップショット保持 | `payroll_id`, `attendance_id` | 親トランザクション連動 |
