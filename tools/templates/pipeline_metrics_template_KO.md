# 📊 SRS 다층 파이프라인 검증 메트릭 & 감사 총괄 대시보드 (한국어 대조본)

최종 갱신일: {{TODAY}} | 시스템 버전: v3.1 | 파이프라인 상태: {{LAST_STATUS}}

---

## 🚦 1. 파이프라인 종합 상태 (Summary)

* **총 요구사항 수**: {{TOTAL_REQ_COUNT}}건 (Slice 1 점포/회원/스태프, Slice 2 시프트/휴게/캘린더, Slice 4 노동법 37조/정산)
* **결정론적 C# 린터 상태**: `PASS` (FATAL: 0, WARNING: 0)
* **외부 지적 물리 큐 (`pending_findings.json`)**: `ALL_RESOLVED` (17건 전수 해결 완료)
* **OpenAI Codex CLI 상태**: `ONLINE` (`gpt-6.2-astra` 심층 감사 완료)
* **로컬 Qwen 27B 스트리밍**: `CONNECTED` (RTX 5070 Ti, 48.8 tokens/s)
* **Anthropic Claude 교차 감사**: `VERIFIED` (노동기준법 제37조 법리 확증)
* **Zero-Korean 하드게이트**: `100% PASS` (공개 파일 내 한글 0건)

---

## 🔬 2. 요구사항 무결성 검증 성적표 (전 {{TOTAL_REQ_COUNT}}개 요구사항)

| ID | 요구사항 명칭 | C# 린터 | Codex 6.2 | Claude 5.5 | Qwen 27B | 최종 판정 |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
{{MATRIX_TABLE}}

---

## 📜 3. 최근 감사 실행 이력
* **최근 감사 배치**: {{LAST_BATCH_ID}} (상태: `{{LAST_STATUS}}`)
* **최근 검증 내용**: {{LAST_NOTES}}
* **상세 사고 및 벤치마크 원장**: `logs/incident_history_ledger.md` 참조
* **외부 지적 물리 큐 원장**: `scratch/pending_findings.json`
