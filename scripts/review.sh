#!/usr/bin/env bash
# Ревьюер без Claude (Ш-49, Ш-50, Ш-52 Штаба): ворота до Claude и вердикт
# после. Claude в GitHub не пишет — комментарий и метку ставит этот скрипт.
#
#   review.sh gate — закончились «Проверки PR»: нужен ли Claude. Красный CI —
#     вердикт здесь же. Вход (env): REPO, GH_TOKEN, HEAD_SHA, HEAD_BRANCH,
#     HEAD_REPO, CONCLUSION, RUN_URL, DEFAULT_TURNS, BIG_TURNS.
#     Выход ($GITHUB_OUTPUT): pr, issue, turns; pr пусто — ревью не нужно.
#   review.sh post — вердикт Claude в PR. Вход (env): REPO, GH_TOKEN, PR,
#     HEAD_SHA, RUN_URL, RESULT — ответ Claude заданной формы; пусто — не дошёл.
#
# DRY_RUN=1 — только показать решение и текст, без комментариев и меток.
set -euo pipefail

BOT=app/claude
ACTIONS_BOT='github-actions[bot]'   # автор комментариев этого скрипта
OK=можно-сливать
NO=не-сливать

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
say() { echo "$*" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
dry() { [ "${DRY_RUN:-}" = 1 ]; }
# Запись в GitHub — с повтором: сбой GitHub 07.10 снял вердикт целиком
# (ретро 08.10). Три попытки, 20 с между ними.
retry() { local i; for i in 1 2 3; do "$@" && return 0; [ "$i" = 3 ] || sleep "${RETRY_PAUSE:-20}"; done; return 1; }

# Метка вердикта: одна из двух; пусто — снять обе. Отсутствующую метку API
# снимать отказывается — это не ошибка.
set_label() {
  local pr=$1 label=${2:-}
  for l in "$OK" "$NO"; do
    [ "$l" = "$label" ] && continue
    gh api -X DELETE "repos/$REPO/issues/$pr/labels/$l" > /dev/null 2>&1 || true
  done
  [ -z "$label" ] || retry gh api "repos/$REPO/issues/$pr/labels" -f "labels[]=$label" > /dev/null
}

# Прошлые вердикты запуска — свернуть как устаревшие: на телефоне виден
# только вердикт последнего коммита. Не вышло — не беда, вердикт важнее.
hide_old() {
  local pr=$1 id
  for id in $(gh api "repos/$REPO/issues/$pr/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$ACTIONS_BOT\" and (.body | contains(\"<!-- ревьюер:\"))) | .node_id"); do
    if dry; then echo "--- свернуть старый вердикт $id ---"; continue; fi
    gh api graphql -f query="mutation { minimizeComment(input: {subjectId: \"$id\", classifier: OUTDATED}) { clientMutationId } }" \
      > /dev/null 2>&1 || true
  done
}

# Комментарий в PR: в сухом прогоне — только показать. Старые вердикты
# перед новым сворачиваются.
comment() {
  local pr=$1 body=$2
  hide_old "$pr"
  if dry; then
    printf -- '--- комментарий в PR #%s ---\n%s\n---\n' "$pr" "$body"
  else
    retry gh pr comment "$pr" -R "$REPO" --body "$body" > /dev/null
  fi
}

footer() {
  printf '<sub>Проверен коммит %s · [лог](%s)</sub>\n<!-- ревьюер: %s -->' "${1:0:7}" "$RUN_URL" "$1"
}

# Строка повторной проверки (Ш-53): ветка изменилась после проверенного коммита.
again() {
  [ -z "${1:-}" ] || printf '_Повторная проверка: ветка изменилась после проверки коммита %s._' "${1:0:7}"
}

gate() {
  say "### Ворота ревьюера"
  say ""

  # PR из чужой копии репо (форка) — не наш: ни секретов, ни Claude.
  if [ "$HEAD_REPO" != "$REPO" ]; then
    say "Ветка из другого репо ($HEAD_REPO) — пропуск."
    return
  fi

  # Список PR в событии после слияния пуст — PR ищем по ветке.
  local line pr author head issue
  line=$(gh pr list -R "$REPO" --head "$HEAD_BRANCH" --state open --limit 1 \
    --json number,author,headRefOid,body \
    --jq '.[0] // empty | "\(.number)\t\(.author.login)\t\(.headRefOid)\t\((.body // "") | [scan("(?i)(?:closes|fixes|resolves)\\s+#([0-9]+)") | .[0]] | .[0] // "")"')
  if [ -z "$line" ]; then
    say "Открытого PR из ветки $HEAD_BRANCH нет — пропуск."
    return
  fi
  IFS=$'\t' read -r pr author head issue <<< "$line"

  if [ "$author" != "$BOT" ]; then
    say "PR #$pr открыл $author, не бот — пропуск."
    return
  fi
  if [ "$head" != "$HEAD_SHA" ]; then
    say "PR #$pr: на ветке коммит новее (${head:0:7}) — его проверим после его проверок."
    return
  fi

  # Повтор (Ш-49): коммит уже проверен — пропуск. Отметку берём только из
  # комментариев запуска: посторонний в публичном репо её не подделает.
  # Прошлый вердикт — коммит и итог: они нужны повторной проверке (Ш-53).
  local last seen prev_verdict
  last=$(gh api "repos/$REPO/issues/$pr/comments?per_page=100" --jq "
    [.[] | select(.user.login == \"$ACTIONS_BOT\") | .body | select(test(\"<!-- ревьюер: [0-9a-f]+ -->\"))
     | (capture(\"<!-- ревьюер: (?<sha>[0-9a-f]+) -->\").sha) + \"\t\" + (if startswith(\"**Не сливать**\") then \"$NO\" else \"$OK\" end)]
    | last // \"\"")
  IFS=$'\t' read -r seen prev_verdict <<< "$last"
  if [ "$seen" = "$HEAD_SHA" ]; then
    say "PR #$pr: коммит ${HEAD_SHA:0:7} уже проверен — пропуск."
    return
  fi

  case "$CONCLUSION" in
    success) ;;
    failure|timed_out)
      say "PR #$pr: проверки красные ($CONCLUSION) — «Не сливать» без Claude."
      comment "$pr" "**Не сливать**
${seen:+
$(again "$seen")
}
Автоматические проверки не прошли — сборка или тесты красные. Ревьюер такой PR не читает.

Совет: посмотреть, что упало, и доработать или закрыть.

$(footer "$HEAD_SHA")"
      dry || set_label "$pr" "$NO"
      return
      ;;
    *)
      say "PR #$pr: проверки кончились со статусом «$CONCLUSION» — не вердикт, пропуск."
      return
      ;;
  esac

  # Предел ходов (Ш-52): у задачи с меткой «крупная» — больше.
  local turns=${DEFAULT_TURNS:-40} labels=""
  if [ -n "$issue" ]; then
    labels=$(gh issue view "$issue" -R "$REPO" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || true)
  fi
  case ",$labels," in *,крупная,*) turns=${BIG_TURNS:-80} ;; esac

  say "PR #$pr (задача #${issue:-?}), коммит ${HEAD_SHA:0:7}: зовём ревьюера, предел ходов $turns.${seen:+ Повторно: прошлый — ${seen:0:7}, $prev_verdict.}"
  out pr "$pr"
  out issue "$issue"
  out turns "$turns"
  out prev "$seen"
  out prev_verdict "$prev_verdict"
}

post() {
  if [ -z "${RESULT:-}" ]; then
    say "Ревьюер не дал вердикта — комментарий без метки."
    comment "$PR" "**Ревьюер не дошёл до вердикта**

Кончились ходы или прогон прервался. Метки нет — PR посмотрит сессия Штаба. Повторить — перезапустить проверки PR.

<sub>Коммит ${HEAD_SHA:0:7} · [лог]($RUN_URL)</sub>"
    dry || set_label "$PR" ""
    return
  fi

  # Хоть одна «блокирует» — «Не сливать», что бы ни сказал Claude (Ш-52).
  local verdict body
  verdict=$(jq -r --arg ok "$OK" --arg no "$NO" '
    if (.verdict == $no) or any(.findings[]?; .severity == "блокирует") then $no else $ok end' <<< "$RESULT")
  body=$(jq -r --arg v "$verdict" --arg no "$NO" --arg again "$(again "${PREV:-}")" '
    ([.findings[]? | select(.severity == "блокирует") | "- \(.text)"]) as $block
    | ([.findings[]? | select(.severity != "блокирует") | "- \(.text)"]) as $warn
    | [ (if $v == $no then "**Не сливать**"
         elif ($warn | length) > 0 then "**Можно сливать** — с оговоркой"
         else "**Можно сливать**" end),
        (if $again != "" then "", $again else empty end),
        "",
        (.summary // ""),
        (if ($block | length) > 0 then "", "**Блокирует:**", $block[] else empty end),
        (if ($warn | length) > 0 then "", "**Оговорки:**", $warn[] else empty end),
        "",
        "Совет: \(.advice // "—")"
      ] | join("\n")' <<< "$RESULT")

  say "PR #$PR: вердикт — $verdict."
  comment "$PR" "$body

$(footer "$HEAD_SHA")"
  dry || set_label "$PR" "$verdict"
}

case "${1:-}" in
  gate) gate ;;
  post) post ;;
  *) echo "Использование: review.sh gate|post" >&2; exit 2 ;;
esac
