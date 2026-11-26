# 요구사항 정의 크로스 감사 계약 사양서 (Audit Contract Spec)

---

## 1. 감사 입력 사양
- 감사 대상 파일: `config/srs_specification_ssot.md`
- 관련 스키마: `domain_target/02_database_schema_ssot/schema.sql`
- 도메인 서비스: `domain_target/03_core_domain_services/`

## 2. 필수 검증 관점
1. **노동기준법 제37조 준거성**: 심야업(22:00 ~ 05:00), 시간외 노동(1일 8시간 초과), 휴일 할증의 산정 로직.
2. **단수 처리의 정합성**: 쇼와 63년 기발 제150호에 따른 월간 합산 처리 및 일별 계산 방침.
3. **동시성 및 데드락 방지**: 부모 행 락 순서 정렬(`store_staff -> payroll`) 및 이중 타각 방지.
4. **보안 경계**: IDOR 취약점 배제, 세션 Principal 검증, RBAC 분리.
