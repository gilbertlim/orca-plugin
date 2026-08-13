# orca-plugin

한 작업이 레포 여럿에 걸릴 때, 각 레포의 몫을 [Orca](https://github.com/stablyai/orca) 워크트리에 하나씩 떼어 에이전트를 붙이고 리뷰와 머지까지 그 워크트리 안에서 끝내는 절차다. <br>
오케스트레이터 세션은 무엇을 어디로 나눌지와 언제 머지할지만 들고, 코드와 diff는 워크트리 밖으로 안 나온다.

한 레포에 플러그인 둘이 산다. 설치처가 갈릴 뿐 고치는 사람은 하나다.

| 무엇 | 어디에 붙나 | 무엇을 하나 |
|------|-------------|-------------|
| Claude Code 플러그인 | Claude Code | 슬래시 커맨드 다섯과 절차를 가르치는 스킬 |
| Orca 앱 플러그인 | Orca 앱 | UI에서 만든 워크트리 셋업, 에이전트가 멈추면 데스크톱 알림 |

## 전제

- **Orca 앱과 `orca` CLI.** 스크립트가 그것 없이는 한 줄도 안 돈다.
- **레포가 Orca에 등록돼 있어야 한다.** 스크립트는 레포를 경로가 아니라 등록된 displayName으로 받는다. `orca repo list --json`으로 확인한다.
- `git`, `python3`, `bash`. python3는 표준 라이브러리만 쓴다.

## 설치

**Claude Code 쪽.**

```
/plugin marketplace add gilbertlim/orca-plugin
/plugin install orca@orca-plugin
```

**Orca 앱 쪽.** 마켓플레이스가 없어서 클론하고 로컬 경로로 건다.

```bash
git clone git@github.com:gilbertlim/orca-plugin.git ~/orca-plugin
```

그다음 Orca에서 설정 → Plugins → Installed → 로컬 경로로 위 디렉터리를 지정한다.

**프로젝트 쪽.** 쓸 프로젝트의 루트에 `.orca-flow.json`을 둔다. `templates/orca-flow.json`을 복사해 고치면 되고, 없어도 기본값으로 돈다.

## 한 사이클

슬래시 커맨드로 하면 이렇다.

```
/orca:dispatch shared migration-platform-trade  플랫폼 거래 컬럼을 판다
/orca:status
/orca:review shared migration-platform-trade
/orca:handback shared migration-platform-trade      # blocking이 있으면
/orca:review shared migration-platform-trade        # 재리뷰
/orca:land shared migration-platform-trade
```

스크립트를 직접 부르면 이렇다.

```bash
bin/dispatch.sh shared migration-platform-trade /tmp/prompt.md
bin/status.sh
bin/review.sh shared migration-platform-trade
bin/handback.sh shared migration-platform-trade
bin/land.sh shared migration-platform-trade
```

레포가 넷이면 dispatch를 넷 나란히 부른다. 디렉터리가 겹치지 않아 서로를 안 건드린다. <br>
handback과 review는 blocking이 없어질 때까지 돈다. 도는 자리는 언제나 그 워크트리 안이고, 오케스트레이터는 판정 파일(`~/orca/reviews/<repo>-<name>.md`)만 읽는다.

## 스크립트

| 스크립트 | 하는 일 |
|----------|---------|
| `dispatch.sh <repo> <name> <prompt-file>` | 워크트리를 만들고, gitignore된 파일을 메인 체크아웃에서 채우고, 에이전트를 띄운다 |
| `review.sh <repo> <name> [prompt-file]` | 그 워크트리 안에 리뷰어를 띄운다. 이미 떠 있으면 새로 안 띄우고 재리뷰를 시킨다 |
| `handback.sh <repo> <name> [review-file]` | 리뷰 결과를 작업 에이전트에게 되돌려 고치게 한다. 죽었으면 새로 띄운다 |
| `status.sh [repo]` | 워크트리별 커밋 수, 미커밋 수, 리뷰 상태, 살아 있는 터미널, 카드에 적힌 줄 |
| `land.sh <repo> <name>` | 리뷰 판정을 찍어 보이고 `--no-ff`로 머지, push까지 한 뒤 워크트리를 지운다 |
| `worktree-setup.sh [path]` | 새 워크트리에 gitignore된 파일을 메인 체크아웃에서 채운다. dispatch가 자동으로 부른다 |

손잡이가 환경변수로 열려 있다. `AGENT_CMD`, `BASE_BRANCH`, `NO_SETUP=1`, `KEEP=1`, `NO_PUSH=1`, `FORCE=1`, `NOTE`(handback에 실을 메모), `NEW=1`(리뷰어를 새로 띄운다)이다.

## 설정

프로젝트 루트의 `.orca-flow.json` 하나가 프로젝트마다 달라지는 것을 전부 든다. 없으면 기본값으로 돈다. <br>
`${projectRoot}`는 그 파일이 있는 디렉터리로 바뀐다. 절대 경로를 안 적어도 되므로 이 파일을 커밋해도 남의 머신에서 그대로 돈다.

```json
{
  "baseBranch": "main",
  "agentCmd": "claude --permission-mode auto",
  "workspaces": "~/orca/workspaces",
  "reviews": "~/orca/reviews",

  "setup": {
    "enabled": true,
    "script": "scripts/my-worktree-setup.sh",
    "files": ["*-local-mine.yaml", ".env", ".env.local", ".env.*.local"],
    "dirs": ["*/src/generated", "*/app/types/generated"],
    "prune": [".git", "node_modules", "build", ".venv", "dist"],
    "repoExtras": { "terraform": ["secrets/dev/values"] },
    "deny": ["my-umbrella-repo"]
  },

  "review": {
    "context": "계약 정본은 ${projectRoot}/repos/architecture/specs/ 아래에 있다."
  },

  "promptTemplate": "orca/prompt-template.md"
}
```

| 키 | 기본값 | 무엇 |
|----|--------|------|
| `baseBranch` | `main` | 워크트리를 딸 기준이자 land할 대상 |
| `agentCmd` | `claude --permission-mode auto` | 워크트리에 띄울 에이전트 명령. Codex를 쓰면 여기를 바꾼다 |
| `workspaces` | `~/orca/workspaces` | Orca가 워크트리를 만드는 곳 |
| `reviews` | `~/orca/reviews` | 리뷰 판정과 터미널 핸들, claim이 앉는 곳 |
| `setup.enabled` | `true` | `false`면 dispatch도 앱 플러그인도 셋업을 안 돌린다 |
| `setup.script` | 플러그인의 `bin/worktree-setup.sh` | 프로젝트가 제 셋업을 쓸 때. 프로젝트 루트 기준 상대 경로 |
| `setup.files` | `.env` 계열과 `*-local-mine.yaml` | 복사할 파일 패턴. 슬래시가 있으면 `-path`, 없으면 `-name` |
| `setup.dirs` | 없음 | 통째로 옮길 디렉터리. 코드 생성 산출물처럼 다시 만들기 비싼 것만 |
| `setup.prune` | 빌드 산출물과 의존성 트리 | 훑지 않을 디렉터리 |
| `setup.repoExtras` | 없음 | 패턴으로 안 잡히는 레포별 예외. 키는 레포 디렉터리 이름 |
| `setup.deny` | 없음 | 워크트리로 가르면 안 되는 레포 |
| `review.context` | 없음 | 기본 리뷰 프롬프트에 얹을 한 줄 |
| `promptTemplate` | 플러그인의 `templates/prompt-template.md` | dispatch 프롬프트의 뼈대 |

**설정을 어떻게 찾나.** 기준점에서 위로 올라가며 `.orca-flow.json`을 찾는다. 사람이 부르면 `$PWD`에서, 워크트리 셋업에서는 그 워크트리의 **메인 체크아웃**에서 올라간다. <br>
워크트리는 워크스페이스 디렉터리 아래 있어 프로젝트 트리 밖이므로 워크트리에서 올라가면 아무것도 못 찾는다. 메인 체크아웃에서 올라가면 레포가 곧 프로젝트인 경우는 레포 루트에서 잡히고, 우산 아래 레포가 여럿인 경우는 우산에서 잡힌다. 그래서 후보 경로를 열거하는 자리가 이 플러그인에 하나도 없다.

**호스트 수준 설정(`~/.orca-flow.json`).** Orca 앱 플러그인은 워커의 env가 허용 목록으로 스크럽돼 와서 `ORCA_REVIEWS` 같은 환경변수를 못 본다. 워크스페이스나 리뷰 디렉터리를 기본값에서 옮겼다면 여기에도 적어야 앱 플러그인이 같은 자리를 본다. `pathPrepend`로 자식 PATH에 디렉터리를 더 얹을 수도 있다.

## 새 워크트리는 그대로 못 쓴다

git worktree는 추적하는 파일만 가져오는데, 앱을 띄우고 테스트를 돌리는 데 필요한 것 상당수가 gitignore 대상이다. `.env` 계열, 개발자별 프로파일, 코드 생성 산출물, submodule이 빈 채로 남는다. 그 상태로 빌드하면 원인이 코드처럼 보이는 오류가 난다.

`worktree-setup.sh`가 그 빈자리를 같은 레포의 메인 체크아웃에서 채운다. 복사 원본은 `git worktree list`의 첫 항목이라 레포별 경로를 적어 둘 필요가 없다.

- 이미 있는 파일은 건너뛴다. 워크트리에서 일부러 다르게 잡아 둔 값을 조용히 덮어쓰지 않기 위해서다.
- **추적되는 파일은 `--force`를 줘도 두고 간다.** 커밋된 `.env.local`이 섞여 있는 레포가 있어서, 덮으면 워크트리에 출처를 모를 수정이 남고 다음 커밋에 딸려 나간다.
- 정본은 언제나 메인 체크아웃이고 반대 방향으로는 안 돌려보낸다. 그 파일들은 커밋되지 않아 리뷰를 못 거치는데, 양방향으로 열어 두면 어느 쪽이 맞는 설정인지 판정할 근거가 사라진다.
- 에이전트 권한 허용 목록(`.claude/settings.local.json`)은 기본으로 안 옮긴다. 한 작업 트리에서 승인한 권한이 조용히 번지는 걸 막기 위해서고, 필요하면 `--with-agent-settings`다.
- 의존성은 복사하지 않고 설치한다. `node_modules`와 `.venv`는 심링크와 절대 경로를 품고 있어 다른 디렉터리로 옮기면 조용히 깨진다.

**셋업이 끝나야 에이전트가 뜬다는 순서가 dispatch의 존재 이유다.** Orca UI에서 만든 워크트리는 dispatch를 안 거치므로 앱 플러그인이 같은 스크립트를 부르는데, 플러그인은 같은 생성 이벤트를 받으니 그대로 두면 둘이 같은 워크트리를 다툰다. 플러그인이 먼저 잡으면 dispatch 쪽 호출이 75로 즉시 돌아오고, 셋업이 백그라운드로 도는 중에 에이전트가 뜬다.

그래서 dispatch는 워크트리를 **만들기 전에** `<reviews>/.claims/<repo>-<name>`에 표식을 놓는다. 이벤트보다 항상 먼저 놓이므로 플러그인은 dispatch가 만든 워크트리에서 늘 물러선다. 표식은 dispatch가 끝날 때 사라지고, 늦게 도착한 플러그인은 셋업이 남긴 `worktree-setup.done`을 보고 또 물러선다. <br>
사람이 손으로 부른 것과 겹치는 경우가 마지막에 남는데, 그건 `worktree-setup.sh` 자신이 그 워크트리의 git 디렉터리에 든 잠금이 가른다. 진 쪽은 75로 빠지고, dispatch는 75를 받으면 실패로 읽지 않고 잠금이 풀릴 때까지 기다렸다 에이전트를 띄운다.

## 진행은 Orca 카드에 앉는다

Orca 워크스페이스 카드에 한 줄짜리 코멘트와 보드 상태(`todo`, `in-progress`, `in-review`, `completed`)가 붙는다. 스크립트가 자기 마디에서 그 둘을 갱신하고, 워크트리 안의 에이전트도 제 손으로 쓴다.

| 언제 | 상태 | 카드에 앉는 줄 |
|------|------|----------------|
| `dispatch.sh`가 에이전트를 붙일 때 | `in-progress` | 에이전트 투입 |
| 작업 에이전트가 마디를 지날 때 | 그대로 | 그 에이전트가 직접 쓴 한 줄 |
| `review.sh`가 리뷰어를 띄울 때 | `in-review` | 리뷰 중 (커밋 N개) |
| 리뷰어가 판정 파일을 다 썼을 때 | 그대로 | 리뷰: blocking N건, 또는 리뷰 통과 |
| `handback.sh`가 되돌릴 때 | `in-progress` | 재작업 -- 리뷰 blocking 반영 |
| `land.sh`가 push까지 끝냈을 때 | `completed` | 머지, push 완료 |

둘째 행이 나머지와 다르다. 스크립트가 아니라 에이전트가 쓰는 줄이고, 그래서 커밋 수가 못 담는 것("테스트 도는 중", "FK에 막힘")이 거기 올라온다. `dispatch.sh`와 `handback.sh`가 프롬프트 끝에 그 지시를 붙여 보내므로 오케스트레이터가 챙길 필요는 없다.

한동안은 git을 2초마다 긁어 데스크톱 알림을 띄우는 워처를 따로 돌렸다. 상태를 밖에서 추측하는 물건이라 커밋 수와 미커밋 수 너머는 못 봤다. 카드는 방향이 반대다. 상태를 실제로 바꾸는 쪽이 그 자리에서 쓴다.

카드는 조용히 바뀐다. Orca를 안 보고 있으면 바뀐 줄 모르고, CLI에는 알림을 쏘는 명령이 없다. 그 자리를 Orca 앱 플러그인이 메운다 — 에이전트가 멈추면(`done`, `waiting`, `blocked`) 데스크톱 알림이 뜨고, 카드에 적힌 줄이 본문 첫 줄로 실린다. 폴링이 아니라 훅이 올려 준 상태 변화를 받는다. <br>
코멘트를 비우는 것은 안 된다. 빈 문자열을 주면 CLI가 그 인자를 무시해 지난 줄이 그대로 남는다. 덮어쓰기만 되고, 다음 마디가 자기 줄을 남기는 것으로 그 자리를 메운다.

## 리뷰가 워크트리 안에서 도는 이유

리뷰어를 오케스트레이터 세션의 서브에이전트로 띄우면 레포 수만큼의 diff가 그 세션 컨텍스트로 올라온다. 레포 넷이면 그게 곧 한도다. <br>
`review.sh`는 작업이 있는 그 워크트리에 터미널을 하나 더 열고 거기서 돌린다. 오케스트레이터는 판정 파일만 읽는다.

**판정은 반드시 파일로 받는다.** TUI에만 뱉으면 스피너 재도색이 스크롤백을 밀어내 판정이 통째로 사라지고, 그건 실제로 한 번 났다.

## 알아 둘 것

**PATH가 앱 플러그인에서는 다르다.** Finder나 Dock에서 뜬 Orca의 PATH는 launchd 기본(`/usr/bin:/bin:/usr/sbin:/sbin`)이다. `git`과 `bash`는 거기 있지만 `orca`, `pnpm`, `uv`는 대개 그 밖이다. 그대로 두면 셋업이 의존성을 "not found, skipped"로 넘기고 0으로 끝나서 `node_modules` 없는 워크트리에 완료 알림이 뜬다. 그래서 자식 PATH에 흔한 자리(`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`)를 얹는데, 머신마다 다르면 `~/.orca-flow.json`의 `pathPrepend`로 더 넣는다. <br>
뭔가 조용히 안 될 때 제일 먼저 볼 것이 플러그인 로그의 `자식 PATH` 줄과 `도구:` 줄이다.

**env는 허용 목록으로 스크럽돼 온다.** 앱 플러그인 워커에는 `PATH`, `HOME`, `LANG`, `TMPDIR` 정도만 넘어온다. 셸에 export해 둔 값은 안 오므로 `AWS_PROFILE` 같은 것에 기대는 스크립트를 셋업에 붙이면 조용히 다르게 돈다.

**긴 셋업은 알림을 놓칠 수 있다.** 이벤트 핸들러는 5분에 끊기고 워커는 유휴 5분에 수거된다. 자식은 detached로 띄우므로 `pnpm install`이 중간에 죽지는 않지만, 4분을 넘기면 "백그라운드로 계속 돈다"는 알림으로 바뀐다.

**플러그인 API는 문서가 없다.** 근거는 [plugin-host-api.ts](https://github.com/stablyai/orca/blob/main/src/shared/plugins/plugin-host-api.ts)와 [plugin-manifest.ts](https://github.com/stablyai/orca/blob/main/src/shared/plugins/plugin-manifest.ts), 예제 [hello-orca](https://github.com/stablyai/orca/tree/main/examples/plugins/hello-orca)뿐이고, 소스 주석이 `pluginApi` 1이 얼기 전까지 호환을 보장하지 않는다고 적어 뒀다. Orca를 올린 뒤 안 뜨면 매니페스트 스키마부터 본다.

## 배치

```
.claude-plugin/     Claude Code 매니페스트와 마켓플레이스 (이 레포가 곧 마켓플레이스다)
orca-plugin.json    Orca 앱 매니페스트
main.mjs            Orca 앱 워커
bin/                스크립트. config.sh 가 설정을 읽고 lib.sh 가 Orca 를 감싼다
commands/           슬래시 커맨드 다섯
skills/orca-flow/   절차를 가르치는 스킬
templates/          설정과 프롬프트의 출발점
```

`config.sh`를 `lib.sh`에서 갈라 둔 것은 `worktree-setup.sh`가 혼자서도 돌아야 하기 때문이다. Orca 앱 플러그인이 그 스크립트를 직접 띄우는데, `lib.sh`는 맨 위에서 `orca` CLI를 요구하므로 거기 얹으면 셋업이 "orca가 없다"로 죽는다.
