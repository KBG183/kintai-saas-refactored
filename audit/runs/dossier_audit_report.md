### [Hermes Audit Execution Metrics v1.2.0]
| Target File | Model | Duration | Input Code Tokens | Output Tokens | Speed | Done Reason | Run ID |
|---|---|---|---|---|---|---|---|
| docs/technical_audit_dossier.md | qwen27b:latest (IQ3_M) | 126.75s | 5192 tokens | 6124 tokens | 49.5 tokens/s | stop | 20261127_024924_bd6bb625 |

# Red-Team Labour Standards Audit: KINTAI SaaS Refactored

## 1. Interaction Matrix & Adversarial Simulation

### 1.1 Rule Extraction (Atomic Constraints)
*   **R1 (State Machine)**: `WORKING --> COMPLETED : 退勤打刻 (CLOCK_OUT)` and `WORKING --> ON_BREAK : 休憩開始 (BREAK_START)`.
*   **R2 (Payroll Guard)**: "未処理勤怠の締日ガード: 締め期間内に打刻中（`WORKING`, `ON_BREAK`）... が1件でも残存している場合、給与確定を拒絶。" (If any `WORKING` or `ON_BREAK` status remains, payroll confirmation is rejected).
*   **R3 (Modification Workflow)**: `COMPLETED --> MOD_REQUESTED : 修正申請 (MOD_REQUEST)` and `MOD_REQUESTED --> COMPLETED : 管理者承認 (APPROVE)`.
*   **R4 (Immutability)**: "既に月次給与が `CONFIRMED` または `PAID` となっている過去日付に対する修正申請は... 即時拒絶".
*   **R5 (Night Shift Definition)**: "22:00 〜 翌05:00 の実労働時間".
*   **R6 (Overtime Definition)**: "1日8時間（480分）を超過した労働時間".
*   **R7 (Split Shift Logic)**: "日累計実労働時間基準で480分超過分を正確に配分" (Daily cumulative basis for overtime).

### 1.2 Adversarial Simulation: The "Ghost Shift" Deadlock (P1/P4)

**Scenario**: A staff member works a night shift from 22:00 to 05:00 the next day. Due to a system crash, network failure, or user error, they fail to click `CLOCK_OUT` at 05:00. They leave the premises. The next day, they log in and attempt to start a new shift.

**Step-by-Step Walkthrough**:
1.  **22:00 (Day 1)**: Staff clicks `CLOCK_IN`. State: `WORKING`.
2.  **05:00 (Day 2)**: Staff leaves. State remains `WORKING` in the database.
3.  **09:00 (Day 2)**: Staff attempts to start a new shift (e.g., a morning shift).
    *   *System Check*: The state machine requires `[*] --> WORKING`. However, the previous record is still `WORKING`.
    *   *Conflict*: If the system enforces one active `WORKING` session per user, the new `CLOCK_IN` is rejected or creates a duplicate `WORKING` state (depending on DB constraints not fully specified, but logically a conflict).
    *   *Assumption*: Let's assume the system allows multiple `WORKING` records or forces a `CLOCK_OUT` first. If it forces `CLOCK_OUT`, the user must manually close the previous shift.
4.  **The Deadlock**: The user *cannot* close the previous shift because they are not physically present to "punch out" in a way that validates the time, or they simply forgot. They are now stuck in `WORKING` state.
5.  **Payroll Cutoff (End of Month)**: The `PayrollService` runs.
    *   *Guard Check*: "締め期間内に打刻中（`WORKING`...）... が1件でも残存している場合、給与確定を拒絶."
    *   *Result*: The entire payroll batch for that store/user fails to confirm.
6.  **The Trap**: To fix this, the user must submit a `MOD_REQUEST` to change the `CLOCK_OUT` time.
    *   *Workflow*: `COMPLETED --> MOD_REQUESTED`.
    *   *Problem*: The record is currently `WORKING`, not `COMPLETED`. The state machine diagram shows `WORKING --> COMPLETED : 退勤打刻 (CLOCK_OUT)`. It does *not* show `WORKING --> MOD_REQUESTED`.
    *   *Inference*: If the system strictly follows the state machine, a `WORKING` record cannot be modified directly. It must first be `COMPLETED`.
    *   *Action*: User must perform a `CLOCK_OUT` action.
    *   *Consequence*: The `CLOCK_OUT` time will be the *current* time (e.g., Day 3, 10:00 AM).
    *   *Result*: The system records 36+ hours of work (22:00 Day 1 to 10:00 Day 3).
    *   *Payroll Impact*: The user is paid for 36 hours of work they did not perform. This is a **P2 Record-vs-Reality Divergence**.
    *   *Correction Attempt*: Now the record is `COMPLETED`. User submits `MOD_REQUEST` to change `CLOCK_OUT` to 05:00 Day 2.
    *   *Approval*: Manager approves. Record becomes `COMPLETED` with correct times.
    *   *Payroll Re-run*: Payroll is recalculated.

**Critical Failure Mode**: What if the user *never* logs in again?
*   The record stays `WORKING`.
*   Payroll for that month is **blocked** (HTTP 409 / `IllegalStateException`).
*   The store owner cannot confirm payroll for *any* employee if one employee has a dangling `WORKING` state, unless the guard is per-employee. The text says "1件でも残存している" (if even 1 remains). If this is a global check for the batch, one forgotten punch blocks the entire store's payroll.
*   If the check is per-employee, that employee's payroll is blocked indefinitely until they log in and fix it.
*   **Legal Harm**: Unpaid wages (if the system refuses to pay until fixed) or Overpayment (if the system defaults to a max time). The spec says "給与確定を拒絶" (Reject payroll confirmation). This means **no one gets paid** for that period until the state is resolved. This is a **P0 Blocked-Terminator** scenario causing wage loss.

### 1.3 Adversarial Simulation: The Midnight Boundary (P3)

**Scenario**: Staff works 23:30 to 00:30.
*   **Night Band**: 22:00 - 05:00.
*   **Overtime**: > 480 mins/day.
*   **Calculation**:
    *   23:30 - 00:00 (30 mins) is Night.
    *   00:00 - 00:30 (30 mins) is Night.
    *   Total Night: 60 mins.
*   **Ambiguity**: The spec defines Night as "22:00 〜 翌05:00".
*   **Risk**: If the system calculates "Day" based on calendar date, 23:30-00:00 belongs to Day 1, and 00:00-00:30 belongs to Day 2.
*   **Overtime Calculation**: "日累計実労働時間基準" (Daily cumulative).
    *   If Day 1 has 8 hours of work ending at 23:30, and Day 2 starts at 00:00, the 480-minute threshold is split.
    *   Does the 480-minute threshold reset at 00:00 or at the end of the shift?
    *   Spec says: "1日8時間（480分）を超過した労働時間".
    *   If "1日" means calendar day, then 23:30-00:00 counts toward Day 1's 480, and 00:00-00:30 counts toward Day 2's 480.
    *   If "1日" means the shift period, it's different.
    *   Japanese Labor Standards Act (LSTA) typically defines "day" as the 24-hour period from 00:00 to 24:00 for statutory purposes, but overtime is often calculated per shift or per day depending on the agreement. The spec cites "LSTA Art 37".
    *   **Conflict**: The spec says "1日8時間". If a worker works 23:00-07:00 (8 hours), is it 8 hours of Day 1 and 0 hours of Day 2? Or 1 hour Day 1, 7 hours Day 2?
    *   If it's 1 hour Day 1, 7 hours Day 2, and they had 7 hours of work earlier in Day 1, they hit 8 hours in Day 1. The last hour of the night shift (06:00-07:00) is Day 2.
    *   **Finding**: The spec does not explicitly define how the 480-minute threshold handles the midnight crossover for *overtime* calculation, only that it's "daily cumulative". If the system groups by `workDate` (calendar date), a shift crossing midnight is split. If the user works 23:00-07:00, and has already worked 7 hours on Day 1, the 23:00-00:00 hour pushes Day 1 to 8 hours (no OT). The 00:00-07:00 is Day 2 (7 hours, no OT). Total OT = 0.
    *   However, if the "work day" is defined by the shift, it might be different. The spec says "日次グルーピング" (Daily grouping) by `workDate`. This implies calendar day.
    *   **Risk**: A worker working 23:00-07:00 every day might never trigger overtime if their daily calendar hours are split, even if they work 8 hours straight. This is a **P3 Boundary Instant** issue.

### 1.4 Adversarial Simulation: The "Silent Default" of Breaks (P6)

**Scenario**: Staff works 09:00 to 18:00. They take a 1-hour break from 12:00 to 13:00.
*   **State**: `WORKING` -> `ON_BREAK` -> `WORKING`.
*   **Punches**: `CLOCK_IN` (09:00), `BREAK_START` (12:00), `BREAK_END` (13:00), `CLOCK_OUT` (18:00).
*   **Net Work**: 8 hours.
*   **Overtime**: 0.
*   **What if they forget `BREAK_END`?**
    *   State: `ON_BREAK`.
    *   They work from 13:00 to 18:00.
    *   They click `CLOCK_OUT` at 18:00.
    *   Does `CLOCK_OUT` implicitly end the break?
    *   State Machine: `ON_BREAK --> WORKING : 休憩終了 (BREAK_END)`. `WORKING --> COMPLETED : 退勤打刻 (CLOCK_OUT)`.
    *   There is no direct transition `ON_BREAK --> COMPLETED`.
    *   Therefore, the user *must* click `BREAK_END` before `CLOCK_OUT`.
    *   If they forget `BREAK_END`, they are stuck in `ON_BREAK`.
    *   They cannot `CLOCK_OUT` (invalid transition).
    *   They must click `BREAK_END` (state becomes `WORKING`), then `CLOCK_OUT`.
    *   **Risk**: If the UI doesn't force this sequence, or if the API rejects `CLOCK_OUT` from `ON_BREAK`, the user is stuck.
    *   **Worse**: If the system *allows* `CLOCK_OUT` from `ON_BREAK` (implicit break end), the break duration is calculated from `BREAK_START` to `CLOCK_OUT`.
    *   If the user forgets `BREAK_START`?
    *   State: `WORKING`.
    *   They work 9 hours.
    *   Net work = 9 hours.
    *   Overtime = 1 hour.
    *   **Legal Issue**: If the break was not recorded, the "Net Work" is inflated. The user is paid for 9 hours of work, but legally, if they took a break, the net work might be 8 hours (if the break is unpaid and deducted).
    *   However, the spec says `netMinutes` is used for calculation. If the break is not recorded, `netMinutes` = Gross Minutes.
    *   If the break is *unpaid*, the user should not be paid for it. If the system calculates `netMinutes` as Gross - Breaks, and Breaks=0, then `netMinutes` = Gross.
    *   If the user *did* take a break but didn't record it, they are paid for the break time. This is an overpayment to the user, but a liability for the employer.
    *   **More Critical**: If the break is *paid* (common in some contracts), then not recording it is fine. But if the break is *unpaid*, and the user forgets to record it, they get paid for it.
    *   **Reverse**: If the user *must* record breaks to avoid overtime, and they forget, they get *more* overtime pay.
    *   **Deadlock**: If the system enforces a max break duration or requires break records for shifts > 4 hours, and the user forgets, the `CLOCK_OUT` might be rejected? No, the spec doesn't say that.
    *   **Finding**: The state machine does not handle the "Forgot Break" scenario gracefully. It relies on user discipline. If the user forgets `BREAK_START`, the system assumes continuous work. This is a **P6 Silent Default** issue.

## 2. Findings Table

| Finding ID | Attack Vector | Severity (P0/P1/P2/Info) | Verdict (PASS / WARN / FAIL / N/A) | Code & Test Evidence | Detailed Scenario & Recommendation |
|---|---|---|---|---|---|
| ADV-001 | P1 Blocked-Terminator | P0 | FAIL | **SPEC_QUOTE**: "未処理勤怠の締日ガード: 締め期間内に打刻中（`WORKING`, `ON_BREAK`）... が1件でも残存している場合、給与確定を拒絶." <br> **SPEC_QUOTE**: `WORKING --> COMPLETED : 退勤打刻 (CLOCK_OUT)` <br> **DERIVED**: No transition from `WORKING` to `MOD_REQUESTED`. | **Scenario**: A staff member forgets to `CLOCK_OUT` at the end of a shift. The record remains `WORKING`. At month-end, the payroll batch rejects confirmation for that employee (or store) because a `WORKING` record exists. The employee cannot submit a `MOD_REQUEST` because the state machine only allows `MOD_REQUEST` from `COMPLETED`. The employee is stuck in a deadlock where they cannot be paid until they manually `CLOCK_OUT` (which records the wrong time) and then `MOD_REQUEST` the correct time. If they never log in, their wages are indefinitely blocked. <br> **Recommendation**: Allow `MOD_REQUEST` from `WORKING` state, or provide an admin override to force-close `WORKING` states with a default time (e.g., 00:00 or last known activity) to unblock payroll. |
| ADV-002 | P3 Boundary Instant | P1 | WARN | **SPEC_QUOTE**: "1日8時間（480分）を超過した労働時間" <br> **SPEC_QUOTE**: "日次グルーピング" (Daily grouping) <br> **ASSUMPTION**: "1日" refers to calendar day (00:00-24:00). | **Scenario**: A staff member works 23:00 to 07:00. The system groups by calendar day. Day 1: 1 hour (23:00-00:00). Day 2: 7 hours (00:00-07:00). If the staff member worked 7 hours earlier on Day 1, their Day 1 total is 8 hours (no OT). Their Day 2 total is 7 hours (no OT). Total work: 15 hours. Total OT: 0. However, under LSTA, if the "work day" is defined by the shift, this might be incorrect. The spec does not clarify if "1日" is calendar day or shift day. This ambiguity can lead to underpayment of overtime for night workers. <br> **Recommendation**: Explicitly define "1日" for overtime calculation. If it is calendar day, ensure the UI warns users about midnight splits. If it is shift-based, implement shift-based grouping. |
| ADV-003 | P6 Silent Default | P1 | WARN | **SPEC_QUOTE**: `WORKING --> ON_BREAK : 休憩開始 (BREAK_START)` <br> **SPEC_QUOTE**: `ON_BREAK --> WORKING : 休憩終了 (BREAK_END)` <br> **DERIVED**: No automatic break deduction if `BREAK_START` is missed. | **Scenario**: A staff member works 09:00-18:00. They take an unpaid 1-hour break from 12:00-13:00 but forget to click `BREAK_START` and `BREAK_END`. The system records 9 hours of `WORKING` time. `netMinutes` = 540. Overtime = 60 minutes. The user is paid for 9 hours of work, including the unpaid break. This results in overpayment. Conversely, if the break was required to be recorded to avoid overtime, the user gets *more* overtime pay than they should. <br> **Recommendation**: Implement a "Break Reminder" or allow retroactive break insertion via `MOD_REQUEST`. Consider a default break deduction for shifts > 4 hours if no break is recorded, or flag such records for manual review. |
| ADV-004 | P4 Rule Collision | P1 | WARN | **SPEC_QUOTE**: "深夜時間帯と時間外労働が重複する時間" <br> **SPEC_QUOTE**: "nightAllowance(+25%) + overtimeAllowance(+25%) の加算方式" <br> **SPEC_QUOTE**: "休日深夜労働: 休日35% + 深夜25% の重複加算（時間外25%は通達に基づing免除）" | **Scenario**: A staff member works on a statutory holiday during the night (22:00-05:00). The spec says "休日深夜労働" gets 35% (holiday) + 25% (night) = 60% premium. It explicitly states "時間外25% is exempted". However, if the work also exceeds 480 minutes (overtime), does the 25% overtime premium apply? The spec says "時間外25% is exempted" for "休日深夜". This implies that even if it is overtime, the 25% OT premium is not added, only the 35% Holiday and 25% Night premiums. This is a specific legal interpretation. If the system incorrectly adds the 25% OT premium, it overpays. If it correctly exempts it, it must ensure the logic distinguishes between "Night Overtime" (150%) and "Holiday Night" (160%). The spec says "休日深夜" is 160%. If the system calculates 135% (Holiday) + 25% (Night) + 25% (OT) = 185%, it is wrong. <br> **Recommendation**: Verify that the calculation engine explicitly suppresses the 25% OT premium when the "Holiday Night" condition is met, regardless of whether the 480-minute threshold is exceeded. |
| ADV-005 | P7 Irreversibility | P2 | WARN | **SPEC_QUOTE**: "既に月次給与が `CONFIRMED` または `PAID` となっている過去日付に対する修正申請は... 即時拒絶" <br> **SPEC_QUOTE**: `payroll_daily_detail`: 給与確定時点の日別内訳スナップショット（帳簿不変性担保） | **Scenario**: A payroll is `CONFIRMED`. A critical error is found (e.g., wrong wage rate). The system rejects `MOD_REQUEST` for dates in that payroll. The only way to fix it is to reverse the payroll (if possible) or issue a manual adjustment. The spec does not mention a "Payroll Reversal" or "Correction Payroll" workflow. It only mentions `DRAFT` allows recalculation. Once `CONFIRMED`, it is immutable. This creates a high barrier to correcting errors, potentially leading to manual off-book payments, which breaks the audit trail. <br> **Recommendation**: Implement a "Payroll Correction" workflow that creates a new `DRAFT` payroll for the difference, or allows a "Reversal" entry that offsets the previous `CONFIRMED` payroll, maintaining the audit trail. |

```json
{
  "audit_engine": "Hermes-2Tier-Adversarial",
  "version": "1.2.0",
  "findings": [
    {
      "finding_id": "ADV-001",
      "vector": "P1 Blocked-Terminator",
      "severity": "P0",
      "verdict": "FAIL",
      "evidence": "SPEC_QUOTE: '未処理勤怠の締日ガード: 締め期間内に打刻中（WORKING, ON_BREAK）... が1件でも残存している場合、給与確定を拒絶.' SPEC_QUOTE: 'WORKING --> COMPLETED : 退勤打刻 (CLOCK_OUT)' DERIVED: No transition from WORKING to MOD_REQUESTED.",
      "scenario": "A staff member forgets to CLOCK_OUT. The record remains WORKING. At month-end, payroll confirmation is rejected because a WORKING record exists. The employee cannot submit a MOD_REQUEST because the state machine only allows MOD_REQUEST from COMPLETED. The employee is stuck in a deadlock where they cannot be paid until they manually CLOCK_OUT (recording wrong time) and then MOD_REQUEST the correct time. If they never log in, their wages are indefinitely blocked.",
      "recommendation": "Allow MOD_REQUEST from WORKING state, or provide an admin override to force-close WORKING states with a default time to unblock payroll."
    },
    {
      "finding_id": "ADV-002",
      "vector": "P3 Boundary Instant",
      "severity": "P1",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: '1日8時間（480分）を超過した労働時間' SPEC_QUOTE: '日次グルーピング' ASSUMPTION: '1日' refers to calendar day (00:00-24:00).",
      "scenario": "A staff member works 23:00 to 07:00. The system groups by calendar day. Day 1: 1 hour. Day 2: 7 hours. If the staff member worked 7 hours earlier on Day 1, their Day 1 total is 8 hours (no OT). Their Day 2 total is 7 hours (no OT). Total work: 15 hours. Total OT: 0. This may underpay overtime compared to a shift-based calculation.",
      "recommendation": "Explicitly define '1日' for overtime calculation. If it is calendar day, ensure the UI warns users about midnight splits. If it is shift-based, implement shift-based grouping."
    },
    {
      "finding_id": "ADV-003",
      "vector": "P6 Silent Default",
      "severity": "P1",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: 'WORKING --> ON_BREAK : 休憩開始 (BREAK_START)' SPEC_QUOTE: 'ON_BREAK --> WORKING : 休憩終了 (BREAK_END)' DERIVED: No automatic break deduction if BREAK_START is missed.",
      "scenario": "A staff member works 09:00-18:00. They take an unpaid 1-hour break but forget to click BREAK_START and BREAK_END. The system records 9 hours of WORKING time. netMinutes = 540. Overtime = 60 minutes. The user is paid for 9 hours of work, including the unpaid break. This results in overpayment.",
      "recommendation": "Implement a 'Break Reminder' or allow retroactive break insertion via MOD_REQUEST. Consider a default break deduction for shifts > 4 hours if no break is recorded."
    },
    {
      "finding_id": "ADV-004",
      "vector": "P4 Rule Collision",
      "severity": "P1",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: '深夜時間帯と時間外労働が重複する時間' SPEC_QUOTE: 'nightAllowance(+25%) + overtimeAllowance(+25%) の加算方式' SPEC_QUOTE: '休日深夜労働: 休日35% + 深夜25% の重複加算（時間外25%は通達に基づing免除）'",
      "scenario": "A staff member works on a statutory holiday during the night. The spec says '休日深夜労働' gets 35% (holiday) + 25% (night) = 60% premium. It explicitly states '時間外25% is exempted'. If the system incorrectly adds the 25% OT premium, it overpays. The logic must distinguish between 'Night Overtime' (150%) and 'Holiday Night' (160%).",
      "recommendation": "Verify that the calculation engine explicitly suppresses the 25% OT premium when the 'Holiday Night' condition is met, regardless of whether the 480-minute threshold is exceeded."
    },
    {
      "finding_id": "ADV-005",
      "vector": "P7 Irreversibility",
      "severity": "P2",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: '既に月次給与が CONFIRMED または PAID となっている過去日付に対する修正申請は... 即時拒絶' SPEC_QUOTE: 'payroll_daily_detail: 給与確定時点の日別内訳スナップショット（帳簿不変性担保）'",
      "scenario": "A payroll is CONFIRMED. A critical error is found. The system rejects MOD_REQUEST for dates in that payroll. The only way to fix it is to reverse the payroll (if possible) or issue a manual adjustment. The spec does not mention a 'Payroll Reversal' or 'Correction Payroll' workflow. This creates a high barrier to correcting errors.",
      "recommendation": "Implement a 'Payroll Correction' workflow that creates a new DRAFT payroll for the difference, or allows a 'Reversal' entry that offsets the previous CONFIRMED payroll."
    }
  ]
}
```