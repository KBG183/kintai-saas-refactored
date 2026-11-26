# Codex·Antigravity 공용 운영 및 크로스 감사 규약

시행일: 2026-11-16

---

## 1. 기본 원칙 (분업과 상호 견제)

- **Antigravity (총괄)**: 프로젝트 전체 맥락 파악, 파일 입출력 제어, 사용자 인터페이스 담당.
- **Codex CLI (감사관)**: 파일 쓰기 권한이 없는 `--sandbox read-only` 모드로 격리 실행되며, 요구사항 정의서나 코드의 모호성, 경계 조건(Edge Case) 누락, 보안 취약점, 규약 위반을 독립적으로 교차 검증한다.
- **로컬 Qwen 27B (생성기)**: GPU 자원을 활용하여 요구사항 정의 초안과 유스케이스 시나리오의 골격을 추가 비용 0원으로 고속 생성한다.

---

## 2. 크로스 감사 실행 절차

1. Antigravity가 작성한 SRS 초안을 임시 워크스페이스에 배치.
2. `tools/scripts/call_codex.ps1`을 호출하여 표준 감사 계약에 따라 검증 실행.
3. Codex의 출력에서 중요도(P0/P1/P2)를 분석하여 감사 리포트에 반영.
4. 지적 사항을 `queue/srs_pending_findings.json`에 등록·보정한 후, C# 결정론적 린터(`VerifySRS.exe`) 및 `verify_repo_total_integrity.ps1`에 의한 검증을 실시.

---

## 3. 연동 갱신 프로토콜

작업 완료 시 Antigravity는 사용자에게 아래 정형 블록을 제시한다:

```markdown
### 📦 연동 갱신 대상 파일 패키지
1. `config/srs_specification_ssot.md` (요구사항 ID 확정 반영)
2. `logs/pipeline_metrics.md` (검증 합격 메트릭 최신화)
3. `logs/incident_history_ledger.md` (기술 과제 및 재발 방지 기록)
4. `logs/CURRENT_STATUS.md` (프로젝트 상태 갱신)
```
