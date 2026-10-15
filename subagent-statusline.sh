#!/bin/bash
# Claude Code subagentStatusLine: one row per subagent in the panel below the prompt.
#   (agent type) label · model · effort · ctx% · ↻compactions · elapsed
# Agent type is the definition's name (builder, fixer, Explore). The payload does not carry it
# (`name` is null, `type` is "local_agent", `label` is the spawn description), so it comes from
# agentType in the subagent's meta file beside its transcript, shown in parens before the label;
# nothing when that file is absent.
# Model shows family and version from the payload's model ID (claude-sonnet-5-5 → sonnet 5.5;
# an ID that does not parse shows as is), colored as on the main line: fable red | opus orange |
# sonnet yellow | haiku green.
# Effort set by the agent's definition shows in its level's color. The payload omits effort for
# a subagent that inherits the session's, so that one shows the session's effort in gray, as
# statusline-command.sh saved it for this session_id; nothing when none was saved. Haiku has no
# effort setting, so its rows never show one.
# ctx% is tokenCount over contextWindowSize, in the main line's Ctx tiers: >60 red | >50 orange |
# >40 yellow | else cyan; nothing when the window size is unknown.
# Compactions are the compact_boundary lines in the subagent's own transcript, which sits beside
# the parent's at <transcript_path minus .jsonl>/subagents/agent-<task id>.jsonl; colored as on
# the main line: 0 gray | 1 yellow | 2+ orange. Before that file exists it reads 0. A subagent
# transcript is a few MB at most, so each render greps it whole.
# A finished row shows `done`: the payload has a start time but no end time.
# Width: the payload's `columns` is the usable row width. A row wider than that drops parts,
# first listed first, until it fits:
#   compactions, ctx%, effort, model, elapsed
# If it still does not fit, the label is cut short with …; the agent type and label stay.
# With no `columns` nothing drops.
# Input: {columns, session_id, transcript_path, tasks: [{id, label, status, startTime (ms), model,
# effort, contextWindowSize, tokenCount}]}; output: one {"id", "content"} line per task.

input=$(cat)
now_ms=$(( $(date +%s) * 1000 ))
session_id=$(jq -r '.session_id // empty' <<<"$input")
inherited=""
[ -n "$session_id" ] && inherited=$(cat "$HOME/.claude/.statusline-effort/$session_id" 2>/dev/null)
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
compactions="{}"
types="{}"
if [ -n "$transcript" ]; then
  sub_dir="${transcript%.jsonl}/subagents"
  ids=$(jq -r '.tasks[]?.id // empty' <<<"$input")
  compactions=$(while read -r id; do
      f="$sub_dir/agent-$id.jsonl"
      [ -f "$f" ] && printf '%s %s\n' "$id" "$(LC_ALL=C command grep -F -c '"subtype":"compact_boundary"' "$f")"
    done <<<"$ids" | jq -R -s -c 'split("\n") | map(select(. != "") | split(" ") | {(.[0]): (.[1] | tonumber)}) | add // {}')
  types=$(while read -r id; do
      f="$sub_dir/agent-$id.meta.json"
      [ -f "$f" ] && printf '%s %s\n' "$id" "$(jq -r '.agentType // empty' "$f" 2>/dev/null)"
    done <<<"$ids" | jq -R -s -c 'split("\n") | map(select(. != "") | split(" ") | select(length == 2) | {(.[0]): .[1]}) | add // {}')
fi
jq -c --argjson now "$now_ms" --arg inherited "$inherited" --argjson comp "$compactions" --argjson types "$types" '
  def c($code; $s): "\u001b[" + $code + "m" + $s + "\u001b[0m";
  def dot: c("0;90"; " · ");
  def plain: gsub("\u001b\\[[0-9;]*m"; "");
  # claude-sonnet-5-5 → "sonnet 5.5"; claude-haiku-4-5-20251001 → "haiku 4.5"; claude-opus-5 → "opus 5".
  def model_name: (.model // "" | ascii_downcase) as $m
    | ([$m | capture("(?<fam>fable|opus|sonnet|haiku)-(?<maj>[0-9]+)(?:-(?<min>[0-9]{1,2})(?![0-9]))?")] | first) as $p
    | if $p then $p.fam + " " + $p.maj + (if $p.min then "." + $p.min else "" end) else .model end;
  def model_seg: (.model // "" | ascii_downcase) as $m
    | if $m == "" then empty
      elif ($m | test("fable")) then c("0;31"; model_name)
      elif ($m | test("opus")) then c("38;5;208"; model_name)
      elif ($m | test("sonnet")) then c("0;33"; model_name)
      elif ($m | test("haiku")) then c("38;5;34"; model_name)
      else c("0;33"; .model) end;
  def effort_seg: if ((.model // "") | ascii_downcase | test("haiku")) then empty
    elif .effort == null then (if $inherited == "" then empty else c("0;90"; $inherited) end)
    else .effort | tostring
    | if . == "low" then c("38;5;34"; .)
      elif . == "medium" then c("0;33"; .)
      elif . == "high" then c("38;5;208"; .)
      elif . == "xhigh" then c("0;31"; "*" + . + "*")
      elif . == "max" then c("38;5;124"; "**" + . + "**")
      else c("0;33"; .) end end;
  def ctx_seg: (.tokenCount // 0) as $t
    | if (.contextWindowSize // 0) > 0 then
        ($t * 100 / .contextWindowSize | floor) as $p
        | c(if $p > 60 then "1;31" elif $p > 50 then "38;5;208" elif $p > 40 then "0;33" else "0;36" end; "\($p)%")
      else empty end;
  def comp_seg: ($comp[.id] // 0) as $n
    | c(if $n == 0 then "0;90" elif $n == 1 then "0;33" else "38;5;208" end; "↻\($n)");
  def time_seg: if .status == "running" and .startTime then
        (($now - .startTime) / 1000 | floor) as $s
        | c("0;90"; if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m" else "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m" end)
      else c("0;90"; .status // "" | if . == "completed" then "done" else . end) end;
  # The row text of a list of {k, s} parts; empty parts are skipped.
  def row: map(select(.s != "") | .s) | join(dot);
  def cols: map(select(.s != "") | .s | plain | length) | add // 0;
  def row_width: (map(select(.s != "")) | length) as $n | cols + (if $n > 1 then ($n - 1) * 3 else 0 end);
  # Drops parts in order while the row is wider than $budget, then cuts the label.
  def fit($budget): if $budget <= 0 then . else
      reduce ("comp", "ctx", "effort", "model", "time") as $k (.;
        if row_width > $budget then map(if .k == $k then .s = "" else . end) else . end)
      | if row_width > $budget then
          (row_width - $budget) as $over
          | map(if .k == "label" then
              (.l | length) as $len
              | .s = .p + (if $len - $over < 2 then .l[0:1] + "…" else .l[0:($len - $over - 1)] + "…" end)
            else . end)
        else . end
    end;
  (.columns // 0) as $budget
  | .tasks[]? | . as $t | ($types[.id] // "") as $type
  | {id, content: ([
      (.label // .description // .name // .id | tostring) as $label
        | (if $type == "" then "" else c("1"; "(\($type)) ") end) as $prefix
        | {k: "label", p: $prefix, l: $label, s: ($prefix + $label)},
      {k: "model", s: (model_seg // "")},
      {k: "effort", s: (effort_seg // "")},
      {k: "ctx", s: (ctx_seg // "")},
      {k: "comp", s: comp_seg},
      {k: "time", s: time_seg}
    ] | fit($budget) | row)}
' <<<"$input"
