#!/usr/bin/env bash
# Замер прогона (Ш-19 Штаба) — ревьюер и развязчик: ходы и время из итога
# Claude Code, а не со слов агента; отказы в правах; последние слова агента;
# событие лимита подписки (Ш-52: предохранителя у них нет — только замер).
#
# Вход (env): EXECUTION_FILE, WHAT — что проверяли (строка), MODEL, TURNS.
set -euo pipefail

[ -n "${EXECUTION_FILE:-}" ] && [ -f "$EXECUTION_FILE" ] || exit 0
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

{
  jq -r --arg what "$WHAT" --arg model "$MODEL" --arg turns "$TURNS" '
    [.[] | select(.type == "result")] | last |
    "### Замер прогона",
    "",
    $what,
    "",
    "Модель: \($model)",
    "",
    "Ходов: \(.num_turns) из \($turns), минут: \((.duration_ms / 60000 * 10 | floor) / 10)",
    "",
    "Отказано в правах: \(.permission_denials | length)",
    (.permission_denials[]? | "- \(.tool_name): \((.tool_input.command // .tool_input.file_path // "") | tostring | .[0:120])")
  ' "$EXECUTION_FILE"
  jq -r '
    [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // "—" |
    "", "Последние слова агента: \(.[0:300] | gsub("\n"; " "))"
  ' "$EXECUTION_FILE"
  jq -r '
    [.[] | select(.type == "rate_limit_event") | .rate_limit_info // {} | "\(.rateLimitType // "?"): \(.status // "?")"] | unique |
    "", "Лимит подписки: \(if length == 0 then "событий нет" else join(", ") end)"
  ' "$EXECUTION_FILE"
} | tee -a "$summary"
