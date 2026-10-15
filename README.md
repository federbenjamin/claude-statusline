# claude-statusline

<p align="center"><strong>A two-line Claude Code status line showing branch, PR, model, context, cost, cache and rate limits</strong></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/federbenjamin/claude-statusline" alt="License"></a>
</p>

Two bash scripts that render the status line in [Claude Code](https://docs.anthropic.com/en/docs/claude-code): one for the main session, one row per subagent. They read the JSON payload Claude Code pipes to the status line command and print two colored lines. For anyone who runs Claude Code in a terminal and wants to see where they are and what the session is costing without asking.

## Install

You need bash, `jq` and `git` on your PATH, and a Claude Code that has been run at least once. Works on macOS and Linux; on Windows, run it under Git Bash or WSL.

```sh
git clone https://github.com/federbenjamin/claude-statusline.git && cd claude-statusline && ./install.sh
```

The installer copies both scripts into `~/.claude/claude-statusline/` and sets `statusLine` and `subagentStatusLine` in `~/.claude/settings.json`, keeping a `.bak` of the previous file. It honours `CLAUDE_CONFIG_DIR`. Start a new Claude Code session to see it.

## Features

- **Where you are.** Repo and folder, branch, dirty marker, ahead and behind counts, the open PR number and its state. A linked worktree is marked.
- **Which model.** Model name colored by family (fable, opus, sonnet, haiku) and the session's effort level.
- **How full the context is.** Context used as a percentage, the headroom before compaction, and the number of compactions so far.
- **What it costs.** Session cost, and how long the prompt cache stays warm. Once the cache is cold, the tokens the next message re-writes.
- **How much quota is left.** The 5-hour session and 7-day weekly rate limits, each with its reset time once past half, and the account they belong to.
- **One row per subagent.** Agent type, label, model, effort, context percentage, compactions and elapsed time for every running subagent.
- **Fits the terminal.** When a line is wider than the terminal, the least useful parts drop first until it fits.

## Configuration

Both scripts read everything from the payload Claude Code sends, so there is nothing to set. The `refreshInterval` the installer writes makes the cache and reset timers tick once a minute.

Claude Code sends the rate limits only after a session's first reply, so until then they show as `?`. If a file at `~/.clauth/status.json` holds the limits for the current account, the scripts read them from there in the meantime; the comment header of the main script describes its shape.

## How it works

Claude Code runs the `statusLine` command on every event and pipes a JSON payload on stdin: session id, transcript path, working directory, model, context size, cost, cache state and rate limits. The main script parses it in one `jq` pass, asks `git` for the branch state, and keeps three small state files under `~/.claude/` per session: effort, compaction count, and the cached account name. The subagent script reads the `tasks` array of the same payload and counts compactions in each subagent's own transcript. The comment header at the top of each script describes every segment and the order parts drop in.

## Contributing

Report a problem in [Issues](https://github.com/federbenjamin/claude-statusline/issues). PRs are welcome; see [CONTRIBUTING.md](https://github.com/federbenjamin/.github/blob/main/CONTRIBUTING.md) and [SECURITY.md](https://github.com/federbenjamin/.github/blob/main/SECURITY.md). To try a change, feed a script a payload by hand:

```sh
echo '{"session_id":"test","model":{"display_name":"Claude Opus 5.5"},"workspace":{"current_dir":"'"$PWD"'"}}' | bash statusline-command.sh
```

## License

MIT © Benjamin Feder
