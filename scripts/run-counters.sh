#!/usr/bin/env bash
# Счётчики прогона (Ш-214 Штаба): на что ушли ходы — инструменты, запуски
# тестов, сборки и снимков, чтения документов проекта, рост контекста.
# Считает скрипт после прогона: токенов агента не тратит. Исполнитель,
# ревьюер и развязчик — один скрипт.
#
# Источник — файл прогона Claude Code (EXECUTION_FILE). Его Action пишет
# только в конце: при обрыве по времени файла нет — тогда журнал сессии
# Claude Code на раннере (~/.claude/projects/…/*.jsonl), он пишется по ходу.
#
# Вход (env): WHAT — что за прогон (строка, как в «Замере»);
# EXECUTION_FILE — может быть пустым. Выход: сводка шага и аннотация
# «Счётчики прогона» (её отдаёт REST — читает scripts/summary.py Штаба).
set -euo pipefail

src="файл прогона"
file=${EXECUTION_FILE:-}
if [ -z "$file" ] || [ ! -f "$file" ]; then
  # Журнал верхнего уровня (субагенты — в подпапках), самый свежий.
  file=$(ls -t "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/*.jsonl 2>/dev/null | head -1 || true)
  src="журнал сессии (файла прогона нет — обрыв?)"
fi
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "::warning title=Счётчики прогона::${WHAT:-?} | нет ни файла прогона, ни журнала сессии"
  exit 0
fi

# Файл прогона — массив JSON, журнал — строка на сообщение: -s сводит оба к
# массиву строк-сообщений.
if [ "$(head -c 1 "$file")" = "[" ]; then load='.[]'; else load='.'; fi

line=$(jq -s -r --arg what "${WHAT:-?}" --arg src "$src" --arg ws "${GITHUB_WORKSPACE:-}/" '
  [.[] | '"$load"'] as $all |
  # Главная нить: без субагентов.
  [$all[] | select(.type == "assistant" and (.parent_tool_use_id // null) == null and (.isSidechain // false) == false)] as $main |
  # Вызовы инструментов — по id: в потоке одно сообщение режется на части.
  ([$all[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")]
    | unique_by(.id)) as $tools |
  ([$all[] | select(.type == "result")] | last) as $res |
  ($res.num_turns // ([$main[] | .message.id] | unique | length)) as $turns |

  ($tools | group_by(.name) | map({n: .[0].name, c: length}) | sort_by(-.c)
    | map("\(.n) \(.c)") | join(", ")) as $by_tool |

  # Команды: без ведущих пробелов и cd; тесты — весь набор, если без аргументов.
  [$tools[] | select(.name == "Bash") | .input.command // "" | sub("^\\s+"; "")] as $cmds |
  ([$cmds[] | select(test("^npm (test|t|run test)\\b"))]) as $tests |
  ([$tests[] | select(test("^npm (test|t|run test)\\s*$"))] | length) as $tests_full |
  ([$cmds[] | select(test("^npm run \\S*build\\b"))] | length) as $build |
  ([$cmds[] | select(test("^npm run shots\\b"))] | length) as $shots |
  ([$cmds[] | select(test("^git\\b"))] | length) as $git |
  ([$cmds[] | select(test("^gh\\b"))] | length) as $gh |

  # Чтения документов проекта: docs/*.md и CLAUDE.md, целиком — без offset/limit.
  ([$tools[] | select(.name == "Read") | .input
     | {p: ((.file_path // "") | ltrimstr($ws)), whole: ((.offset == null) and (.limit == null))}
     | select(.p | test("(^|/)(docs/.*\\.md|CLAUDE\\.md)$"))]
   | group_by(.p) | map({p: .[0].p, c: length, w: ([.[] | select(.whole)] | length)})
   | sort_by(-.c)) as $docs |

  def ctx: .message.usage | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) / 1000 | round;

  [$what,
   "Источник: \($src)",
   "Ходов: \($turns)",
   "Инструменты: \(if $by_tool == "" then "—" else $by_tool end)",
   "Bash: тесты \($tests | length) (весь набор \($tests_full)), сборка \($build), снимки \($shots), git \($git), gh \($gh)",
   "Документы: \(if ($docs | length) == 0 then "—" else ($docs[:8] | map("\(.p) \(.c) (целиком \(.w))") | join("; ")) end)",
   "Контекст, тыс. токенов: \(if ($main | length) == 0 then "?" else "\($main[0] | ctx) → \($main[-1] | ctx)" end)"]
  | map(gsub("[\r\n]+"; " ") | gsub("\\|"; "¦")) | join(" | ")
' "$file")

{ echo ""; echo "### Счётчики прогона"; echo ""; echo "${line// | /$'\n\n'}"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "::notice title=Счётчики прогона::${line//%/%25}"
