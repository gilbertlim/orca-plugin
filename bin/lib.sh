#!/usr/bin/env bash
# bin/ 의 스크립트가 공유하는 함수. 직접 실행하지 않고 source 한다.
#
# 프로젝트마다 달라지는 값은 전부 프로젝트 루트의 .orca-flow.json 에서 온다.
# 그 파일이 없어도 기본값으로 돈다 -- 셋업만 조용히 빠지고 dispatch, review,
# handback, status, land 는 그대로 쓸 수 있다.
#
# 우선순위는 환경변수 > 설정 파일 > 기본값이다. 환경변수를 위에 두는 것은
# 한 번만 다르게 돌리는 자리가 실제로 있어서다(NO_PUSH=1, FORCE=1 처럼).

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=bin/config.sh
source "$PLUGIN_ROOT/bin/config.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 이(가) 없다. 먼저 설치한다."
}

need orca
need python3
need git

# ---------------------------------------------------------------------------
# 프로젝트 설정
# ---------------------------------------------------------------------------

# 사람이 부르는 자리라 $PWD 에서 위로 올라가며 찾는다.
orca_flow_load "$PWD"

ORCA_WORKSPACES="$(expand_home "${ORCA_WORKSPACES:-$(cfg_get workspaces "$HOME/orca/workspaces")}")"
ORCA_REVIEWS="$(expand_home "${ORCA_REVIEWS:-$(cfg_get reviews "$HOME/orca/reviews")}")"
AGENT_CMD="${AGENT_CMD:-$(cfg_get agentCmd "claude --permission-mode auto")}"
BASE_BRANCH="${BASE_BRANCH:-$(cfg_get baseBranch main)}"

# 프로젝트가 쓴 셋업 스크립트. 안 적으면 플러그인이 들고 온 것을 쓴다.
setup_script() {
  local custom
  custom="$(cfg_get setup.script "")"
  if [ -n "$custom" ]; then
    case "$custom" in
      /*) printf '%s' "$custom" ;;
      *) printf '%s/%s' "${PROJECT_ROOT:-$PWD}" "$custom" ;;
    esac
    return 0
  fi
  printf '%s/bin/worktree-setup.sh' "$PLUGIN_ROOT"
}

# ---------------------------------------------------------------------------
# Orca
# ---------------------------------------------------------------------------

# 레포 displayName -> 메인 체크아웃 절대 경로
repo_path() {
  orca repo list --json 2>/dev/null | python3 -c '
import sys, json
want = sys.argv[1]
for r in json.load(sys.stdin)["result"]["repos"]:
    if r.get("displayName") == want:
        print(r["path"])
        break
' "$1"
}

# 등록된 레포 이름 전부
repo_names() {
  orca repo list --json 2>/dev/null | python3 -c '
import sys, json
for r in json.load(sys.stdin)["result"]["repos"]:
    print(r.get("displayName") or "(이름 없음)")
'
}

worktree_path() { printf '%s/%s/%s' "$ORCA_WORKSPACES" "$1" "$2"; }

# orca --json 출력을 받아 ok가 아니면 죽는다
orca_check() {
  python3 -c '
import sys, json
d = json.load(sys.stdin)
if not d.get("ok"):
    sys.stderr.write(json.dumps(d.get("error", d), ensure_ascii=False) + "\n")
    sys.exit(1)
'
}

resolve_repo() {
  local name="$1" path
  path="$(repo_path "$name")"
  [ -n "$path" ] || die "orca에 등록되지 않은 레포다: $name
등록된 것: $(repo_names | tr '\n' ' ')
등록은 Orca 앱에서 하거나 orca repo add 로 한다."
  printf '%s' "$path"
}

require_worktree() {
  local wt="$1"
  [ -d "$wt" ] || die "워크트리가 없다: $wt
먼저 dispatch 로 만든다."
}

# 리뷰 결과 파일. 워크트리 밖에 둔다 -- 안에 쓰면 작업 트리가 더러워지고 다음
# 커밋에 딸려 나간다.
review_file() { printf '%s/%s-%s.md' "$ORCA_REVIEWS" "$1" "$2"; }

# "이 워크트리의 셋업은 내가 맡는다"는 표식. Orca 플러그인이 이걸 보고 물러선다.
# 워크트리를 만들기 전에 놓아야 한다. worktree.created 이벤트는 생성과 동시에
# 날아가므로, 만든 뒤에 놓으면 플러그인이 그 사이에 먼저 잡는다. 그러면
# dispatch가 75로 되돌아오고 셋업이 끝나기 전에 에이전트가 뜬다.
claim_file() { printf '%s/.claims/%s-%s' "$ORCA_REVIEWS" "$1" "$2"; }

# 셋업이 이미 도는 중이면 그 잠금이 풀릴 때까지 기다린다.
# 사람이 손으로 부른 것과 겹치면 우리 쪽은 75로 즉시 돌아오는데, 그대로 지나가면
# 아직 채워지지 않은 워크트리에 에이전트가 뜬다. 그것을 막는 것이 dispatch의 일이다.
wait_for_setup() { # worktree-path [seconds]
  local wt="$1" limit="${2:-600}" gitdir lock waited=0
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  lock="$gitdir/worktree-setup.lock"
  while [ -d "$lock" ] && [ "$waited" -lt "$limit" ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if [ -d "$lock" ]; then
    printf '  %s초를 기다렸는데 셋업이 안 끝났다. 빌드 전에 손으로 확인한다.\n' "$limit" >&2
  fi
  return 0
}

# Orca 워크스페이스 카드에 진행을 찍는다.
# CLI에는 알림을 쏘는 명령이 없어서, 상태를 바꾸는 쪽이 카드를 직접 고치는 것이
# 그 자리다. git을 긁어 상태를 추측하는 워처보다 낫다 -- 커밋 수 말고
# "테스트 도는 중", "FK에 막힘" 같은 것을 쓸 수 있다.
# 카드는 조용히 바뀌므로 그 줄을 데스크톱까지 밀어 주는 것은 Orca 플러그인이 맡는다.
# 표시일 뿐이므로 실패해도 넘어간다. 이것 때문에 리뷰나 머지가 멈추면 안 된다.
# 인자 이름을 st로 줄인 것은 zsh에서 status가 읽기 전용이라서다. 이 스크립트는
# bash로 돌지만 사람이 zsh에서 lib.sh를 source 해 보는 일이 있다.
card() { # worktree-path [status] [comment]  -- 빈 인자는 그 필드를 건드리지 않는다
  local wt="$1" st="${2:-}" comment="${3:-}"
  local args=(--worktree "path:$wt")
  [ -d "$wt" ] || return 0
  if [ -n "$st" ]; then args+=(--workspace-status "$st"); fi
  if [ -n "$comment" ]; then args+=(--comment "$comment"); fi
  [ "${#args[@]}" -gt 2 ] || return 0
  orca worktree set "${args[@]}" --json >/dev/null 2>&1 || true
}

# 에이전트가 제 카드를 스스로 갱신하게 하는 지시. 프롬프트 끝에 붙인다.
# 워크트리 경로를 박아 넣는 것은 active 셀렉터가 터미널이 아니라 UI에서 켜 둔
# 워크트리를 가리킬 수 있어서다. 그러면 엉뚱한 카드에 남는다.
card_rule() { # worktree-path
  printf '%s' "

## 카드를 갱신한다

마디가 바뀔 때마다 Orca 카드에 한 줄을 남긴다. 오케스트레이터는 그 줄로 진행을 본다.

\`\`\`
orca worktree set --worktree \"path:$1\" --comment \"<지금 무엇을 하고 있는지>\" --json
\`\`\`

재현, 구현, 검증, 막힘, 넘김처럼 상태가 실제로 바뀐 때만 쓴다. 짧게 쓰고 지금 것만 남긴다.
커밋 수나 파일 수는 적지 않는다 -- 그건 status가 직접 센다."
}

# 프롬프트를 보내고 에이전트가 실제로 받았는지까지 본다.
# --enter 가 텍스트만 넣고 Enter를 안 누르는 때가 있다. CLI는 ok를 돌려주므로
# 보낸 쪽은 성공으로 읽고, 메시지는 입력창에 앉은 채 아무 일도 안 일어난다.
send_prompt() { # handle text
  local h="$1" text="$2" i
  orca terminal send --terminal "$h" --text "$text" --enter --json 2>&1 | orca_check
  for i in 1 2 3; do
    sleep 5
    if terminal_busy "$h"; then return 0; fi
    # 입력창에 남아 있으면 Enter만 다시 친다
    orca terminal send --terminal "$h" --text "" --enter --json >/dev/null 2>&1 || true
  done
  sleep 5
  if terminal_busy "$h"; then return 0; fi
  printf '보냈지만 에이전트가 움직이지 않는다: %s\n' "$h" >&2
  printf 'Orca에서 그 탭을 열어 입력창에 메시지가 남아 있는지 본다.\n' >&2
  return 1
}

# 에이전트가 지금 무언가 하고 있나. TUI 하단 상태줄에 도는 표시가 뜬다.
terminal_busy() {
  orca terminal read --terminal "$1" --limit 80 --json 2>/dev/null | python3 -c '
import sys, json, re
try:
    t = json.load(sys.stdin)["result"]["terminal"]
except Exception:
    sys.exit(1)
body = "\n".join(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", l) for l in t.get("tail", []))
# 도는 동안에만 뜨는 표시들.
# 스피너 문구는 Churning, Crunching, Mulling, Cooking 처럼 매번 다르지만 전부 말줄임표를 단다.
# 그래서 단어를 열거하지 않고 그 표시와 인터럽트 안내, 토큰 속도를 본다.
sys.exit(0 if re.search(r"…|esc to interrupt|tok/s|thinking|thought for|◐", body) else 1)
'
}

# 터미널 핸들을 레포/이름과 역할(work|review)로 기억한다.
# 에이전트가 탭 제목을 자기 마음대로 바꾸므로 제목으로는 되찾지 못한다.
handle_file() { printf '%s/.handles/%s-%s.%s' "$ORCA_REVIEWS" "$1" "$2" "$3"; }

save_handle() { # repo name role handle
  mkdir -p "$ORCA_REVIEWS/.handles"
  printf '%s' "$4" > "$(handle_file "$1" "$2" "$3")"
}

load_handle() { # repo name role -- 살아 있는 핸들만 돌려준다
  local f h
  f="$(handle_file "$1" "$2" "$3")"
  [ -f "$f" ] || return 1
  h="$(cat "$f")"
  [ -n "$h" ] || return 1
  orca terminal list --json 2>/dev/null | python3 -c '
import sys, json
want = sys.argv[1]
for t in json.load(sys.stdin).get("result", {}).get("terminals", []):
    if t.get("handle") == want and not t.get("orphaned"):
        print(want)
        break
' "$h" | grep -q . || return 1
  printf '%s' "$h"
}

# orca --json 출력에서 새 터미널 핸들을 뽑는다
terminal_handle() {
  python3 -c '
import sys, json
d = json.load(sys.stdin)
if not d.get("ok"):
    sys.stderr.write(json.dumps(d.get("error", d), ensure_ascii=False) + "\n")
    sys.exit(1)
r = d.get("result", {})
print(r.get("handle")
      or (r.get("terminal") or {}).get("handle")
      or r.get("agentTerminalHandle")
      or (r.get("startupTerminal") or {}).get("handle")
      or "")
'
}
