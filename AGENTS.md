# claude-statusline

claude-statusline is a two-line status line for Claude Code, for anyone who runs it in a terminal and wants to see their session at a glance. Two bash scripts read the JSON payload Claude Code pipes to the status line command: `statusline-command.sh` for the main session and `subagent-statusline.sh` for one row per subagent. They show branch and PR, model, context use, cost, prompt-cache state, and rate limits, and `install.sh` copies them into place and edits the user's Claude Code settings.

<!-- >>> git-workflow (generated block; do not edit by hand) -->
## Git workflow

- `main` changes only through a PR, squash-merged.
<!-- <<< git-workflow -->

## Project state

- 2026-10-15: not launched — no release yet. Retires at the first version tag.
- 2026-10-15: the project holds no user data; each user's files stay on their own machine. Retires if it ever stores or sends data off the user's machine.
