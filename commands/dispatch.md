---
description: 레포에 Orca 워크트리를 따고 그 안에 작업 에이전트를 띄운다
argument-hint: '<repo> <worktree-name> [작업 설명]'
allowed-tools: Read, Write, Glob, Grep, Bash(${CLAUDE_PLUGIN_ROOT}/bin/*), Bash(orca:*), Bash(git:*)
---

Orca 워크트리 하나를 따고 거기에 작업 에이전트를 붙인다.

인자: `$ARGUMENTS`

## 순서

1. 첫 인자가 레포 이름, 둘째가 워크트리 이름이다. 나머지는 무엇을 시킬지에 대한 설명이다.
   - 레포 이름은 **Orca에 등록된 displayName**이다. 경로가 아니다. `orca repo list --json`으로 확인한다.
   - 둘 중 하나라도 없으면 되묻지 말고 `orca repo list`를 찍어 후보를 보여 준 뒤 무엇을 겨눌지 묻는다.
2. 프롬프트 파일을 쓴다. `${CLAUDE_PLUGIN_ROOT}/templates/prompt-template.md`를 뼈대로 삼되, 프로젝트가 `.orca-flow.json`의 `promptTemplate`에 제 것을 지정했으면 그쪽이 이긴다.
   - **워크트리의 에이전트는 이 세션의 서브에이전트 정의도, 프로젝트 루트의 상대 경로도 못 읽는다.** 역할과 읽을 문서를 절대 경로로 적는다.
   - 스크래치패드나 `/tmp`에 쓴다. 프로젝트 트리 안에 쓰면 다음 커밋에 딸려 나간다.
3. 사람에게 그 프롬프트를 보여 주고 확인을 받는다. 워크트리를 따고 에이전트를 띄우는 것은 되돌리기 번거로운 일이다.
4. 확인이 나면 실행한다.

```
${CLAUDE_PLUGIN_ROOT}/bin/dispatch.sh <repo> <worktree-name> <prompt-file>
```

5. 출력의 경로와 브랜치를 사람에게 그대로 전한다.

## 알아 둘 것

- 레포가 여럿이면 이 명령을 레포 수만큼 부른다. 디렉터리가 겹치지 않아 서로를 안 건드린다.
- 같은 이름의 워크트리가 이미 있으면 스크립트가 멈춘다. 이어서 붙일 때는 `/orca:review`나 `/orca:handback`이다.
- `AGENT_CMD`, `BASE_BRANCH`, `NO_SETUP=1`을 앞에 붙여 한 번만 다르게 돌릴 수 있다.
