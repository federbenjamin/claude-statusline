#!/bin/bash
# Claude Code status line, two lines:
#   1  [worktree] (in a linked worktree) repo/path │ ⎇ branch · *dirty ↑ahead↓behind │ #PR · state
#   2  model (fable red | opus orange | sonnet yellow | haiku green) · effort │ Ctx: N% · →headroom · ↻compactions │ $cost · ◷cache │ Sess: N% →reset · Wk: N% →reset [· Fable: N%] · account
# Account: the local part of `claude auth status`'s email, which names the clauth profile
# (CLAUDE_CONFIG_DIR-aware). That call costs ~110ms, so its answer is kept per config dir and
# reused while the login's stamp (the Keychain item's mdat, else .credentials.json's mtime) is
# unchanged, for at most ACCOUNT_TTL seconds; with no stamp it runs every render.
# Sess (5h) and Wk (7d): the payload's rate_limits. Claude Code sends those only after
# the session's first reply; until then they come from that profile's windows in
# ~/.clauth/status.json, which the clauth daemon rewrites. Fable (the separate Fable 7d
# window) exists only there and shows on a Fable model. A value the daemon marks stale
# shows as ~N%; a missing one as ?. Above 50%, each shows when its window resets.
# ◷ is the prompt cache's time left before it goes cold, and once cold, the tokens the next
# message re-writes. The cache is the account's own: once the account differs from the one the
# last reply went under, ◷ reads cold. Claude Code redraws only on events, so settings.json sets
# statusLine.refreshInterval for the minutes to tick.
# Width: Claude Code sets COLUMNS to the terminal width. A line wider than COLUMNS − margin drops
# parts, first listed first, until it fits:
#   1  PR state, PR number, ahead/behind, dirty, branch, [worktree]; the folder always stays
#   2  account, Fable, cost, headroom, Wk, cache, compactions, effort, Sess, model; Ctx always stays
# With COLUMNS unset nothing drops.

shopt -s extglob
input=$(cat)
now=$(date +%s)

# Background status reads must not take git's index.lock from under a running git command.
export GIT_OPTIONAL_LOCKS=0

# One jq pass. The unit separator (\x1f) is not IFS whitespace, so empty fields survive `read`.
IFS=$'\x1f' read -r session_id transcript current_dir model effort context_size current_tokens sess_cost \
  sess_pct sess_reset wk_pct wk_reset cache_warm cache_expires recache pr_number pr_state < <(
  jq -r '
    def pct: if . == null then "" else . + 0.5 | floor end;
    [
      .session_id // "",
      .transcript_path // "",
      .workspace.current_dir // .cwd // "",
      (.model.display_name // "" | sub(" *\\([^)]*[Cc]ontext\\)"; "")),
      .effort.level // "",
      .context_window.context_window_size // 0,
      (.context_window.current_usage // {} | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)),
      .cost.total_cost_usd // "",
      (.rate_limits.five_hour.used_percentage | pct),
      .rate_limits.five_hour.resets_at // "",
      (.rate_limits.seven_day.used_percentage | pct),
      .rate_limits.seven_day.resets_at // "",
      (.prompt_cache.warm | if . == null then "" else . end),
      .prompt_cache.expires_at // "",
      .prompt_cache.recache_tokens_if_cold // "",
      .pr.number // "",
      .pr.review_state // ""
    ] | map(tostring) | join("\u001f")' <<<"$input"
)

RESET=$'\033[0m'
GRAY=$'\033[0;90m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[38;5;75m'
LIME=$'\033[38;5;34m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[0;31m'
BOLD_RED=$'\033[1;31m'
DEEP_RED=$'\033[38;5;124m'
separator="${GRAY} │ ${RESET}"
# Splits the parts inside one block.
dot="${GRAY} · ${RESET}"

# abbrev <int> → compact token count: >=1M "1.2M", >=10k "45k", >=1k "4.5k", else raw
abbrev() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000
    else if (n >= 10000) printf "%.0fk", n/1000
    else if (n >= 1000) printf "%.1fk", n/1000
    else printf "%d", n
  }'
}

# join_with <sep> <part>... → the non-empty parts joined by sep
join_with() {
  local sep=$1 out="" seg
  shift
  for seg in "$@"; do
    [ -z "$seg" ] && continue
    [ -n "$out" ] && out="${out}${sep}"
    out="${out}${seg}"
  done
  printf "%s" "$out"
}

# join_segments <segment>... → the non-empty segments joined by the separator
join_segments() { join_with "$separator" "$@"; }

# width <text> → the columns it takes on screen: color codes stripped, characters counted
width() {
  local LC_ALL=en_US.UTF-8
  local s=${1//$'\e'\[*([0-9;])m/}
  printf "%s" "${#s}"
}

# Columns Claude Code's own layout keeps beside the status line; empty budget = no fitting.
margin=4
budget=""
[[ "$COLUMNS" =~ ^[0-9]+$ ]] && budget=$((COLUMNS - margin))

# fit <compose function> <variable>... → the composed line; while it is wider than the budget,
# empties the next variable and composes again
fit() {
  local compose=$1 line
  shift
  line=$($compose)
  while [ -n "$budget" ] && [ $# -gt 0 ] && [ "$(width "$line")" -gt "$budget" ]; do
    # bash 3.2's printf -v skips the assignment for an empty format, hence "%s".
    printf -v "$1" "%s" ""
    shift
    line=$($compose)
  done
  printf "%s\n" "$line"
}

# shorten <path> <max> <keep> → path as is when it has at most max parts, else …/<last keep parts>
shorten() {
  awk -v p="$1" -v max="$2" -v keep="$3" 'BEGIN {
    n = split(p, s, "/")
    if (n <= max) { print p; exit }
    out = "…"; for (i = n - keep + 1; i <= n; i++) out = out "/" s[i]
    print out
  }'
}

# --- Line 1: worktree name + folder, then branch + git state ---
# Folder: in a repo, the repo name + the path inside it, up to 4 folders, past that
# repo/…/<last 3>. In a linked worktree the worktree's own path is skipped ([worktree] names
# it) and the cap is 3 folders, past that repo/…/<last 2>. Outside a repo, the ~ path;
# past 4 folders below ~, …/<last 3>.
[ -d "$current_dir" ] && cd "$current_dir"
dir_text=""
branch_text=""
worktree_text=""
dirty_text=""
ab_text=""
if { read -r git_dir; read -r git_common_dir; read -r git_top; } < <(
  git rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>/dev/null
); then
  # A linked worktree has its own git dir under the main repo's common one.
  [ "$git_dir" != "$git_common_dir" ] && worktree_text="${BLUE}[$(basename "$git_top")]${RESET}"
  if [ "$(basename "$git_common_dir")" = .git ]; then
    repo=$(basename "$(dirname "$git_common_dir")")
  else
    repo=$(basename "$git_top")
  fi
  inside=$(pwd -P); inside=${inside#"$git_top"}; inside=${inside#/}
  folder=$repo
  if [ -n "$inside" ]; then
    if [ -n "$worktree_text" ]; then
      folder="${repo}/$(shorten "$inside" 3 2)"
    else
      folder="${repo}/$(shorten "$inside" 4 3)"
    fi
  fi
  dir_text="${GRAY}${folder}${RESET}"
  branch=$(git branch --show-current 2>/dev/null)
  if [ -n "$branch" ]; then
    # Truncate ONLY a long branch name (last two chars → ".."); the git
    # dirty/ahead-behind info is its own part so it's never cut off.
    branch_max=42
    if [ ${#branch} -gt "$branch_max" ]; then branch="${branch:0:$((branch_max - 2))}.."; fi
    branch_text="${GREEN}⎇ ${branch}${RESET}"
    # Git state after a dot: dirty file count, then ahead/behind.
    # dirty working-tree file count (staged + unstaged + untracked)
    dirty=$(git status --porcelain 2>/dev/null | grep -c .)
    [ "${dirty:-0}" -gt 0 ] && dirty_text="${YELLOW}*${dirty}${RESET}"
    # ahead/behind vs origin/main (uses last-fetched origin/main; no fetch here)
    if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      read -r behind ahead < <(git rev-list --left-right --count origin/main...HEAD 2>/dev/null)
      ableg=""
      [ "${ahead:-0}" -gt 0 ] && ableg="↑${ahead}"
      [ "${behind:-0}" -gt 0 ] && ableg="${ableg}↓${behind}"
      [ -n "$ableg" ] && ab_text="${CYAN}${ableg}${RESET}"
    fi
  fi
fi

if [ -z "$dir_text" ] && [ -n "$current_dir" ]; then
  folder=$current_dir
  case "$folder" in "$HOME"|"$HOME"/*) folder="~${folder#"$HOME"}" ;; esac
  dir_text="${GRAY}$(shorten "$folder" 5 3)${RESET}"
fi

# --- Line 2, model + effort ---
# Effort colored by level: low green | medium yellow | high orange | xhigh red *n* | max deep-red **n**
# The session's effort is also saved for subagent-statusline.sh: its payload omits effort for a
# subagent that inherits the session's, and does not carry the session's own.
if [ -n "$session_id" ] && [ -n "$effort" ]; then
  effort_file="$HOME/.claude/.statusline-effort/$session_id"
  if [ "$(cat "$effort_file" 2>/dev/null)" != "$effort" ]; then
    [ -f "$effort_file" ] || { mkdir -p "${effort_file%/*}"; find "${effort_file%/*}" -type f -mtime +30 -delete; }
    echo "$effort" > "$effort_file"
  fi
fi
model_text=""
effort_text=""
if [ -n "$model" ]; then
  case "$model" in
    *[Ff]able*)  model_col="$RED" ;;
    *[Oo]pus*)   model_col="$ORANGE" ;;
    *[Ss]onnet*) model_col="$YELLOW" ;;
    *[Hh]aiku*)  model_col="$LIME" ;;
    *)           model_col="$YELLOW" ;;
  esac
  model_text="${model_col}${model}${RESET}"
  if [ -n "$effort" ]; then
    case "$effort" in
      low)    eff_col="$LIME";     eff_disp="$effort" ;;
      medium) eff_col="$YELLOW";   eff_disp="$effort" ;;
      high)   eff_col="$ORANGE";   eff_disp="$effort" ;;
      xhigh)  eff_col="$RED";      eff_disp="*${effort}*" ;;
      max)    eff_col="$DEEP_RED"; eff_disp="**${effort}**" ;;
      *)      eff_col="$YELLOW";   eff_disp="$effort" ;;
    esac
    effort_text="${eff_col}${eff_disp}${RESET}"
  fi
fi

# --- Line 2, context: Ctx% tiered >60 red | >50 orange | >40 yellow | else cyan ---
context_text=""
headroom_text=""
comp_text=""
if [ "$context_size" -gt 0 ] 2>/dev/null; then
  context_pct=$((current_tokens * 100 / context_size))
  if   [ "$context_pct" -gt 60 ]; then ctx_col="$BOLD_RED"
  elif [ "$context_pct" -gt 50 ]; then ctx_col="$ORANGE"
  elif [ "$context_pct" -gt 40 ]; then ctx_col="$YELLOW"
  else ctx_col="$CYAN"
  fi
  # Compaction headroom: tokens until auto-compact fires. Prefer the absolute
  # window (CLAUDE_CODE_AUTO_COMPACT_WINDOW, governs 1M sessions); else derive
  # from the pct override × the model's context window.
  # Auto-compact trigger = min(AUTO_COMPACT_WINDOW||full, full) × PCT_OVERRIDE%.
  # Claude Code MULTIPLIES the two: PCT is a percentage OF the window value, and
  # the window is capped at the model's real context size. (Both env vars set at
  # once compound — that's what fires compaction early if you don't expect it.)
  compact_win="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-$context_size}"
  [ "$compact_win" -gt "$context_size" ] && compact_win="$context_size"
  cpct="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-100}"
  compact_trigger=$(( compact_win * cpct / 100 ))
  headroom=$(( compact_trigger - current_tokens )); [ "$headroom" -lt 0 ] && headroom=0
  if   [ "$headroom" -gt 200000 ]; then hr_col="$LIME"
  elif [ "$headroom" -gt 100000 ]; then hr_col="$YELLOW"
  elif [ "$headroom" -gt 40000  ]; then hr_col="$ORANGE"
  else hr_col="$BOLD_RED"
  fi
  context_text="${ctx_col}Ctx: ${context_pct}%${RESET}"
  headroom_text="${hr_col}→$(abbrev "$headroom")${RESET}"

  # Compactions so far: the transcript's compact_boundary lines. A long transcript runs to tens
  # of MB, so a per-session state file keeps the byte offset already scanned and its count, and
  # each render reads only what was appended. 0 gray | 1 yellow | 2+ orange. Before the
  # transcript file exists (a brand-new session) it reads 0.
  if [ -n "$session_id" ] && [ -n "$transcript" ]; then
    state_dir="$HOME/.claude/.statusline-compactions"
    state="$state_dir/$session_id"
    offset=""; compactions=0
    [ -f "$state" ] && read -r offset compactions < "$state"
    size=$(stat -c %s "$transcript" 2>/dev/null || stat -f %z "$transcript" 2>/dev/null || echo 0)
    # A missing state, or a transcript smaller than the offset (rewritten), scans from the start.
    if [ -z "$offset" ] || [ "$size" -lt "$offset" ]; then offset=0; compactions=0; fi
    if [ "$size" -gt "$offset" ]; then
      [ -f "$state" ] || { mkdir -p "$state_dir"; find "$state_dir" -type f -mtime +30 -delete; }
      # Fixed-string, byte-locale grep: about 1s on a 175 MB transcript read whole, where
      # `tail -c +1 |` takes 3.7s; an appended tail of a few MB reads in ~0.04s.
      if [ "$offset" -eq 0 ]; then
        found=$(LC_ALL=C command grep -F -c '"subtype":"compact_boundary"' "$transcript")
      else
        found=$(tail -c +$((offset + 1)) "$transcript" | LC_ALL=C command grep -F -c '"subtype":"compact_boundary"')
      fi
      compactions=$((compactions + found))
      echo "$size $compactions" > "$state"
    fi
    case "${compactions:-0}" in
      0) comp_col="$GRAY" ;;
      1) comp_col="$YELLOW" ;;
      *) comp_col="$ORANGE" ;;
    esac
    comp_text="${comp_col}↻${compactions:-0}${RESET}"
  fi
fi

ACCOUNT_TTL=300
account=""
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
login_stamp=$(security find-generic-password -s "Claude Code-credentials" 2>/dev/null \
  | sed -n 's/.*"mdat"<timedate>=[^"]*"\([0-9]*Z\).*/\1/p')
[ -z "$login_stamp" ] && login_stamp=$(stat -c %Y "$config_dir/.credentials.json" 2>/dev/null || stat -f %m "$config_dir/.credentials.json" 2>/dev/null)
acct_cache="$HOME/.claude/.statusline-account/$(printf '%s' "$config_dir" | cksum | cut -d' ' -f1)"
if [ -n "$login_stamp" ] && [ -f "$acct_cache" ]; then
  read -r c_stamp c_at c_account < "$acct_cache"
  [ "$c_stamp" = "$login_stamp" ] && [ $(( now - ${c_at:-0} )) -lt "$ACCOUNT_TTL" ] && account=$c_account
fi
if [ -z "$account" ] && command -v claude >/dev/null 2>&1; then
  account=$(claude auth status --json 2>/dev/null \
    | jq -r 'select(.loggedIn == true) | .email // empty | split("@")[0]' 2>/dev/null)
  if [ -n "$account" ] && [ -n "$login_stamp" ]; then
    mkdir -p "${acct_cache%/*}" && echo "$login_stamp $now $account" > "$acct_cache"
  fi
fi

# --- Line 2, prompt cache time left (beside the cost): >20m green | >5m yellow | else orange | cold red.
# warm and expires_at describe the last reply, so compare expires_at with now. A new expires_at is
# a new reply: the first render after it records the account it went under, per session; a later
# render under another account (clauth switch) shows cold, as the next request rebuilds the cache.
cache_text=""
if [ -n "$cache_warm" ]; then
  left=0
  [ "$cache_warm" = true ] && [ -n "$cache_expires" ] && left=$(( cache_expires - now ))
  if [ "$left" -gt 0 ] && [ -n "$session_id" ] && [ -n "$account" ]; then
    acct_file="$HOME/.claude/.statusline-cache-account/$session_id"
    rec_expires=""; rec_account=""
    [ -f "$acct_file" ] && read -r rec_expires rec_account < "$acct_file"
    if [ "$rec_expires" != "$cache_expires" ]; then
      [ -f "$acct_file" ] || { mkdir -p "${acct_file%/*}"; find "${acct_file%/*}" -type f -mtime +30 -delete; }
      echo "$cache_expires $account" > "$acct_file"
    elif [ -n "$rec_account" ] && [ "$rec_account" != "$account" ]; then
      left=0
    fi
  fi
  if [ "$left" -gt 0 ]; then
    mins=$(( (left + 59) / 60 ))
    if   [ "$mins" -gt 20 ]; then cache_col="$LIME"
    elif [ "$mins" -gt 5 ];  then cache_col="$YELLOW"
    else cache_col="$ORANGE"
    fi
    cache_text="${cache_col}◷${mins}m${RESET}"
  else
    # Cold: the next message re-writes the whole cached prefix; show its size (recache_tokens_if_cold,
    # which is null right after a compaction; the context's token count stands in then).
    cache_text="${BOLD_RED}◷cold $(abbrev "${recache:-$current_tokens}")${RESET}"
  fi
fi

# --- Line 2, account + Sess (5h) / Wk (7d) usage ---
account_text=""
[ -n "$account" ] && account_text="${GRAY}${account}${RESET}"

# clauth's copy of this account's windows: 5h and 7d stand in until the session's first reply
# brings rate_limits; the separate Fable weekly window exists only here, shown on Fable models.
mark=""; fable_mark=""; fable_pct=""; fable_reset=""
is_fable=""; case "$model" in *[Ff]able*) is_fable=1 ;; esac
status_file="$HOME/.clauth/status.json"
if [ -n "$account" ] && [ -r "$status_file" ] && { [ -z "$sess_pct$wk_pct" ] || [ -n "$is_fable" ]; }; then
  IFS=$'\x1f' read -r c_sess c_sess_reset c_wk c_wk_reset fable_pct fable_reset stale < <(
    jq -r --arg p "$account" '
      def epoch: if . == null then "" else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 end;
      def win($l): [.windows[] | select(.label == $l)] | first // {};
      def pct: .utilization_pct // null | if . == null then "" else . + 0.5 | floor end;
      .profiles[] | select(.name == $p)
      | [ (win("5h") | pct), (win("5h") | .resets_at | epoch),
          (win("7d") | pct), (win("7d") | .resets_at | epoch),
          (win("7d fable") | pct), (win("7d fable") | .resets_at | epoch),
          .stale ]
      | map(tostring) | join("\u001f")' "$status_file" 2>/dev/null
  )
  [ "$stale" = "true" ] && fable_mark="~"
  if [ -z "$sess_pct$wk_pct" ]; then
    sess_pct=$c_sess; sess_reset=$c_sess_reset; wk_pct=$c_wk; wk_reset=$c_wk_reset; mark=$fable_mark
  fi
fi

# usage_color <pct> → truecolor on one scale for Sess and Wk: green at 0, yellow at 50, red at 100
usage_color() {
  awk -v p="$1" 'BEGIN {
    if (p < 0) p = 0; if (p > 100) p = 100
    if (p <= 50) { t = p / 50; r = 80 + t * 140; g = 200; b = 70 - t * 10 }
    else         { t = (p - 50) / 50; r = 220; g = 200 - t * 140; b = 60 }
    printf "\033[38;2;%d;%d;%dm", r, g, b
  }'
}

# usage_segment <label> <pct> <reset epoch> <reset date format> <stale mark> → "Label: N%",
# plus " →<reset>" above 50%, colored by usage_color; "Label: ?" in gray when pct is unknown.
usage_segment() {
  local label=$1 pct=$2 reset=$3 fmt=$4 stale_mark=$5 text when
  if [ -z "$pct" ]; then
    printf "%s" "${GRAY}${label}: ?${RESET}"
    return
  fi
  text="${label}: ${stale_mark}${pct}%"
  if [ "$pct" -gt 50 ] && [ -n "$reset" ]; then
    # Round to the minute; lowercase am/pm with no leading zero on the hour.
    at=$(( (reset + 30) / 60 * 60 ))
    when=$( { date -r "$at" "+$fmt" 2>/dev/null || date -d "@$at" "+$fmt" 2>/dev/null; } | sed 's/AM$/am/; s/PM$/pm/; s/^0//; s/ 0/ /')
    [ -n "$when" ] && text="${text} →${when}"
  fi
  printf "%s" "$(usage_color "$pct")${text}${RESET}"
}
sess_text=$(usage_segment Sess "$sess_pct" "$sess_reset" "%I:%M%p" "$mark")
wk_text=$(usage_segment Wk "$wk_pct" "$wk_reset" "%a %I:%M%p" "$mark")
fable_text=""
[ -n "$is_fable" ] && fable_text=$(usage_segment Fable "$fable_pct" "$fable_reset" "%a %I:%M%p" "$fable_mark")

# --- Line 2, cost: Claude Code's own session estimate (cost.total_cost_usd) ---
# Colored on usage_color's scale: green up to $50, then yellow at $125, red from $200.
cost_text="${GRAY}\$n/a${RESET}"
if [ -n "$sess_cost" ]; then
  read -r cost_disp cost_pct < <(awk -v c="$sess_cost" 'BEGIN {
    printf (c >= 1 ? "%.2f" : "%.3f"), c
    printf " %d\n", (c - 50) / 1.5
  }')
  cost_text="$(usage_color "$cost_pct")\$${cost_disp}${RESET}"
fi

# --- Line 1, open PR for this branch: number + review state (the footer shows only the number).
# approved green | pending yellow | changes_requested red | draft gray; absent once it merges or closes.
pr_text=""
pr_state_text=""
if [ -n "$pr_number" ]; then
  case "$pr_state" in
    approved) pr_col="$LIME" ;;
    pending) pr_col="$YELLOW" ;;
    changes_requested) pr_col="$BOLD_RED"; pr_state="changes requested" ;;
    *) pr_col="$GRAY" ;;
  esac
  pr_text="${GRAY}#${pr_number}${RESET}"
  [ -n "$pr_state" ] && pr_state_text="${pr_col}${pr_state}${RESET}"
fi

# Each line is composed from its parts; fit empties them in the header's drop order.
line1() {
  join_segments \
    "$(join_with " " "$worktree_text" "$dir_text")" \
    "$(join_with "$dot" "$branch_text" "$(join_with " " "$dirty_text" "$ab_text")")" \
    "$(join_with "$dot" "$pr_text" "$pr_state_text")"
}
# Sess, Wk (Fable on a Fable model) and the account form one block, the account last.
line2() {
  join_segments \
    "$(join_with "$dot" "$model_text" "$effort_text")" \
    "$(join_with "$dot" "$context_text" "$headroom_text" "$comp_text")" \
    "$(join_with "$dot" "$cost_text" "$cache_text")" \
    "$(join_with "$dot" "$sess_text" "$wk_text" "$fable_text" "$account_text")"
}

fit line1 pr_state_text pr_text ab_text dirty_text branch_text worktree_text
fit line2 account_text fable_text cost_text headroom_text wk_text cache_text comp_text effort_text sess_text model_text
