# agentwake

Keep your Mac awake while Claude Code (or any long command) is working — and only then.

You hand a task to an agent, walk away, and come back to find the Mac fell asleep halfway through. `agentwake` holds a macOS power assertion exactly while work is running and releases it the moment it ends, then tells you it's done.

[한국어 설명은 아래에 있습니다](#한국어)

## Install

```sh
brew install jamesleetu/tap/agentwake
agentwake install-hooks
```

`install-hooks` adds four hooks to `~/.claude/settings.json` (your existing hooks are kept, and a backup is written next to it). New Claude Code sessions pick them up automatically; in a running session, open `/hooks` once.

Already get "task done" notifications from another tool? Use `agentwake install-hooks --quiet` to keep the sleep prevention but skip agentwake's own notification.

<details>
<summary>Build from source</summary>

```sh
git clone https://github.com/jamesleetu/agentwake && cd agentwake
swift build -c release
rm -f ~/.local/bin/agentwake && cp .build/release/agentwake ~/.local/bin/
~/.local/bin/agentwake install-hooks
```

Remove the old binary before copying a new one over it: overwriting a signed binary in place makes macOS kill it on launch.
</details>

## How it works

| Claude Code event | agentwake |
|---|---|
| `UserPromptSubmit` | Starts a small background holder with a `PreventUserIdleSystemSleep` assertion |
| `Stop` / `StopFailure` / `SessionEnd` | Releases it and notifies you if the task took 30s or more |

The holder also watches the Claude process with kqueue, so if you close the terminal mid-task the assertion is released right away. A hard cap (6 hours by default) guards against anything getting stuck.

You can verify it at any time:

```sh
agentwake status              # sessions keeping the Mac awake
pmset -g assertions | grep agentwake
```

## Other commands

```sh
agentwake run -- npm run build   # keep awake while a command runs, notify when done
agentwake wait 12345             # keep awake until an already-running process exits
agentwake uninstall-hooks        # remove the Claude Code hooks
```

## Configuration

| Variable | Default | |
|---|---|---|
| `AGENTWAKE_MIN_NOTIFY` | `30` | Only notify for tasks longer than this many seconds |
| `AGENTWAKE_MAX_HOURS` | `6` | Safety cap on a single hold |
| `AGENTWAKE_NOTIFY` | on | `0` turns off the desktop notification |
| `AGENTWAKE_NTFY_TOPIC` | – | Also push to your phone via [ntfy.sh](https://ntfy.sh) (free) |
| `AGENTWAKE_LANG` | system | `en` or `ko` |

Notifications use [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) when installed, otherwise the built-in `osascript` notification.

## Do I need this with Claude Code?

Recent interactive Claude Code sessions keep the Mac awake on their own while working (they run `caffeinate -i` in the background; observed in 2.1.303). If that's all you use, you may not need agentwake's hooks.

agentwake still covers what that doesn't:

- **Headless runs** — `claude -p` in scripts and automation did not hold off sleep in our tests; agentwake's hooks do.
- **Anything that isn't Claude** — long builds, training runs, downloads: `agentwake run -- <command>` or `agentwake wait <pid>`.
- **Done notifications**, optionally pushed to your phone.

## Limitations

- **Closing the lid still sleeps the Mac.** This prevents *idle* sleep (walking away), not clamshell sleep — unless you're on power with an external display. Verified: with agentwake holding, closing the lid logged `Clamshell Sleep`, and the hold resumed normally on wake.
- Reported durations count time the Mac was awake, so a task interrupted by closing the lid isn't reported as taking longer than it worked.
- If all you need is to wrap one command, macOS already ships `caffeinate -i -w <pid>`. agentwake's value is the automatic integration and the done notification.

---

## 한국어

Claude Code에 일을 맡기고 자리를 비웠다가 돌아와 보니 Mac이 잠들어 작업이 멈춰 있던 적이 있다면, agentwake가 해결합니다. **작업이 도는 동안에만** 잠자기를 막고, 끝나면 바로 풀고 알려 줍니다.

```sh
brew install jamesleetu/tap/agentwake
agentwake install-hooks          # 다른 도구로 이미 완료 알림을 받는다면 --quiet
```

- `install-hooks`는 `~/.claude/settings.json`에 hook 4개를 추가합니다. 기존 hook은 그대로 두고 백업을 남깁니다.
- `agentwake status`로 지금 잠자기를 막고 있는 세션을 볼 수 있습니다.
- 최근 대화형 Claude Code는 작업 중에 스스로 잠자기를 막습니다(2.1.303에서 확인). agentwake가 필요한 곳은 `claude -p` 같은 헤드리스 실행, Claude가 아닌 긴 작업(`agentwake run`, `agentwake wait`), 완료 알림입니다.
- 노트북 뚜껑을 닫으면 그대로 잠듭니다. 자리를 비워 생기는 유휴 잠자기만 막습니다.
- 알림에 표시되는 소요 시간에서 Mac이 잠들어 있던 시간은 빠집니다.
- 설정 변수와 다른 명령은 위 영어 설명을 참고하세요. 메시지는 시스템 언어에 따라 한국어로 나옵니다.

## License

MIT
