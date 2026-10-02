#!/usr/bin/env bash
# Очередь исполнителя (Ш-41, Ш-42 Штаба): выбрать следующую задачу и
# проверить лимиты (Ш-07). Работает до Claude, ходов не тратит.
#
# Вход (env): REPO, OWNER, GH_TOKEN, DEFAULT_MODEL; DRY_RUN=1 — только
# показать выбор, без меток и комментариев.
# Выход ($GITHUB_OUTPUT): issue, model, pair, branch; issue пусто — работы нет.
set -euo pipefail

BOT=app/claude
MAX_OPEN=3       # открытых PR бота во всех репо владельца
MAX_REPO_DAY=3   # PR бота за 24 часа в этом репо
MAX_ALL_DAY=6    # PR бота за 24 часа во всех репо
LIMIT_MARK='<!-- очередь: лимит -->'

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
say() { echo "$*" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
dry() { [ "${DRY_RUN:-}" = 1 ]; }

say "### Очередь"
say ""

# Кандидаты: «готово» без «в-работе» и «нужно-решение»; порядок — p1, p2, p3,
# без p, при равных — старший issue. Строка: номер, метки, «после #N».
candidates=$(gh issue list -R "$REPO" --state open --label готово --limit 100 \
  --json number,labels,body --jq '
  map(select(any(.labels[]; .name == "в-работе" or .name == "нужно-решение") | not))
  | sort_by([([.labels[].name | select(test("^p[1-3]$"))] | sort | .[0] // "p9"), .number])
  | .[]
  | "\(.number)\t\([.labels[].name] | join(","))\t\([(.body // "") | scan("[Пп]осле\\s+#([0-9]+)") | .[0]] | join(","))"')

issue="" pair=no model="" branch=""
while IFS=$'\t' read -r num labels deps; do
  [ -n "$num" ] || continue
  model=""
  case ",$labels," in *,sonnet,*) model=sonnet ;; *,opus,*) model=opus ;; esac
  pair=no branch="agent/$num"
  case ",$labels," in *,пара,*) pair=yes branch="agent/$num-${model:-opus}" ;; esac

  wait=""
  for dep in ${deps//,/ }; do
    state=$(gh api "repos/$REPO/issues/$dep" --jq .state 2>/dev/null || echo closed)
    [ "$state" = open ] && wait=$dep
  done
  if [ -n "$wait" ]; then say "- #$num ждёт #$wait"; continue; fi

  # По ветке задачи уже есть PR — задача сдвинута, второй раз не брать.
  prs=$(gh pr list -R "$REPO" --head "$branch" --state all --json number --jq length)
  if [ "$prs" != 0 ]; then say "- #$num: по ветке $branch уже есть PR — пропуск"; continue; fi

  issue=$num
  break
done <<< "$candidates"

if [ -z "$issue" ]; then
  say "Очередь пуста — работы нет."
  exit 0
fi

# Лимиты Ш-07. Прогон считается PR-ом бота (Ш-42). В этом репо — точным
# списком; в остальных — поиском GitHub, он может отставать на минуты.
since=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
here=$(gh pr list -R "$REPO" --state all --limit 100 \
  --json author,state,createdAt --jq "
  map(select(.author.login == \"$BOT\"))
  | \"\(map(select(.state == \"OPEN\")) | length) \(map(select(.createdAt >= \"$since\")) | length)\"")
read -r here_open here_day <<< "$here"
other_open=$(gh search prs --owner "$OWNER" --author "$BOT" --state open --limit 100 \
  --json repository --jq "map(select(.repository.nameWithOwner != \"$REPO\")) | length")
other_day=$(gh search prs --owner "$OWNER" --author "$BOT" --created ">=$since" --limit 100 \
  --json repository --jq "map(select(.repository.nameWithOwner != \"$REPO\")) | length")

all_open=$((here_open + other_open))
all_day=$((here_day + other_day))
say "Открытых PR бота: $all_open из $MAX_OPEN; за сутки: здесь $here_day из $MAX_REPO_DAY, всего $all_day из $MAX_ALL_DAY."

reason=""
if [ "$all_open" -ge "$MAX_OPEN" ]; then
  reason="открытых PR бота во всех репо — $all_open, предел $MAX_OPEN. Слейте или закройте PR"
elif [ "$here_day" -ge "$MAX_REPO_DAY" ]; then
  reason="PR бота в этом репо за сутки — $here_day, предел $MAX_REPO_DAY. Подождите до завтра"
elif [ "$all_day" -ge "$MAX_ALL_DAY" ]; then
  reason="PR бота во всех репо за сутки — $all_day, предел $MAX_ALL_DAY. Подождите до завтра"
fi

if [ -n "$reason" ]; then
  say "Лимит: $reason. Задача #$issue ждёт."
  # Один комментарий на задачу, а не по одному на слот.
  last=$(gh api "repos/$REPO/issues/$issue/comments?per_page=100" --jq '.[-1].body // ""')
  if [[ "$last" != *"$LIMIT_MARK"* ]] && ! dry; then
    gh issue comment "$issue" -R "$REPO" --body "Очередь стоит: $reason. Задача ждёт; потом снимите и снова поставьте \`готово\` на любую задачу в этом репо — очередь проснётся. @$OWNER

$LIMIT_MARK"
  fi
  exit 0
fi

case "$model" in
  sonnet) model_id=claude-sonnet-5-5 ;;
  opus) model_id=claude-opus-5-5 ;;
  *) model_id=$DEFAULT_MODEL ;;
esac

say "Берём #$issue: модель $model_id, ветка $branch, пара: $pair."
# «в-работе» — замок и защита от повтора: задачу, которую прогон не сдвинул,
# следующий слот не возьмёт (Ш-42).
dry || gh issue edit "$issue" -R "$REPO" --add-label в-работе > /dev/null

out issue "$issue"
out model "$model_id"
out pair "$pair"
out branch "$branch"
