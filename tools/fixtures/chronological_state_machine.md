# 🔄 KINTAI 勤怠・給与トランザクション時系列状態遷移マシン (State Machine)

> **定義スコープ**: 打刻レコードライフサイクルおよび月次給与確定トランザクション

---

## 1. 勤怠打刻状態マシン (Attendance Record Lifecycle)

```text
[UNPUNCHED] ──(出勤打刻)──> [WORKING] ──(休憩開始)──> [BREAK]
                                │                          │
                                │                      (休憩終了)
                                ▼                          │
                            [WORKING] <────────────────────┘
                                │
                            (退勤打刻)
                                ▼
                           [COMPLETED] ──(修正申請)──> [PENDING_APPROVAL]
                                │                               │
                           (月次確定)                      (店長承認/却下)
                                ▼                               ▼
                            [LOCKED] <─────────────────────[COMPLETED]
```

### 遷移規則および不変性条件
1. **WORKING**: `clock_in_at` 記録済み、`clock_out_at` は NULL。
2. **BREAK**: `break_start_at` 記録中、無給控除タイマー稼働。
3. **COMPLETED**: 出勤および退勤打刻が完了し、総実労働時間・深夜労働時間が分単位で確定。
4. **LOCKED**: 月次給与締めに組み込まれ、以後の打刻直接修正をDB悲観的ロックで遮断。
