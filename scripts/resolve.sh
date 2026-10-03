#!/usr/bin/env bash
# Развязчик без Claude (Ш-51, Ш-52 Штаба): найти PR бота с конфликтом после
# слияния, проверить его перед Claude, подвести итог после.
#
#   resolve.sh find  — слит PR: какие открытые PR бота теперь не сливаются.
#     Вход (env): REPO, GH_TOKEN, BASE; WAIT — секунд до первого вопроса
#     (GitHub пересчитывает слияемость не сразу).
#     Выход ($GITHUB_OUTPUT): prs — JSON [{pr, branch, sha}], count.
#   resolve.sh check — перед Claude: PR открыт, коммит тот же, конфликт есть.
#     Вход: REPO, GH_TOKEN, PR, SHA. Выход: go=yes.
#   resolve.sh after — после Claude: ветка сдвинулась — старый вердикт снять;
#     не сдвинулась и Claude не написал — комментарий владельцу.
#     Вход: REPO, GH_TOKEN, PR, SHA, START (время старта), RUN_URL, OWNER.
#
# DRY_RUN=1 — только показать, без комментариев и меток.
set -euo pipefail

BOT=app/claude
MAX_PRS=5   # PR за один запуск — столько же, сколько слотов у исполнителя

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
say() { echo "$*" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
dry() { [ "${DRY_RUN:-}" = 1 ]; }

# Слияемость: MERGEABLE, CONFLICTING или UNKNOWN, пока GitHub считает.
mergeable() {
  local pr=$1 state=UNKNOWN i
  for i in 1 2 3 4 5 6; do
    state=$(gh pr view "$pr" -R "$REPO" --json mergeable --jq .mergeable)
    [ "$state" != UNKNOWN ] && break
    sleep 10
  done
  echo "$state"
}

find_prs() {
  say "### Развязчик: поиск конфликтов"
  say ""
  sleep "${WAIT:-20}"
  local list pr branch sha state found="[]"
  list=$(gh pr list -R "$REPO" --state open --base "$BASE" --limit 50 \
    --json number,author,headRefName,headRefOid,isCrossRepository \
    --jq ".[] | select(.author.login == \"$BOT\" and (.isCrossRepository | not)) | \"\(.number)\t\(.headRefName)\t\(.headRefOid)\"")
  while IFS=$'\t' read -r pr branch sha; do
    [ -n "$pr" ] || continue
    state=$(mergeable "$pr")
    say "- PR #$pr ($branch): $state"
    if [ "$state" = CONFLICTING ]; then
      found=$(jq -c --argjson pr "$pr" --arg b "$branch" --arg s "$sha" '. + [{pr: $pr, branch: $b, sha: $s}]' <<< "$found")
    fi
  done <<< "$list"
  found=$(jq -c ".[:$MAX_PRS]" <<< "$found")
  local count
  count=$(jq length <<< "$found")
  say ""
  say "С конфликтом: $count."
  out prs "$found"
  out count "$count"
}

check() {
  local line state head
  line=$(gh pr view "$PR" -R "$REPO" --json state,headRefOid --jq '"\(.state)\t\(.headRefOid)"')
  IFS=$'\t' read -r state head <<< "$line"
  if [ "$state" != OPEN ]; then say "PR #$PR уже не открыт — пропуск."; return; fi
  if [ "$head" != "$SHA" ]; then say "PR #$PR: ветка сдвинулась (${head:0:7}) — пропуск."; return; fi
  if [ "$(mergeable "$PR")" != CONFLICTING ]; then say "PR #$PR: конфликта больше нет — пропуск."; return; fi
  say "PR #$PR: конфликт — зовём развязчика."
  out go yes
}

after() {
  local head said
  head=$(gh pr view "$PR" -R "$REPO" --json headRefOid --jq .headRefOid)
  if [ "$head" != "$SHA" ]; then
    # Ветка сдвинулась — проверенный вердикт устарел до нового ревью (Ш-51).
    say "PR #$PR: развязан, новый коммит ${head:0:7}; старый вердикт снят — ревьюер проверит заново."
    if ! dry; then
      gh api -X DELETE "repos/$REPO/issues/$PR/labels/можно-сливать" > /dev/null 2>&1 || true
      gh api -X DELETE "repos/$REPO/issues/$PR/labels/не-сливать" > /dev/null 2>&1 || true
    fi
    return
  fi
  said=$(gh api "repos/$REPO/issues/$PR/comments?per_page=100" \
    --jq "[.[] | select(.user.login == \"claude[bot]\" and .created_at >= \"$START\")] | length")
  if [ "$said" != 0 ]; then
    say "PR #$PR: развязчик не уверен — комментарий в PR."
    return
  fi
  say "PR #$PR: ветка не сдвинулась, комментария нет — пишем владельцу."
  local body="Развязчик не справился с конфликтом этого PR с основной веткой — прогон кончился без результата. Слить PR нельзя, пока конфликт не развязан: посмотрит сессия Штаба. [Лог]($RUN_URL) @$OWNER"
  if dry; then echo "--- комментарий в PR #$PR ---"; echo "$body"; else gh pr comment "$PR" -R "$REPO" --body "$body" > /dev/null; fi
}

case "${1:-}" in
  find) find_prs ;;
  check) check ;;
  after) after ;;
  *) echo "Использование: resolve.sh find|check|after" >&2; exit 2 ;;
esac
