리팩토링 분석 결과가 왔어. 어떻게 생각해?

## Context

- **Current branch**: ${CURRENT_BRANCH}
- **Target branch**: ${TARGET_BRANCH}

## Refactoring Findings

```json
${REVIEW_JSON}
```

각 finding에 대해 네 의견을 말해줘:
- 해당 파일/코드를 직접 읽고 확인한 뒤 판단해
- refactoring_plan의 steps 순서를 참고해서 의존성 관계를 파악해
- 리팩토링 제안이 타당한지, 과도한지
- 타당하다면 어떻게 고칠지 간단히 제안 (plan의 steps 순서를 따라)
- 과도하다면 왜 과도한지 설명
- blast_radius 대비 실질적 개선이 적다면 그것도 말해줘

## Scope-Aware Judgment

- `refactoring_plan.scope`와 `estimated_blast_radius`를 확인하고, blast_radius 대비 개선이 미미한 finding은 SKIP을 권장해
- finding이 명시된 scope를 넘어서는 변경을 제안하고 있다면 (예: micro scope인데 다른 파일 수정 필요) 반드시 SKIP 처리해
- 이전 iteration의 변경과 충돌 가능성이 있는지 체크해 — 같은 파일의 같은 영역을 건드리면 주의
- finding 간 의존성 순서를 확인해: step A 없이 step B가 불가능한 경우, A가 SKIP이면 B도 SKIP
