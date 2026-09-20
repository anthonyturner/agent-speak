---
description: Stop, pause, resume or check the speech playing right now
argument-hint: "stop | pause | resume | toggle | status"
allowed-tools: Bash(node:*)
---

Transport controls for speech that is already playing. Side-effect only: run it,
reply with a single short line, nothing else. It never speaks anything itself and
never starts a playback - that is `/agent-speak:play`.

Arguments: $ARGUMENTS

Run, with the argument mapped to a subcommand:

```
node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" <subcommand>
```

| Said | Subcommand | The script prints |
| --- | --- | --- |
| `stop`, `shut up`, `quiet`, `cancel` | `stop` | `stopped` / `nothing was playing` |
| `pause`, `hold`, `wait` | `pause` | `paused` / `nothing is playing` |
| `resume`, `continue`, `unpause`, `go on` | `resume` | `resumed` |
| `toggle`, no argument at all | `toggle` | `paused` / `resumed` |
| `status`, `what is playing` | `status` | `playing` / `paused` / `idle` |
| `skip`, `forward`, `next` | `forward` | `skipped` (+10 seconds) |
| `back`, `rewind`, `previous` | `rewind` | `rewound` (-10 seconds) |

Report what it actually printed, not what you expected. If it says nothing was
playing, say that.

**Treat the bare words as this command even without the slash.** "Stop talking",
"pause that", "shut up", "keep going" are this command, not an invitation to
discuss speech settings.

## Keyboard media keys

If the hotkey listener is running, the keyboard's own transport keys do all of
this without typing: **Play/Pause** toggles, **Next** skips forward, **Previous**
skips back. They are only captured while speech is playing, and pass straight
through to whatever else is playing music the rest of the time.

Start it with `node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" hotkeys`, and
`hotkeys stop` / `hotkeys status` to manage it.

## When it misbehaves

- **Stop** kills the player outright, so it works even if the player is wedged.
- **Pause and resume** cannot kill anything - the audio has to survive to be
  resumed - so they write into `~/.claude/agent-speak/.tts.ctl`, which the player
  polls about eight times a second. Expect pause to land within a fraction of a
  second, not instantly.
- **If speech has gone silent entirely**, suspect a stale `.tts.pid` naming a
  `manual` playback: that makes the end-of-turn cue stay quiet on purpose so it
  does not talk over you. `stop` clears it.
- `~/.claude/agent-speak/errors.log` records failures the script swallowed.
