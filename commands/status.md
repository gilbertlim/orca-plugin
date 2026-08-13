---
description: 떠 있는 Orca 워크트리의 커밋, 미커밋, 리뷰 상태, 살아 있는 터미널을 한 자리에 찍는다
argument-hint: '[repo]'
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/*), Bash(orca:*), Bash(git:*)
---

떠 있는 워크트리 전부의 처지를 본다.

인자: `$ARGUMENTS` (레포 이름 하나를 주면 그것만 본다)

```
${CLAUDE_PLUGIN_ROOT}/bin/status.sh $ARGUMENTS
```

출력을 그대로 전하되, 사람이 다음에 무엇을 해야 하는지 한 줄로 짚는다.

| 무엇이 보이면 | 다음 마디 |
|---------------|-----------|
| 커밋이 서고 리뷰가 "안 함" | `/orca:review` |
| 리뷰가 "낡음" | 고친 뒤 재리뷰를 안 돌린 상태다. `/orca:review` |
| 카드에 "리뷰: blocking N건" | `/orca:handback` |
| 카드에 "리뷰 통과" | `/orca:land` |
| 미커밋이 쌓여 있고 터미널이 없음 | 에이전트가 죽었다. 그 워크트리를 열어 본다 |

판정을 추측하지 않는다. 카드 줄과 리뷰 칸이 말하는 것만 옮긴다.
