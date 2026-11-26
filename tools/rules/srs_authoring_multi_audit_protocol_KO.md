# 다층 AI 교차 검증 프로토콜

시행일: 2026-11-25

---

## 1. 5중 다층 AI 교차 검증 아키텍처 (Role-Swap)

본 프로토콜은 아르바이트 근태·급여 관리 SaaS (KINTAI) 요구사항 정의서 및 구현 코드의 다층 검증을 표준화한다. 상시 '집필자 1자 ＋ 독립 교차 감사 4자'에 의한 총 5중 파이프라인 체제를 유지한다.

- **Fast Track**: 집필［Antigravity］ ＋ 독립 4중 교차 감사［①Codex, ②Claude, ③Qwen 27B, ④VerifySRS.exe］
- **Heavy Track**: 집필［Codex］ ＋ 독립 4중 교차 감사［①Antigravity(제1감사관), ②Claude, ③Qwen 27B, ④VerifySRS.exe］

### 구성 요소 및 역할
- **Antigravity (Gemini)**: 총괄 오케스트레이션, Fast Track 집필, Heavy Track 제1감사 (SSOT 대조·코드 정밀 검수).
- **OpenAI Codex CLI (`call_codex.ps1`)**: Heavy Track 초안 집필, Fast Track 교차 감사.
- **Anthropic Claude (`call_claude.ps1`)**: 노동기준법 제34조(휴게)·제37조(할증) 계산, 단수 처리, 동시성 예외 분기 심층 교차 감사.
- **로컬 Qwen 27B (`call_qwen.ps1`)**: 자사 GPU(RTX 5070 Ti)를 활용한 고속 정합성·상태 전이 회귀 점검.
- **C# 결정론적 린터 (`VerifySRS.exe v1.2`)**: 구문, 서식, DoD(완료 정의)의 기계식 Fail-Closed 차단.

---

## 2. 판정 구분 (Verdict)

- **PASS**: 지적 사항 없음 또는 경미한 정보(Info) 전용.
- **WARN**: 사양 기술 보완이나 비즈니스 규칙 명확화가 권장되는 사항.
- **FAIL**: 법령 위반, 데이터 파손 위험, 동시성 데드락, 보안 취약점(P0/P1).

모든 FAIL 항목은 코드 수정 및 테스트 코드에 의한 실증 증적이 제출될 때까지 해소로 간주되지 않는다 (Fail-Closed 원칙).
