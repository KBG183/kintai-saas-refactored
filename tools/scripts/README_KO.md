# KINTAI 개발 및 운영 스크립트 카탈로그 사양서

- 작성일: 2026-11-24
- 상태: STABLE (전체 27개 스크립트 검증 완료)
- 적용 대상: `tools/scripts/` 하위 전체 실행 가능 파일 및 엔진군

---

## 1. 개요

`tools/scripts/` 디렉토리는 아르바이트 근태・급여 관리 SaaS(KINTAI)의 요구사항 정의서(SRS) 작성, 다층 AI 하이브리드 교차 검증, 결정론적 리포지토리 무결성 보증을 담당하는 실행 엔진군을 보관합니다.
본 카탈로그는 평면적으로 배치된 전체 자산의 책임 경계와 호출 인터페이스를 명확히 정의하여 향후 유지보수성을 영구히 담보하기 위해 제정되었습니다.

---

## 2. 도구 분류 매트릭스

전체 자산을 용도 및 실행 레이어에 따라 아래 4대 카테고리로 분류합니다.

| 카테고리 | 파일 목록 | 주요 책무 및 실행 내용 | 거버넌스 및 실행 권한 |
|---|---|---|---|
| **① 결정론적 검증 및 린터** | `VerifySRS.cs`, `VerifySRS.exe`, `verify_srs.ps1`, `verify_integrity.ps1`, `verify_repo_total_integrity.ps1`, `TestV52Suite_Regression.cs`, `TestV52Suite_Regression.exe` | 구문, 서식, DoD, IDOR, 전체 12대 게이트를 컴파일러 레벨에서 기계적 검증 (Fail-Closed) | CI 및 Git 사전 훅 자동 실행 |
| **② 멀티 AI 오케스트레이터** | `call_ai.ps1`, `call_codex.ps1`, `call_claude.ps1`, `call_qwen.ps1`, `run_quad_audit.ps1`, `hermes_controller.ps1`, `AuditVerdictHelper.psm1`, `route_audit.ps1`, `run_lab_benchmark.ps1` | OpenAI Codex, Anthropic Claude, 로컬 Qwen 27B (RTX 5070 Ti) 스트리밍 호출 및 교차 감사 조율 | 읽기 전용 격리 및 무출력 래퍼 |
| **③ SSOT 패치 및 대장 운영** | `patch_ssot.ps1`, `patch_ssot_editorial.ps1`, `patch_ssot_literal.ps1`, `finalize_daily_ledgers.ps1`, `sync_dashboard.ps1`, `sync_all_mirrors.ps1`, `sync_domain_mirror.ps1`, `bundle_diff_context.ps1`, `extract_ddl_spec.ps1`, `pipeline_draft_and_integrate.ps1`, `gate_master_srs.ps1`, `gate_phase3.ps1`, `audit_srs.ps1` | SSOT 아토믹 패치 적용, 스프린트 마감 시 6대 대장 정합성 검증 및 자동 등록 | 편집 권한은 초크포인트 경유 한정 |
| **④ 훅, 테스트 및 데모** | `install_hooks.ps1`, `test_git_hooks.ps1`, `demo_offline_replay.ps1` | Git 사전 검증 훅 도입 및 구문 검증, API 키 불필요 3초 오프라인 회귀 데모 재생 | 개발자 로컬 환경 즉각 기동 |

---

## 3. 주요 카노니컬 진입점 목록

아래 스크립트들은 CI/CD, Git 훅, 최상위 헌법(`GEMINI.md`)에서 직접 참조되는 핵심 진입점이며 경로 변경이 엄격히 금지됩니다.

| 카노니컬 도구 | 명령어 실행 예시 | 기대되는 실행 결과 |
|---|---|---|
| `VerifySRS.exe` | `.\tools\scripts\VerifySRS.exe config\srs_specification_ssot.md` | SSOT 단일 진실 원서의 텍스트, DoD, IDOR 정적 검증 (0 FAIL PASS) |
| `verify_repo_total_integrity.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\verify_repo_total_integrity.ps1 -NoLog` | 전체 12대 무결성 게이트(Zero-Korean, CSV 정합성, 링크 등) 전원 통과 |
| `run_quad_audit.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\run_quad_audit.ps1 -TargetFile config\srs_specification_ssot.md` | Codex / Claude / Qwen / VerifySRS 4중 교차 검증 릴레이 실행 |
| `finalize_daily_ledgers.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\finalize_daily_ledgers.ps1 -Stage` | 6대 대장 정합성 확인, CSV-004 검증, Git 스테이징 자동 완료 |
| `test_git_hooks.ps1` | `powershell -ExecutionPolicy Bypass -File tools\scripts\test_git_hooks.ps1` | pre-commit 훅의 Bash 구문 및 Zero-Korean 정책 적합성 확인 |

---

## 4. 실행 환경 및 종속성 사양

- **PowerShell 엔진**: Windows PowerShell 5.1 또는 PowerShell 7+ (UTF-8 No BOM, `$ErrorActionPreference = 'Stop'` 필수).
- **C# Roslyn 컴파일러**: `.NET Framework 4.0` 호환 `csc.exe` (CI 환경 동적 자동 컴파일 대응).
- **외부 AI 실행 환경**: OpenAI Codex CLI (격리 샌드박스), Anthropic Claude API, Tailscale P2P 경유 자택 GPU Ollama 엔드포인트.
