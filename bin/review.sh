#!/usr/bin/env bash
# 이미 있는 워크트리 안에서 리뷰어를 띄운다. 새 워크트리를 만들지 않는다.
#
#   review.sh <repo> <worktree-name> [prompt-file]
#
# 리뷰는 작업이 있는 그 워크트리에서 돈다. 오케스트레이터 세션에서 돌리면
# diff를 그 세션 컨텍스트로 끌어올리게 되고, 레포가 여럿일 때 그게 곧 한도다.
#
# 결과는 반드시 파일로 받는다. TUI 안에만 뱉으면 스피너가 스크롤백을 밀어내
# 판정이 통째로 사라진다.
#
# 프롬프트 파일을 안 주면 기본 리뷰 지시로 돈다. 그때 프로젝트가 설정의
# review.context 에 한 줄을 얹으면 계약 정본 위치 같은 것이 함께 실린다.
# 리뷰어가 이미 그 워크트리에 살아 있으면 새로 띄우지 않고 그쪽에 재리뷰를
# 시킨다. 컨텍스트를 들고 있어 지난 발견과 지금 상태를 견줄 수 있다.
# NEW=1 을 주면 그래도 새로 띄운다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 2 ] || die "사용법: review.sh <repo> <worktree-name> [prompt-file]"

REPO="$1"; NAME="$2"; PROMPT_FILE="${3:-}"

WT="$(worktree_path "$REPO" "$NAME")"
require_worktree "$WT"

DIRTY="$(git -C "$WT" status --porcelain | head -5)"
if [ -n "$DIRTY" ]; then
  printf '작업 트리가 깨끗하지 않다. 리뷰가 도는 동안 diff가 바뀌면 판정이 실제로 커밋될 것과 달라진다.\n' >&2
  printf '%s\n' "$DIRTY" >&2
  printf '그래도 띄우려면 FORCE=1 을 준다.\n' >&2
  [ "${FORCE:-}" = "1" ] || exit 1
fi

AHEAD="$(git -C "$WT" rev-list --count "$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)"
[ "$AHEAD" -gt 0 ] || die "$BASE_BRANCH 대비 커밋이 없다. 리뷰할 것이 없다."

OUT="$(review_file "$REPO" "$NAME")"
mkdir -p "$ORCA_REVIEWS"

OUT_RULE="

## 결과를 남기는 법

발견을 $OUT 에 마크다운으로 쓴다. 터미널에만 뱉지 마라. 그러면 스크롤백에 밀려 사라진다.
blocking과 non-blocking을 갈라 적고, 항목마다 파일 경로와 줄 번호, 무엇이 왜 문제인지, 어떻게 고치면 되는지를 넣는다.
발견이 없으면 통과라고 적는다. 워크트리 안의 파일은 하나도 건드리지 마라 -- 읽기만 한다.

파일을 다 쓴 뒤 판정을 Orca 카드에도 한 줄로 남긴다. 오케스트레이터가 파일을 열기 전에 그 줄을 먼저 본다.

\`\`\`
orca worktree set --worktree \"path:$WT\" --comment \"리뷰: blocking <개수>건\" --json
\`\`\`

통과면 comment를 \"리뷰 통과\"로 한다. 이건 Orca 메타데이터라 워크트리 파일을 건드리는 것이 아니다."

if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || die "프롬프트 파일이 없다: $PROMPT_FILE"
  BODY="$(cat "$PROMPT_FILE")"
else
  # 프로젝트가 얹는 한 줄. 계약 정본이 어디 있는지처럼 리뷰어가 알아야 하는데
  # 워크트리 안에서는 안 보이는 것이 여기 온다.
  CONTEXT="$(cfg_get review.context "")"
  [ -n "$CONTEXT" ] && CONTEXT="
$CONTEXT"
  BODY="너는 reviewer다. **읽기만 한다. 코드도 문서도 고치지 않고 커밋하지 않는다.**

리뷰 대상은 지금 이 worktree($REPO, 브랜치 $NAME)이고 범위는 커밋 범위 \`$BASE_BRANCH..HEAD\`다.$CONTEXT
정확성과 공유 계약 정합, 스펙 정합을 본다. 빌드와 테스트를 실제로 돌려 결과를 함께 적는다."
fi

# 이미 살아 있는 리뷰어가 있으면 그쪽에 재리뷰를 시킨다
if [ "${NEW:-}" != "1" ] && EXIST="$(load_handle "$REPO" "$NAME" review 2>/dev/null)"; then
  printf '리뷰어가 이미 떠 있다. 재리뷰를 시킨다: %s\n' "$EXIST"
  send_prompt "$EXIST" "고친 것이 커밋됐다. \`$BASE_BRANCH..HEAD\`를 다시 리뷰한다. 지난번에 낸 blocking이 실제로 닫혔는지 항목마다 확인하고, 고치는 과정에서 새로 생긴 것도 본다.${OUT_RULE}" \
    || die "메시지가 리뷰어에 안 들어갔다. Orca에서 그 탭을 직접 본다."
  # 카드는 메시지가 실제로 들어간 뒤에 찍는다. 위에서 die하면 여기까지 안 온다.
  card "$WT" in-review "재리뷰 중 (커밋 ${AHEAD}개)"
  printf '결과   %s\n' "$OUT"
  exit 0
fi

printf '리뷰어를 띄운다: %s/%s (커밋 %s개)\n' "$REPO" "$NAME" "$AHEAD"
TMP="$(mktemp -t orca-review)"
printf '%s%s\n' "$BODY" "$OUT_RULE" > "$TMP"

H="$(orca terminal create \
  --worktree "path:$WT" \
  --title "REVIEW $REPO" \
  --command "$AGENT_CMD \"\$(cat '$TMP')\"" \
  --json 2>&1 | terminal_handle)"

if [ -n "$H" ]; then
  save_handle "$REPO" "$NAME" review "$H"
  card "$WT" in-review "리뷰 중 (커밋 ${AHEAD}개)"
else
  card "$WT" in-review "리뷰어가 안 붙었다 -- Orca에서 탭을 본다"
fi

printf '결과   %s\n' "$OUT"
printf '되돌림 %s/bin/handback.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME"
