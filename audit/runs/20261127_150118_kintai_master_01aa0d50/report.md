### [Hermes Audit Execution Metrics v1.2.0]
| Target File | Model | Duration | Input Code Tokens | Output Tokens | Speed | Done Reason | Run ID |
|---|---|---|---|---|---|---|---|
| .\audit\runs\20261127_150118_kintai_master_01aa0d50\context_bundle.txt | qwen27b:latest (IQ3_M) | 20.44s | 6783 tokens | 858 tokens | 49.9 tokens/s | stop | 20261127_060128_394a7a88 |

| Finding ID | Audit Item | Severity (P0/P1/P2/Info) | Verdict (PASS / WARN / FAIL / N/A) | Code Line & Evidence | Detailed Analysis & Remediation |
|---|---|---|---|---|---|
| CON-01 | 悲観的ロック構文 (`FOR UPDATE`) | P0 | N/A | `N/A` | No service or mapper code provided to verify pessimistic locking implementation. |
| CON-02 | トランザクション境界内実行 | P0 | N/A | `N/A` | No service code provided to verify `@Transactional` boundaries. |
| CON-03 | TOCTOU競合防止（状態判定前ロック） | P0 | N/A | `N/A` | No service logic provided to verify lock acquisition order relative to state checks. |
| CON-04 | 複数行ロック獲得順序の一貫性 | P1 | N/A | `N/A` | No multi-row locking logic provided. |
| CON-05 | トランザクション内外部I/O混入排除 | P2 | N/A | `N/A` | No service logic provided. |
| SEC-01 | IDORテナント分離 (`storeId`検証) | P0 | PASS | `ShiftApiController.java:L39` | The `getEvents` endpoint explicitly verifies that the `storeId` in the request matches the `storeId` of the authenticated user (`userDetails.getStoreId()`). If they do not match, a `403 Forbidden` is thrown. This effectively prevents cross-tenant data access for this endpoint. |
| SEC-02 | セッションユーザーと更新対象の一致 | P0 | PASS | `ShiftApiController.java:L55` | The `requestShift` endpoint verifies that the `storeStaffId` in the request body matches the authenticated user's `storeStaffId`. This prevents a staff member from submitting shift requests on behalf of another staff member. |
| SEC-03 | RBAC権限アノテーションの網羅性 | P0 | PASS | `SecurityConfig.java:L58` | The `SecurityConfig` correctly maps `/api/shifts/*/confirm` and other admin endpoints to `hasRole("OWNER")`. Additionally, `ShiftApiController.confirmShift` (L75) performs a secondary check for the OWNER role, providing defense in depth. |
| SEC-04 | データ更新クエリの二重条件絞り込み | P1 | N/A | `N/A` | No MyBatis XML or repository code provided to verify SQL query scoping. |
| SEC-05 | 入力バリデーション (`@Valid`) | P2 | WARN | `ShiftApiController.java:L51` | The `requestShift` method accepts `@RequestBody ShiftRequestDto requestDto` but does not use the `@Valid` annotation. While the controller performs manual checks for IDOR, it relies on the DTO for other constraints (e.g., date validity, non-null fields). Without `@Valid`, standard Bean Validation annotations (if present in the DTO) will not be triggered, potentially allowing invalid data to reach the service layer. |

```json
[
  {
    "finding_id": "SEC-05",
    "file_line": "ShiftApiController.java:L51",
    "assertion": "The requestShift endpoint does not use @Valid on the ShiftRequestDto, potentially bypassing Bean Validation constraints defined in the DTO.",
    "failure_scenario": {
      "input": "A POST request to /api/shifts/request with a ShiftRequestDto containing null dates or invalid string lengths.",
      "wrong_result": "The request is not rejected at the controller level by Spring Validation. It proceeds to the service layer, potentially causing NullPointerExceptions or data integrity issues if the service does not manually validate every field."
    },
    "severity": "P2",
    "verdict": "WARN"
  }
]
```