### [Hermes Audit Execution Metrics v1.2.0]
| Target File | Model | Duration | Input Code Tokens | Output Tokens | Speed | Done Reason | Run ID |
|---|---|---|---|---|---|---|---|
| src/main/java/com/example/kintai/domain/payroll/service/PayrollService.java | qwen27b:latest (IQ3_M) | 109.08s | 5500 tokens | 4917 tokens | 49.6 tokens/s | stop | 20261127_023519_5419849f |

### Interaction Matrix & Adversarial Simulation

**1. Rule Extraction (Atomic Constraints)**
*   **R1 (Immutability):** "既に確定(CONFIRMED)または支払済(PAID)の給与データが存在する場合は再計算・上書きを遮断" (If CONFIRMED or PAID, block recalculation).
*   **R2 (Unresolved Block):** "未承認または打刻途中の勤怠が存在するため、給与計算を中断しました" (If unresolved attendance exists, interrupt calculation).
*   **R3 (Wage Validation):** "勤務日 (...) に有効な契約時給データが存在しません" (If no valid hourly wage for a work date, throw exception).
*   **R4 (Confirmation Timing):** "精算対象期間 (...) が終了する前に給与を確定することはできません" (Cannot confirm before `rangeEndDate`).
*   **R5 (Recalculation on Confirm):** `confirmPayroll` calls `calculatePayrollForStaff` internally.
*   **R6 (Transport Cap):** `transportLimit` is fetched once per calculation run based on `endDate`.

**2. Event & State Extraction**
*   **States:** `DRAFT`, `CONFIRMED`, `PAID`.
*   **Events:** `CLOCK_IN`, `CLOCK_OUT`, `WAGE_CHANGE`, `PAYROLL_CALCULATE`, `PAYROLL_CONFIRM`, `PAYROLL_PAY`.
*   **Critical Dependency:** `calculatePayrollForStaff` depends on `attendanceMapper.findCompletedAttendancesForStaffAndPeriod` and `payrollMapper.findHourlyWageForStaffOnDate`.

**3. Interaction Matrix (Guard vs. Event)**
*   **Guard:** `if (hourlyWageVal == null || hourlyWageVal <= 0) throw ...`
*   **Event:** Employee works on Day X. HR updates wage effective Day X+1 (or retroactively fixes a missing wage record for Day X).
*   **Conflict:** If the wage record for Day X is missing or invalid *at the time of calculation*, the entire payroll calculation for the month fails.

**4. Adversarial Simulation**
*   **Scenario A: The "Missing Wage" Deadlock (P1/P4)**
    1.  Employee works from Jan 1 to Jan 31.
    2.  On Jan 15, HR realizes the wage record for Jan 1-10 was never created or was set to 0 due to a data entry error.
    3.  Manager attempts to run `calculateMonthlyPayroll` for January on Feb 1.
    4.  System iterates through attendances. It hits Jan 1.
    5.  `payrollMapper.findHourlyWageForStaffOnDate(staffId, Jan 1)` returns `null` or `0`.
    5.  System throws `IllegalStateException`.
    6.  **Result:** The payroll for the *entire month* cannot be generated. The employee has worked 31 days, but the system refuses to record any wages because one day's wage metadata is missing. This creates an "Unrecorded Work" state. The manager *must* fix the wage record before payroll can run. If the manager forgets to fix it until after the payment deadline, wages are delayed.
    7.  **Worse Case:** If the wage record is *deleted* (soft delete or hard delete) after the fact, the system throws an exception. There is no "default wage" fallback.

*   **Scenario B: The "Split Shift" Overtime Recalculation Flaw (P2)**
    1.  Employee has two shifts on Jan 5: 08:00-12:00 (240 min) and 13:00-17:00 (240 min). Total 480 min.
    2.  `attendancesByDate` groups them.
    3.  Loop 1: `prevAccumulated` = 0. `dayAccumulatedNet` = 240. `240 > 480` is False. `overtimeMinutes` = 0.
    4.  Loop 2: `prevAccumulated` = 240. `dayAccumulatedNet` = 480. `480 > 480` is False. `overtimeMinutes` = 0.
    5.  **Result:** 0 Overtime. Correct.
    6.  **Adversarial Case:** Employee works 08:00-12:00 (240 min) and 13:00-18:00 (300 min). Total 540 min.
    7.  Loop 1: `dayAccumulatedNet` = 240. OT = 0.
    8.  Loop 2: `prevAccumulated` = 240. `dayAccumulatedNet` = 540. `540 > 480` is True.
    9.  `dayOvertime` = `540 - 480` = 60.
    10. `att.setOvertimeMinutes(60)`.
    11. **Result:** The *second* attendance record gets 60 mins OT. The first gets 0.
    12. **Impact:** If the wage rate changed between the two shifts (unlikely but possible in complex contracts) or if the "Night" flag differs, the calculation might be skewed. However, the bigger issue is that `att.setOvertimeMinutes` modifies the DTO in memory. If `att` is reused elsewhere or if the order of `dayList` is not guaranteed to be chronological (e.g., if DB returns them out of order), the "excess" calculation is wrong. `LinkedHashMap` preserves insertion order, but `findCompletedAttendancesForStaffAndPeriod` must guarantee chronological order. If it returns them by `attendance_id` (which might not be chronological if corrections are inserted), the OT allocation is arbitrary.

*   **Scenario C: The "Confirm" Recalculation Race (P6)**
    1.  Manager clicks "Confirm".
    2.  `confirmPayroll` acquires lock.
    3.  Checks status is DRAFT.
    4.  Calls `calculatePayrollForStaff`.
    5.  Inside `calculatePayrollForStaff`, it calls `payrollMapper.lockStoreStaffForUpdate(staffId)`.
    6.  **Deadlock Risk:** `confirmPayroll` already holds a lock on the Payroll row (`findByIdForUpdate`). `calculatePayrollForStaff` tries to lock the StoreStaff row. If another transaction is holding the StoreStaff lock and waiting for the Payroll lock (e.g., a concurrent payroll calculation for a different month that touches the same staff), we have a classic deadlock or long wait.
    7.  More critically: `calculatePayrollForStaff` performs an `upsertPayroll`. If the `confirmPayroll` transaction fails *after* the upsert but before the status update to CONFIRMED, the DB rolls back. This is safe.
    8.  **However:** `calculatePayrollForStaff` throws an exception if `unresolvedCount > 0`. If an attendance correction is submitted *between* the initial check in `confirmPayroll` and the re-check inside `calculatePayrollForStaff` (which is unlikely due to the lock, but possible if the lock scope is narrow), it throws.
    9.  **Real Issue:** `confirmPayroll` calls `calculatePayrollForStaff` which *re-calculates* everything. If the `expectedGrossPay` in the DTO was calculated by a *previous* version of the code or a different logic path, and the logic has changed, the confirmation fails. This is a "Silent Default" failure mode where the UI might show a stale number.

*   **Scenario D: The "Transport Allowance" Cap Reset (P5)**
    1.  `transportLimit` is fetched once.
    2.  `totalTransportAllowance` accumulates.
    3.  If the employee works in multiple stores (not supported here, but `storeId` is passed), the cap is per store.
    4.  **Issue:** `findDailyTransportFeeForStaffOnDate` is called for *every* worked date. If the fee is the same, it's fine. But if the fee changes mid-month, the cap logic `Math.min(dailyTransport, remainingLimit)` works.
    5.  **Edge Case:** What if `dailyTransport` is negative? `Math.min` handles it, but `totalTransportAllowance` could decrease. Unlikely but possible if data is corrupted.

**5. Adjudication Across 7 Attack Vectors**

*   **P1 Blocked-Terminator:** **FAIL.** The `IllegalStateException` on missing wage data blocks the *entire* payroll generation. If a single day's wage record is missing, the employee's entire month's wages are "unrecorded" in the system until the data is fixed. This creates a legal risk of unpaid wages if the fix is delayed.
*   **P2 Record-vs-Reality Divergence:** **WARN.** The overtime calculation relies on the order of `attendances` in the list. If the DB query does not explicitly `ORDER BY clock_in_at`, the "excess" overtime minutes are assigned to the wrong attendance record. This causes the "Night Overtime" calculation (which depends on `att.getNightWorkMinutes()`) to be incorrect if the night shift was the first or second shift.
*   **P3 Boundary Instant:** **PASS.** `LocalDate` and `LocalDateTime` are used correctly with `ZoneId.of("Asia/Tokyo")` for the confirmation check.
*   **P4 Rule Collision:** **FAIL.** Collision between "Must calculate payroll" and "Must have valid wage for every day". There is no fallback.
*   **P5 Aggregation Gap:** **PASS.** The code explicitly handles the monthly cap for transport.
*   **P6 Silent Default:** **WARN.** `appliedHourlyWage` is set to `null` if `uniqueWages.size() != 1`. This is a "Silent Default" that hides data integrity issues. If an employee's wage changed mid-month, the summary field `appliedHourlyWage` becomes `null`, which might cause NPEs in downstream reporting or UIs that expect a value.
*   **P7 Irreversibility:** **PASS.** The `CONFIRMED` status prevents recalculation.

### Findings Table

| Finding ID | Attack Vector | Severity (P0/P1/P2/Info) | Verdict (PASS / WARN / FAIL / N/A) | Code & Test Evidence | Detailed Scenario & Recommendation |
|---|---|---|---|---|---|
| ADV-001 | P1 Blocked-Terminator | P0 | FAIL | `if (hourlyWageVal == null \|\| hourlyWageVal <= 0) { throw new IllegalStateException(...); }` | **Scenario:** An employee works 31 days. The wage record for Day 1 is missing due to a data entry error. The manager attempts to run payroll. The system throws an exception for the *entire month*. The employee's work is effectively "unrecorded" in the payroll system until the data is fixed. If the fix is delayed past the payment deadline, this constitutes unpaid labor. <br>**Recommendation:** Do not throw a hard exception for missing wage data during calculation. Instead, log a critical error, use a default/fallback wage (e.g., previous day's wage or store minimum), and flag the payroll record as "DATA_ERROR" for manual review. This ensures wages are recorded (even if estimated) and the work is not lost. |
| ADV-002 | P2 Record-vs-Reality Divergence | P1 | WARN | `for (AttendanceDto att : dayList) { ... att.setOvertimeMinutes(dayOvertime); }` | **Scenario:** The `attendances` list is not guaranteed to be sorted by `clock_in_at`. If the DB returns the 2nd shift before the 1st shift, the "excess" overtime calculation (`dayAccumulatedNet > 480`) will assign the overtime minutes to the wrong attendance record. Since `nightOvertime` is calculated based on `att.getNightWorkMinutes()`, if the night shift was the "first" in the list but should have been the "second" chronologically, the night overtime premium might be applied to the wrong base wage or incorrectly calculated. <br>**Recommendation:** Explicitly sort `dayList` by `clock_in_at` (or `start_time`) before processing the split-shift logic. |
| ADV-003 | P6 Silent Default | P2 | WARN | `Integer appliedHourlyWage = (uniqueWages.size() == 1) ? uniqueWages.iterator().next() : null;` | **Scenario:** An employee's hourly wage changes from 1000 to 1200 mid-month. `uniqueWages` contains {1000, 1200}. `appliedHourlyWage` is set to `null`. Downstream reports or UIs that display "Applied Wage" will show `null` or `0`, causing confusion and potential audit failures, even though the daily details are correct. <br>**Recommendation:** Store the *minimum* and *maximum* wage, or a list of wages, or simply store `null` but ensure all consumers handle `null` gracefully. Better yet, store the wage used for the *majority* of hours or the wage on the last day, and clearly label it. |
| ADV-004 | P4 Rule Collision | P1 | FAIL | `if (unresolvedCount > 0) { throw new IllegalStateException(...); }` inside `calculatePayrollForStaff` | **Scenario:** The `confirmPayroll` method calls `calculatePayrollForStaff`. If there is *any* unresolved attendance (e.g., a pending correction request), the confirmation fails. However, the user might have intended to confirm the payroll *based on the current data* and handle the correction separately. The system forces a "all or nothing" approach. If a single attendance record is stuck in "PENDING" state due to a bug, the entire payroll confirmation is blocked. <br>**Recommendation:** Allow confirmation with a warning if unresolved items exist, or provide a "Force Confirm" option that snapshots the current state and marks the unresolved items as "Overridden". |
| ADV-005 | P7 Irreversibility | P2 | WARN | `payrollMapper.upsertPayroll(payroll);` inside `calculatePayrollForStaff` | **Scenario:** `calculatePayrollForStaff` is called from `confirmPayroll`. It performs an `upsert`. If the `confirmPayroll` transaction fails *after* the upsert (e.g., due to a network timeout during the status update), the DB rolls back. This is safe. However, if the `upsert` succeeds and the `updatePayrollStatusConfirm` fails, the payroll is in `DRAFT` state with new data. This is acceptable. The risk is if `calculatePayrollForStaff` is called *outside* of a transaction that includes the status update. In this code, it is called within `confirmPayroll` which is `@Transactional`. So this is safe. <br>**Verdict:** PASS (Revised). The transactional boundary is correct. |
| ADV-006 | P3 Boundary Instant | P2 | WARN | `LocalDate todayJst = LocalDate.now(ZoneId.of("Asia/Tokyo"));` | **Scenario:** The check `if (!todayJst.isAfter(existing.getRangeEndDate()))` prevents confirmation *on* the last day of the range. If the range ends on Jan 31, you cannot confirm on Jan 31. You must wait until Feb 1. This is a business rule, but it might be too strict. If the store closes on Jan 31, the manager might want to confirm on Jan 31. <br>**Recommendation:** Clarify if "after" means strictly after (next day) or if it should allow confirmation on the last day. If the business rule is "must be after the end date", this is correct. If it is "must be on or after", change to `!todayJst.isBefore(...)`. |

### JSON Output

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
      "evidence": "if (hourlyWageVal == null || hourlyWageVal <= 0) { throw new IllegalStateException(\"勤務日 (\" + workDate + \") に有効な契約時給データが存在しません。\"); }",
      "scenario": "An employee works 31 days. The wage record for Day 1 is missing due to a data entry error. The manager attempts to run payroll. The system throws an exception for the entire month. The employee's work is effectively 'unrecorded' in the payroll system until the data is fixed. If the fix is delayed past the payment deadline, this constitutes unpaid labor.",
      "recommendation": "Do not throw a hard exception for missing wage data during calculation. Instead, log a critical error, use a default/fallback wage (e.g., previous day's wage or store minimum), and flag the payroll record as 'DATA_ERROR' for manual review. This ensures wages are recorded (even if estimated) and the work is not lost."
    },
    {
      "finding_id": "ADV-002",
      "vector": "P2 Record-vs-Reality Divergence",
      "severity": "P1",
      "verdict": "WARN",
      "evidence": "for (AttendanceDto att : dayList) { ... att.setOvertimeMinutes(dayOvertime); }",
      "scenario": "The 'attendances' list is not guaranteed to be sorted by 'clock_in_at'. If the DB returns the 2nd shift before the 1st shift, the 'excess' overtime calculation will assign the overtime minutes to the wrong attendance record. Since 'nightOvertime' is calculated based on 'att.getNightWorkMinutes()', if the night shift was the 'first' in the list but should have been the 'second' chronologically, the night overtime premium might be applied to the wrong base wage or incorrectly calculated.",
      "recommendation": "Explicitly sort 'dayList' by 'clock_in_at' (or 'start_time') before processing the split-shift logic."
    },
    {
      "finding_id": "ADV-003",
      "vector": "P6 Silent Default",
      "severity": "P2",
      "verdict": "WARN",
      "evidence": "Integer appliedHourlyWage = (uniqueWages.size() == 1) ? uniqueWages.iterator().next() : null;",
      "scenario": "An employee's hourly wage changes from 1000 to 1200 mid-month. 'uniqueWages' contains {1000, 1200}. 'appliedHourlyWage' is set to 'null'. Downstream reports or UIs that display 'Applied Wage' will show 'null' or '0', causing confusion and potential audit failures, even though the daily details are correct.",
      "recommendation": "Store the minimum and maximum wage, or a list of wages, or simply store 'null' but ensure all consumers handle 'null' gracefully. Better yet, store the wage used for the majority of hours or the wage on the last day, and clearly label it."
    },
    {
      "finding_id": "ADV-004",
      "vector": "P4 Rule Collision",
      "severity": "P1",
      "verdict": "FAIL",
      "evidence": "if (unresolvedCount > 0) { throw new IllegalStateException(\"未承認または打刻途中の勤怠が存在するため、給与計算を中断しました。(職員ID: \" + staffId + \")\"); }",
      "scenario": "The 'confirmPayroll' method calls 'calculatePayrollForStaff'. If there is any unresolved attendance (e.g., a pending correction request), the confirmation fails. However, the user might have intended to confirm the payroll based on the current data and handle the correction separately. The system forces an 'all or nothing' approach. If a single attendance record is stuck in 'PENDING' state due to a bug, the entire payroll confirmation is blocked.",
      "recommendation": "Allow confirmation with a warning if unresolved items exist, or provide a 'Force Confirm' option that snapshots the current state and marks the unresolved items as 'Overridden'."
    },
    {
      "finding_id": "ADV-005",
      "vector": "P3 Boundary Instant",
      "severity": "P2",
      "verdict": "WARN",
      "evidence": "LocalDate todayJst = LocalDate.now(ZoneId.of(\"Asia/Tokyo\")); if (!todayJst.isAfter(existing.getRangeEndDate())) { throw new IllegalStateException(...); }",
      "scenario": "The check 'if (!todayJst.isAfter(existing.getRangeEndDate()))' prevents confirmation on the last day of the range. If the range ends on Jan 31, you cannot confirm on Jan 31. You must wait until Feb 1. This is a business rule, but it might be too strict. If the store closes on Jan 31, the manager might want to confirm on Jan 31.",
      "recommendation": "Clarify if 'after' means strictly after (next day) or if it should allow confirmation on the last day. If the business rule is 'must be after the end date', this is correct. If it is 'must be on or after', change to '!todayJst.isBefore(...)'."
    }
  ]
}
```