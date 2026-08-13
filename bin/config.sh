#!/usr/bin/env bash
# 프로젝트 설정(.orca-flow.json)을 읽는 함수. 직접 실행하지 않고 source 한다.
#
# lib.sh 와 worktree-setup.sh 둘 다 이걸 문다. 갈라 둔 것은 worktree-setup.sh 가
# 혼자서도 돌아야 하기 때문이다. Orca 플러그인이 그 스크립트를 `bash <path> <wt>`
# 로 직접 띄우는데, 그때 env가 허용 목록으로 스크럽돼 와서 orca CLI 가 PATH에
# 없을 수 있다. lib.sh 는 맨 위에서 orca 를 요구하므로 거기 얹으면 셋업이
# "orca 가 없다"로 죽는다.
#
# 여기에는 의존성이 python3 하나뿐이다.

ORCA_FLOW_CONFIG_NAME=".orca-flow.json"

# 기준점에서 위로 올라가며 .orca-flow.json 을 찾는다.
#
# 시작점이 둘이다. 사람이 부르면 $PWD 이고, 워크트리 셋업에서는 그 워크트리의
# 메인 체크아웃이다. 어느 쪽이든 위로 올라가면 같은 곳에 닿는다 -- 레포가 곧
# 프로젝트면 레포 루트에서 바로 잡히고, 우산 아래 레포가 여럿이면 우산에서
# 잡힌다. 후보 경로를 열거하지 않아도 되는 이유가 이것이고, 그래서 남의
# 머신에서도 고칠 것이 없다.
orca_flow_find_root() { # start-dir
  local dir
  dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || return 1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/$ORCA_FLOW_CONFIG_NAME" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# PROJECT_ROOT 와 PROJECT_CONFIG 를 채운다. 못 찾으면 둘 다 빈 문자열이고,
# 그 상태에서도 cfg_get 은 기본값을 돌려주므로 호출하는 쪽이 분기할 필요가 없다.
orca_flow_load() { # start-dir
  PROJECT_ROOT="${ORCA_FLOW_ROOT:-$(orca_flow_find_root "${1:-$PWD}" || true)}"
  PROJECT_CONFIG=""
  if [ -n "$PROJECT_ROOT" ] && [ -f "$PROJECT_ROOT/$ORCA_FLOW_CONFIG_NAME" ]; then
    PROJECT_CONFIG="$PROJECT_ROOT/$ORCA_FLOW_CONFIG_NAME"
  fi
}

# 설정에서 스칼라 하나를 읽는다. 없으면 기본값이다.
# ${projectRoot} 토큰은 여기서 실제 경로로 바뀐다. 설정 파일에 절대 경로를
# 적지 않아도 되게 하려는 것이다.
cfg_get() { # dotted.path [default]
  local def="${2:-}"
  [ -n "${PROJECT_CONFIG:-}" ] || { printf '%s' "$def"; return 0; }
  ORCA_CFG_PATH="$1" ORCA_CFG_DEF="$def" ORCA_CFG_ROOT="${PROJECT_ROOT:-}" \
    python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        node = json.load(fp)
except Exception as exc:
    sys.stderr.write("%s 를 못 읽었다: %s\n" % (sys.argv[1], exc))
    sys.exit(1)
default = os.environ["ORCA_CFG_DEF"]
for key in os.environ["ORCA_CFG_PATH"].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.stdout.write(default)
        sys.exit(0)
    node = node[key]
if node is None or isinstance(node, (dict, list)):
    sys.stdout.write(default)
elif isinstance(node, bool):
    sys.stdout.write("true" if node else "false")
else:
    sys.stdout.write(str(node).replace("${projectRoot}", os.environ.get("ORCA_CFG_ROOT", "")))
' "$PROJECT_CONFIG"
}

# 설정에서 문자열 배열을 읽어 한 줄에 하나씩 찍는다. 없으면 아무것도 안 찍는다.
# 호출하는 쪽이 "비어 있으면 내 기본 목록을 쓴다"로 판단한다. 빈 배열을
# 명시하는 것과 키가 없는 것을 가르지 않는 이유는, 목록을 통째로 비우고 싶은
# 자리가 지금 없어서다. 생기면 그때 가른다.
cfg_list() { # dotted.path
  [ -n "${PROJECT_CONFIG:-}" ] || return 0
  ORCA_CFG_PATH="$1" ORCA_CFG_ROOT="${PROJECT_ROOT:-}" \
    python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        node = json.load(fp)
except Exception:
    sys.exit(0)
for key in os.environ["ORCA_CFG_PATH"].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(0)
    node = node[key]
if not isinstance(node, list):
    sys.exit(0)
root = os.environ.get("ORCA_CFG_ROOT", "")
for item in node:
    if isinstance(item, str) and item:
        print(item.replace("${projectRoot}", root))
' "$PROJECT_CONFIG"
}

# 객체 안의 한 키가 든 문자열 배열. 키를 인자로 따로 받는 것은 레포 이름에
# 점이 들어가면 dotted path 로는 못 짚어서다(spring-boot.v2 같은 것).
cfg_map_list() { # dotted.path key
  [ -n "${PROJECT_CONFIG:-}" ] || return 0
  ORCA_CFG_PATH="$1" ORCA_CFG_KEY="$2" ORCA_CFG_ROOT="${PROJECT_ROOT:-}" \
    python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        node = json.load(fp)
except Exception:
    sys.exit(0)
for key in os.environ["ORCA_CFG_PATH"].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(0)
    node = node[key]
if not isinstance(node, dict):
    sys.exit(0)
node = node.get(os.environ["ORCA_CFG_KEY"])
if isinstance(node, str):
    node = [node]
if not isinstance(node, list):
    sys.exit(0)
root = os.environ.get("ORCA_CFG_ROOT", "")
for item in node:
    if isinstance(item, str) and item:
        print(item.replace("${projectRoot}", root))
' "$PROJECT_CONFIG"
}

# ~ 를 편다. 셸이 인용부호 안의 물결표를 안 펴므로 JSON에서 온 값은 여기서 편다.
expand_home() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
