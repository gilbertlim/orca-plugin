#!/usr/bin/env bash
# 지금 떠 있는 워크트리 전부를 한 자리에 찍는다.
#
#   status.sh              전부
#   status.sh shared       한 레포만
#   status.sh --summary    표 끝에 세어 둔 값을 기계가 읽을 꼴로 덧붙인다
#
# --summary 는 앱 플러그인이 쓴다. 알림 본문은 비례폭이라 이 표의 칸 정렬이
# 통째로 무너지고 배너는 두어 줄에서 잘리므로, 거기엔 표가 아니라 수를 싣는다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUMMARY=0
if [ "${1:-}" = "--summary" ]; then
  SUMMARY=1
  shift
fi

FILTER="${1:-}"

# --summary 일 때만 찍는다. 표 뒤에 붙으므로 사람이 그냥 부르면 안 보인다.
emit_counts() {
  [ "$SUMMARY" = 1 ] || return 0
  printf -- '--- counts\n'
  printf 'worktrees=%s\n' "${n_total:-0}"
  printf 'review_stale=%s\n' "${n_stale:-0}"
  printf 'review_none=%s\n' "${n_unreviewed:-0}"
  printf 'dirty=%s\n' "${n_dirty:-0}"
  printf 'no_terminal=%s\n' "${n_idle:-0}"
}

n_total=0
n_stale=0
n_unreviewed=0
n_dirty=0
n_idle=0

TERMS="$(orca terminal list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in d.get("result", {}).get("terminals", []):
    if t.get("orphaned"):
        continue
    # title 이 JSON null 로 오는 때가 있다(에이전트가 쉬면 Orca가 제목을 안 준다).
    # get 의 기본값은 키가 있고 값이 null 이면 안 걸린다.
    print("%s\t%s" % (t.get("worktreePath") or "", t.get("title") or ""))
' || true)"

# 카드에 적힌 것. 커밋 수와 달리 이건 에이전트가 스스로 쓴 것이라,
# git이 못 보는 것("테스트 도는 중", "FK에 막힘")이 여기 앉는다.
CARDS="$(orca worktree list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("result", {}).get("worktrees", []):
    c = (w.get("comment") or "").replace("\n", " ").strip()
    if c:
        print("%s\t%s\t%s" % (w.get("path") or "", w.get("workspaceStatus") or "", c))
' || true)"

printf '%-34s %-6s %-7s %-10s %s\n' "워크트리" "커밋" "미커밋" "리뷰" "터미널"
printf '%s\n' "--------------------------------------------------------------------------------"

found=0
for dir in "$ORCA_WORKSPACES"/*/*; do
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
  repo="$(basename "$(dirname "$dir")")"
  name="$(basename "$dir")"
  [ -n "$FILTER" ] && [ "$repo" != "$FILTER" ] && continue
  found=1

  ahead="$(git -C "$dir" rev-list --count "$BASE_BRANCH..HEAD" 2>/dev/null || echo '?')"
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  # 제목은 에이전트가 도는 동안만 오므로, 개수를 먼저 찍고 제목은 있을 때만 덧붙인다.
  tcount="$(printf '%s\n' "$TERMS" | awk -F'\t' -v p="$dir" '$1==p' | grep -c . || true)"
  titles="$(printf '%s\n' "$TERMS" | awk -F'\t' -v p="$dir" '$1==p && $2!="" {print $2}' | paste -sd' | ' - 2>/dev/null || true)"
  if [ "${tcount:-0}" = 0 ]; then
    titles="없음"
  elif [ -n "$titles" ]; then
    titles="${tcount}개 · $titles"
  else
    titles="${tcount}개 (쉬는 중)"
  fi

  # 마지막 커밋보다 리뷰가 오래됐으면 낡은 판정이다. 고친 뒤 재리뷰를 안 돌린 상태다.
  rf="$(review_file "$repo" "$name")"
  if [ ! -f "$rf" ]; then
    review="안 함"
  else
    rt="$(stat -f %m "$rf" 2>/dev/null || stat -c %Y "$rf" 2>/dev/null || echo 0)"
    ct="$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo 0)"
    if [ "$rt" -lt "$ct" ]; then review="낡음"; else review="있음"; fi
  fi

  n_total=$((n_total + 1))
  [ "$review" = "낡음" ] && n_stale=$((n_stale + 1))
  [ "$review" = "안 함" ] && n_unreviewed=$((n_unreviewed + 1))
  [ "${dirty:-0}" != 0 ] && n_dirty=$((n_dirty + 1))
  [ "${tcount:-0}" = 0 ] && n_idle=$((n_idle + 1))

  printf '%-34s %-6s %-7s %-10s %s\n' "$repo/$name" "$ahead" "$dirty" "$review" "${titles:-없음}"

  # 카드 줄은 표에 넣지 않고 아래에 붙인다. 길이가 제각각이라 칸에 넣으면 정렬이 무너진다.
  cline="$(printf '%s\n' "$CARDS" | awk -F'\t' -v p="$dir" '$1==p {print "["$2"] "$3}' | head -1)"
  if [ -n "$cline" ]; then
    printf '%-34s %s\n' "" "└ ${cline}"
  fi
done

[ "$found" = 1 ] || { printf '떠 있는 워크트리가 없다.\n'; emit_counts; exit 0; }

printf '\n'
for dir in "$ORCA_WORKSPACES"/*/*; do
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
  repo="$(basename "$(dirname "$dir")")"
  [ -n "$FILTER" ] && [ "$repo" != "$FILTER" ] && continue
  log="$(git -C "$dir" log --oneline "$BASE_BRANCH..HEAD" 2>/dev/null)"
  [ -n "$log" ] || continue
  printf '=== %s/%s\n%s\n\n' "$repo" "$(basename "$dir")" "$log"
done

emit_counts
