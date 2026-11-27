### [Hermes Audit Execution Metrics v1.2.0]
| Target File | Model | Duration | Input Code Tokens | Output Tokens | Speed | Done Reason | Run ID |
|---|---|---|---|---|---|---|---|
| c:\Users\klad3\OneDrive\바탕 화면\IT\프로젝트\kintai-refactored\GEMINI.md | qwen27b:latest (IQ3_M) | 61.83s | 2748 tokens | 3038 tokens | 50.6 tokens/s | stop | 20261127_052205_92ac2cb6 |

# Red-Team Labour Standards Audit: KINTAI Refactored Specification

## 1. Interaction Matrix & Adversarial Simulation

### Interaction Matrix
The specification defines a "5-Layer Hybrid AI Verification System" intended to enforce labor law compliance (specifically Japanese Labor Standards Act Art. 37) and code quality. The critical interaction points are:

1.  **Input:** Code changes (Java/MyBatis/SQL).
2.  **Gate 1 (Deterministic):** `./gradlew check` (Unit/Integration tests, ArchUnit).
3.  **Gate 2/3 (AI Fan-out):** Parallel execution of `qwen3.8`, `Claude Sonnet 5.5`, and `OpenAI Codex CLI`.
4.  **Gate 4 (Rebuttal):** Cross-verification of AI findings via JUnit 5 test generation.
5.  **Gate 5 (Fail-Closed):** Pipeline halts on P0/P1 defects or parse inconsistencies. Override requires explicit `-HumanOverrideReason`.

**Critical State Transitions:**
*   **State A (Safe):** All gates pass. Commit allowed.
*   **State B (Blocked):** P0/P1 defect found. Pipeline exits non-zero.
*   **State C (Override):** Human provides reason. Pipeline passes.
*   **State D (Silent Failure):** AI models fail to detect a logic error, or `./gradlew check` passes despite logical wage calculation errors (e.g., floating-point precision loss not caught by ArchUnit if types are cast correctly but logic is wrong).

### Adversarial Simulation: The "Ghost Wage" & "Deadlock" Scenario

**Scenario 1: The Floating-Point Wage Drift (P2/P6)**
*   **Context:** The spec mandates `ArchUnit` to prohibit floating-point types in salary/service layers.
*   **Attack:** A developer uses `BigDecimal` but incorrectly applies rounding modes in a complex overtime calculation (e.g., 50-sen rounding). The unit tests (`./gradlew check`) pass because they test the *implementation* of the rounding, not the *legal correctness* against edge-case inputs (e.g., 15:45:33 duration).
*   **AI Layer Failure:** The AI models (Claude/Codex) are instructed to audit "Labor Standards Act Art. 37... 50-sen rounding." However, the spec states: *"Model internal knowledge" is the lowest priority (Priority 5).* If the AI models hallucinate a legal interpretation or fail to generate a specific JUnit test that reproduces the drift (because the "Failure Scenario" in the JSON output is vague), Gate 4 fails to catch it.
*   **Result:** The system commits code that systematically underpays employees by fractions of a yen over time. The "Fail-Closed" gate only closes on *detected* P0/P1s. If the detection logic (AI) misses it, the gate opens.

**Scenario 2: The Concurrency Deadlock in Shift Recording (P1/P4)**
*   **Context:** Spec mentions `SELECT ... FOR UPDATE` and "Pessimistic Lock Order" audits.
*   **Attack:** Two concurrent API calls attempt to record a clock-in/out for the same employee at the exact same millisecond, crossing a midnight boundary.
*   **Mechanism:** The `qwen3.8` model scans for "Pessimistic Lock Order." However, if the lock order is correct but the *business logic* inside the transaction allows a state where `start_time > end_time` due to timezone handling or DST (if applicable, though Japan has no DST, midnight boundaries remain), the AI might flag it as a "Concurrency Issue" (P1).
*   **Deadlock:** If the AI flags it as P1, the pipeline halts. The developer must fix it. However, if the AI *misses* the subtle race condition (e.g., a lost update on a counter that isn't locked), the `./gradlew check` integration tests might not cover the specific concurrency race if the test environment doesn't simulate high-load parallelism.
*   **Result:** Unrecorded work or double-counted shifts in production.

**Scenario 3: The "Zero-Korean" Gate vs. Legal Evidence (P7)**
*   **Context:** Section 5 mandates a "Zero-Korean Gate" for all public artifacts (`src/`, `docs/`, etc.).
*   **Attack:** A critical legal audit finding (e.g., a specific interpretation of "continuous work" under Japanese law) is documented in a Korean memo (`*_KO*` file) to bypass the gate. The spec isolates Korean memos locally.
*   **Risk:** If the "SSOT" (Single Source of Truth) for a complex legal edge case exists *only* in the isolated Korean memo, and the English/Japanese documentation is simplified to pass the "Zero-Korean" and "Business Japanese" checks, the operational logic in code may diverge from the intended legal compliance. The "Fail-Closed" gate does not check for *semantic* completeness, only *linguistic* purity.

**Scenario 4: The Override Loophole (P6)**
*   **Context:** Section 1, Stage 5: *"Emergency or confirmed false positive... explicit `-HumanOverrideReason`... PASS_WITH_OVERRIDE."*
*   **Attack:** A developer encounters a P1 flag from the AI regarding a potential IDOR vulnerability. The developer argues it's a false positive and provides a reason. The pipeline passes.
*   **Risk:** There is no *second* human verification or immutable audit trail requirement for the *reason* itself beyond the log. If the "reason" is insufficient but accepted, the vulnerability ships. The spec lacks a "Dual Authorization" for overrides.

## 2. Standardized Findings

| Finding ID | Attack Vector | Severity (P0/P1/P2/Info) | Verdict (PASS / WARN / FAIL / N/A) | Code & Test Evidence | Detailed Scenario & Recommendation |
|---|---|---|---|---|---|
| ADV-001 | P6 Silent Default | P1 | WARN | **SPEC_QUOTE:** "Model internal knowledge" is Priority 5. **SPEC_QUOTE:** "Fail-Closed gate is not released without explicit approval." **DERIVED:** The gate relies on AI detection accuracy. If AI misses a P0 (e.g., wage calculation error), the gate does not trigger. | **Scenario:** AI models fail to detect a subtle `BigDecimal` rounding error in overtime pay. `./gradlew check` passes because unit tests match the flawed implementation. The pipeline proceeds to commit. **Recommendation:** Implement a deterministic "Golden File" test suite for wage calculations that runs *before* AI gates, independent of AI interpretation. |
| ADV-002 | P7 Irreversibility | P1 | WARN | **SPEC_QUOTE:** "Explicit `-HumanOverrideReason`... PASS_WITH_OVERRIDE." **DERIVED:** No dual-authorization or immutable audit trail for the override reason itself is mandated beyond local logs. | **Scenario:** A developer overrides a P1 security finding (IDOR) with a vague reason. The log is local (`audit/runs/`). If the log is corrupted or deleted, the override is untraceable. **Recommendation:** Require overrides to be signed by a second party or stored in an immutable, append-only audit log with cryptographic hashing. |
| ADV-003 | P4 Rule Collision | P2 | WARN | **SPEC_QUOTE:** "Zero-Korean Gate... `[\uAC00-\uD7A3]`... immediate interruption." **SPEC_QUOTE:** "Korean work memos... isolated locally." **DERIVED:** Critical legal logic may be trapped in isolated Korean memos, creating a divergence between documented intent and code. | **Scenario:** A complex labor law interpretation is documented only in `*_KO*` files. The English/Japanese docs are simplified. Code is written based on the Korean memo. If the Korean memo is lost or misinterpreted, the code logic is unverified against the "SSOT" (which is the English/Japanese doc). **Recommendation:** Mandate that all legal logic in `*_KO*` files must have a corresponding, verified English/Japanese summary in the main docs before commit. |
| ADV-004 | P1 Blocked-Terminator | P2 | WARN | **SPEC_QUOTE:** "Pessimistic Lock Order... `SELECT ... FOR UPDATE`." **DERIVED:** The spec audits for lock *order*, but not necessarily for *deadlock resolution* or *timeout handling* in the business logic. | **Scenario:** Two concurrent shift recordings cause a deadlock. The system throws an exception. If the exception handling does not gracefully roll back and notify the user, the clock-in/out event is lost. **Recommendation:** Add a specific test case for concurrent clock-in/out events that verifies graceful failure and user notification, not just lock order. |
| ADV-005 | P3 Boundary Instant | P2 | WARN | **SPEC_QUOTE:** "Labor Standards Act Art. 37... 50-sen rounding." **DERIVED:** No explicit mention of midnight boundary handling for shift durations crossing 00:00. | **Scenario:** A shift ends at 00:00:01. The system calculates duration based on date-only logic, losing the 1 second. Over time, this causes wage drift. **Recommendation:** Add explicit unit tests for shifts crossing midnight, ensuring duration calculation uses timestamp precision, not date-only logic. |

## 3. JSON Output

```json
{
  "audit_engine": "Hermes-2Tier-Adversarial",
  "version": "1.2.0",
  "findings": [
    {
      "finding_id": "ADV-001",
      "vector": "P6 Silent Default",
      "severity": "P1",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: 'Model internal knowledge' is Priority 5. SPEC_QUOTE: 'Fail-Closed gate is not released without explicit approval.' DERIVED: The gate relies on AI detection accuracy. If AI misses a P0 (e.g., wage calculation error), the gate does not trigger.",
      "scenario": "AI models fail to detect a subtle BigDecimal rounding error in overtime pay. ./gradlew check passes because unit tests match the flawed implementation. The pipeline proceeds to commit.",
      "recommendation": "Implement a deterministic 'Golden File' test suite for wage calculations that runs before AI gates, independent of AI interpretation."
    },
    {
      "finding_id": "ADV-002",
      "vector": "P7 Irreversibility",
      "severity": "P1",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: 'Explicit -HumanOverrideReason... PASS_WITH_OVERRIDE.' DERIVED: No dual-authorization or immutable audit trail for the override reason itself is mandated beyond local logs.",
      "scenario": "A developer overrides a P1 security finding (IDOR) with a vague reason. The log is local (audit/runs/). If the log is corrupted or deleted, the override is untraceable.",
      "recommendation": "Require overrides to be signed by a second party or stored in an immutable, append-only audit log with cryptographic hashing."
    },
    {
      "finding_id": "ADV-003",
      "vector": "P4 Rule Collision",
      "severity": "P2",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: 'Zero-Korean Gate... [\\uAC00-\\uD7A3]... immediate interruption.' SPEC_QUOTE: 'Korean work memos... isolated locally.' DERIVED: Critical legal logic may be trapped in isolated Korean memos, creating a divergence between documented intent and code.",
      "scenario": "A complex labor law interpretation is documented only in *_KO* files. The English/Japanese docs are simplified. Code is written based on the Korean memo. If the Korean memo is lost or misinterpreted, the code logic is unverified against the 'SSOT' (which is the English/Japanese doc).",
      "recommendation": "Mandate that all legal logic in *_KO* files must have a corresponding, verified English/Japanese summary in the main docs before commit."
    },
    {
      "finding_id": "ADV-004",
      "vector": "P1 Blocked-Terminator",
      "severity": "P2",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: 'Pessimistic Lock Order... SELECT ... FOR UPDATE.' DERIVED: The spec audits for lock order, but not necessarily for deadlock resolution or timeout handling in the business logic.",
      "scenario": "Two concurrent shift recordings cause a deadlock. The system throws an exception. If the exception handling does not gracefully roll back and notify the user, the clock-in/out event is lost.",
      "recommendation": "Add a specific test case for concurrent clock-in/out events that verifies graceful failure and user notification, not just lock order."
    },
    {
      "finding_id": "ADV-005",
      "vector": "P3 Boundary Instant",
      "severity": "P2",
      "verdict": "WARN",
      "evidence": "SPEC_QUOTE: 'Labor Standards Act Art. 37... 50-sen rounding.' DERIVED: No explicit mention of midnight boundary handling for shift durations crossing 00:00.",
      "scenario": "A shift ends at 00:00:01. The system calculates duration based on date-only logic, losing the 1 second. Over time, this causes wage drift.",
      "recommendation": "Add explicit unit tests for shifts crossing midnight, ensuring duration calculation uses timestamp precision, not date-only logic."
    }
  ]
}
```