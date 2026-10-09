#!/usr/bin/env bash
# Подключение проекта к конвейеру «Штаб» одной командой (План Штаба, 2Ж).
#
#   connect-project.sh <владелец/репо> [--node 24] [--chrome] [--tools "Bash(...),..."]
#                      [--protect] [--checks "Тесты и сборка,..."]
#
# Ставит метки конвейера; кладёт шаблон «Задача», файл «Агенты» (вызов
# исполнителя, ревьюера и развязчика), «Проверки PR» по шаблону Node — если
# своих нет и задан --node, — и раздел «Для конвейера» в CLAUDE.md. Файлы —
# одним PR (в пустой репо — прямо в основную ветку): сливает человек.
# --protect — набор правил основной ветки: только через PR, без удаления и
# перезаписи истории, обязательные проверки — --checks или задача шаблона.
# Это настройка GitHub — только с согласия владельца в этот раз.
#
# Репо создаёт человек. После скрипта у него остаётся: доступ GitHub App
# Claude к репо и секрет CLAUDE_CODE_OAUTH_TOKEN — скрипт напечатает.
# Только REST (`gh api`): GraphQL облачный прокси не пускает.
# DRY_RUN=1 — только чтение: показать, что было бы сделано.
set -euo pipefail
command -v jq >/dev/null || { echo "нужен jq"; exit 1; }

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
REPO=$1; shift
case $REPO in */*) ;; *) usage ;; esac
NODE="" CHROME=false TOOLS="Bash(npm ci),Bash(npm test:*),Bash(npm run:*)" PROTECT=no CHECKS=""
while [ $# -gt 0 ]; do
  case $1 in
    --node) NODE=$2; shift 2 ;;
    --chrome) CHROME=true; shift ;;
    --tools) TOOLS=$2; shift 2 ;;
    --protect) PROTECT=yes; shift ;;
    --checks) CHECKS=$2; shift 2 ;;
    *) usage ;;
  esac
done

TPL=$(cd "$(dirname "$0")/../templates/project" && pwd)
BRANCH=pipeline-connect
dry() { [ "${DRY_RUN:-}" = 1 ]; }
say() { echo "$*"; }
act() { if dry; then say "  [пробно] $1"; return 1; fi; say "  $1"; }

info=$(gh api "repos/$REPO") || { say "Нет доступа к $REPO: репо создаёт человек, сессии — add_repo."; exit 1; }
BASE=$(jq -r .default_branch <<<"$info")
EMPTY=no
gh api "repos/$REPO/git/ref/heads/$BASE" >/dev/null 2>&1 || EMPTY=yes
say "## $REPO — основная ветка $BASE$([ $EMPTY = yes ] && echo ', репо пустой')"

# ─── Метки ─────────────────────────────────────────────────────────────────
# Имя | цвет | описание — как в проектах семьи.
LABELS='готово|0E8A16|Можно брать в работу
в-работе|FBCA04|Исполнитель взял; замок: один исполнитель на репо
нужно-решение|D93F0B|Ждёт человека: вопрос в комментарии
можно-сливать|0E8A16|Вердикт ревьюера: можно сливать — объяснение в его комментарии
не-сливать|D73A4A|Вердикт ревьюера: не сливать — что не так, в его комментарии
предложение|C5DEF5|Задача предложена аналитиком; «готово» от владельца — согласие (Ш-73)
сверх-предела|B60205|Владелец разрешил: задача идёт сверх суточного предела PR бота (Ш-60 Штаба)
крупная|B60205|Исполнитель: предел ходов 200 вместо 100 (Ш-46 Штаба)
пара|FBCA04|Прогон пары: своя ветка, PR по задаче не останавливает (Ш-42 Штаба)
medium|C5DEF5|Прогон с усилием medium вместо high (Ш-54 Штаба)
xhigh|0052CC|Прогон с усилием xhigh вместо high (Ш-54 Штаба)
sonnet|1D76DB|Прогон на Sonnet вместо модели по умолчанию (Ш-36 Штаба)
opus|5319E7|Прогон на Opus вместо модели по умолчанию (Ш-36 Штаба)
p1|B60205|Приоритет: срочно
p2|E99695|Приоритет: обычный
p3|F9D0C4|Приоритет: когда будет время'

say "### Метки"
have=$(gh api "repos/$REPO/labels?per_page=100" --jq '.[].name')
while IFS='|' read -r name color desc; do
  if grep -qxF "$name" <<<"$have"; then
    act "обновить «$name»" && gh api -X PATCH "repos/$REPO/labels/$(jq -rn --arg s "$name" '$s|@uri')" \
      -f color="$color" -f description="$desc" >/dev/null || true
  else
    act "завести «$name»" && gh api "repos/$REPO/labels" -f name="$name" -f color="$color" -f description="$desc" >/dev/null || true
  fi
done <<<"$LABELS"

# ─── Файлы ─────────────────────────────────────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
REF=$BASE
# Содержимое файла в основной ветке; нет — пусто, код 1.
remote() { [ $EMPTY = no ] && gh api "repos/$REPO/contents/$1?ref=$BASE" --jq .content 2>/dev/null | base64 -d; }
exists() { [ $EMPTY = no ] && gh api "repos/$REPO/contents/$1?ref=$BASE" >/dev/null 2>&1; }

FILES=()   # путь в репо → файл в $WORK; put_file — только с `< файл` или `< <(…)`: в конвейере FILES теряется
put_file() { mkdir -p "$WORK/$(dirname "$1")"; cat > "$WORK/$1"; FILES+=("$1"); }
fill() { sed -e "s|@NODE@|$NODE|g" -e "s|@CHROME@|$CHROME|g" -e "s|@TOOLS@|$TOOLS|g" "$1"; }

say "### Файлы"
if exists ".github/ISSUE_TEMPLATE/задача.md"; then say "  шаблон «Задача» уже есть"
else put_file ".github/ISSUE_TEMPLATE/задача.md" < "$TPL/issue-task.md"; say "  + шаблон «Задача»"; fi

if exists ".github/workflows/executor.yml"; then say "  файл «Агенты» уже есть — не трогаю"
else put_file ".github/workflows/executor.yml" < <(fill "$TPL/agents.yml"); say "  + файл «Агенты» (node «$NODE», chrome $CHROME)"; fi

OWN_CI=no
if [ $EMPTY = no ]; then
  for f in $(gh api "repos/$REPO/contents/.github/workflows?ref=$BASE" --jq '.[].name' 2>/dev/null || true); do
    if remote ".github/workflows/$f" </dev/null | grep -q '^name: Проверки PR'; then OWN_CI=yes; fi
  done
fi
if [ $OWN_CI = yes ]; then
  say "  «Проверки PR» уже есть"
elif [ -n "$NODE" ]; then
  put_file ".github/workflows/ci.yml" < <(fill "$TPL/ci-node.yml"); say "  + «Проверки PR» по шаблону Node"
  [ -n "$CHECKS" ] || CHECKS="Тесты и сборка"
else
  say "  ! «Проверок PR» нет, а --node не задан: их пишет сессия под стек проекта — без них нет ревьюера"
fi

claude_md=$(remote CLAUDE.md || true)
if grep -q '^## Для конвейера' <<<"$claude_md"; then say "  раздел «Для конвейера» уже есть"
else
  put_file CLAUDE.md < <(if [ -n "$claude_md" ]; then printf '%s\n' "$claude_md"
    else printf '# CLAUDE.md\n\n<!-- что это за проект, стек, как работать -->\n'; fi
    cat "$TPL/pipeline-section.md")
  say "  + раздел «Для конвейера» в CLAUDE.md — заготовку дописывает сессия"
fi

PR_URL=""
if [ ${#FILES[@]} -gt 0 ] && act "записать ${#FILES[@]} файл(а)$([ $EMPTY = no ] && echo " веткой $BRANCH и PR")"; then
  if [ $EMPTY = no ]; then
    sha=$(gh api "repos/$REPO/git/ref/heads/$BASE" --jq .object.sha)
    gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$sha" >/dev/null
    REF=$BRANCH
  fi
  for f in "${FILES[@]}"; do
    args=(-X PUT "repos/$REPO/contents/$f" -f message="Конвейер «Штаб»: $f" -f branch="$REF"
          -f content="$(base64 -w0 < "$WORK/$f")")
    old=$( [ $EMPTY = no ] && gh api "repos/$REPO/contents/$f?ref=$REF" --jq .sha 2>/dev/null || true)
    [ -n "$old" ] && args+=(-f sha="$old")
    gh api "${args[@]}" >/dev/null
  done
  if [ $EMPTY = no ]; then
    PR_URL=$(gh api "repos/$REPO/pulls" -f head="$BRANCH" -f base="$BASE" \
      -f title="Подключение к конвейеру «Штаб»" \
      -f body="Метки уже стоят. Файлы: ${FILES[*]}. Раздел «Для конвейера» — заготовка: дописать клон, проверки, данные, выкатку. Сливает владелец." \
      --jq .html_url)
    gh api -X POST "repos/$REPO/issues/$(basename "$PR_URL")/assignees" -f "assignees[]=${REPO%%/*}" >/dev/null || true
    say "  PR: $PR_URL"
  fi
fi

# ─── Защита основной ветки ─────────────────────────────────────────────────
say "### Защита $BASE"
if [ $PROTECT = no ]; then say "  не включаю: нет --protect"
elif gh api "repos/$REPO/rulesets" --jq '.[].name' 2>/dev/null | grep -qxF main; then say "  набор правил «main» уже есть"
else
  rules='[{"type":"deletion"},{"type":"non_fast_forward"},
    {"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,
      "require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false}}]'
  if [ -n "$CHECKS" ]; then
    rules=$(jq --arg c "$CHECKS" '. + [{"type":"required_status_checks","parameters":{
      "strict_required_status_checks_policy":false,
      "required_status_checks":($c | split(",") | map({context: .}))}}]' <<<"$rules")
  else
    say "  ! обязательных проверок нет: задай --checks именами задач «Проверок PR»"
  fi
  body=$(jq -n --argjson r "$rules" '{name:"main",target:"branch",enforcement:"active",
    conditions:{ref_name:{include:["~DEFAULT_BRANCH"],exclude:[]}},
    bypass_actors:[{actor_id:5,actor_type:"RepositoryRole",bypass_mode:"always"}],rules:$r}')
  act "набор правил «main»: только через PR${CHECKS:+, проверки: $CHECKS}" \
    && gh api -X POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null || true
fi

# ─── Что осталось человеку ─────────────────────────────────────────────────
say "### Человеку"
say "  1. Доступ Claude к репо: github.com/settings/installations → Claude → Repository access → добавить ${REPO#*/}"
say "  2. Секрет: github.com/$REPO/settings/secrets/actions → CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)"
[ -n "$PR_URL" ] && say "  3. Слить $PR_URL — после того, как сессия допишет раздел «Для конвейера»"
say "### Сессии Штаба"
say "  карточка в каталоге Штаба: python3 scripts/projects.py --new ${REPO#*/} --group <группа> (Ш-80)"
say "  хостам ретро и аналитика репо подключает человек словом в самом хосте (Ш-76)"
