# agent-speak

Your agent tells you it's done — out loud, in one line. Then reads the whole
answer back only if you ask.

```
"Issue 466, notification toast layout.
 The draft pull request is up and ready for review."
```

That's the whole idea. Most "read my agent's output aloud" setups read the
*response*, which is written to be read, not heard — you get the first few
hundred characters of a document narrated at you. This reads a **handover**
instead: one sentence saying the work is finished and what you do next. The
answer itself stays on screen until you ask for it.

**How it works underneath:** [Design notes](DESIGN-NOTES.md) — why it speaks a
handover instead of the response, why the media keys use a low-level hook, and
the job object that silently killed detached playback.

> **Windows only for now.** The speech engine uses Windows APIs (MCI for
> pausable playback, SAPI5 as the offline voice, a low-level keyboard hook for
> the media keys). Installing on macOS or Linux is harmless — every hook exits
> quietly — but nothing will speak. See [Porting](#porting).

## Why you'd want it

- **You run several agent sessions at once.** Each spoken line starts with a
  label naming its session, so you know which window just finished.
- **You look away while it works.** The cue is the notification; you don't have
  to watch the terminal to know it's your turn.
- **You want the detail sometimes.** `/agent-speak:play` reads the full response
  back, with pause, resume and 10-second skips.

## Install

```
/plugin marketplace add anthonyturner/agent-speak
/plugin install agent-speak
```

Or to try it locally, from the directory above this one:

```
claude --plugin-dir ./agent-speak
```

**Requires:** Windows, and Node.js on `PATH` (the plugin's entry point is a Node
script — it's what keeps the plugin quiet on other platforms).

### Give it a voice

Out of the box it uses the built-in Windows voice, which is free, offline and
robotic. For a natural one, set an [ElevenLabs](https://elevenlabs.io) key:

```powershell
setx ELEVENLABS_API_KEY "your-key-here"
```

Then check it:

```
/agent-speak:speak testing one two three
```

`node <plugin>/bin/agent-speak.js diag` prints which engine is active, whether
the key and voice are configured, and how much quota is left. It never prints
the key.

## Talking while it works

The cue is the end of the turn. Two things speak *during* one.

**The agent narrates its own decisions.** At a point worth overhearing — picking
between two approaches, changing course after finding something out — it says one
line and carries on working:

> "Going with CSS derivation rather than hand-tuned pixels."

**Each subagent says when it's done.** Run anything that fans work out and you
hear the shape of it going past:

> "The engineer agent finished: wire the manifest window."

These **queue**. Everything else here speaks by interrupting, which is right for a
handover and wrong for a stream of short lines — you'd get the first syllable of
each and the whole of none. Narration lines wait their turn and are spoken in
order. The end-of-turn cue still interrupts them, on purpose: once the turn is
over, a narration line is stale.

Narration is billed like anything else, so it's capped and it's optional:

```json
{ "SpeakNarration": false }
```

## Running it on several windows

Speech is per-session, and so is turning it off. Every window speaks by default;
one that you want quiet, you mute:

```
/agent-speak:tts mute      →  muted      (this window only)
/agent-speak:tts unmute    →  speaking
```

Bare phrases work, as with the other transport words — "be quiet in this window",
"you can talk again".

Mute covers everything the plugin says on its own initiative: cues, narration and
notifications. It does **not** cover `/agent-speak:speak` or `/agent-speak:play` —
asking out loud to hear something is not overruled by a flag you set an hour ago.
Nothing is banked while muted, either: cues are consumed and discarded as they
arrive, so unmuting never empties an hour of handovers over you.

`stop` and `mute` are different tools. `stop` kills the sentence playing now;
`mute` silences the window until you say otherwise.

**Windows don't talk over each other.** Every automatic utterance goes through one
queue, so a turn ending in a window you aren't looking at waits its turn instead
of cutting off the one you are. Within a single window a cue still supersedes that
window's own pending narration — once the turn is over, "I'm about to try X" is
not worth hearing after X is finished.

The exception is notifications, which still interrupt on purpose: a window
notifying you is blocked waiting for you, and making that queue behind another
window's sentence is the one case where being polite is wrong.

## It waits while you're talking

Dictating to one agent while another starts talking is the worst case here — you
can't reach for pause without stopping dictating, and what you're saying lands in
the transcript on top of what it's saying back.

So automatic speech holds while your microphone is live, and carries on when you
release it, after a short settle — you're usually still reading the transcription
back when the mic closes.

```json
{ "MicHoldApps": ["WisprFlow"] }
```

**It's a list of apps, not "is the microphone in use", and that matters.** Windows
reports OBS, virtual-camera software and conferencing apps as holding the
microphone for as long as they're open. Gate on the microphone in general and the
machine never speaks again — which looks like a broken plugin, not a wrong
setting. Only the apps named here count as *you talking*. Add `Discord`, `Zoom` or
`ms-teams` to hold speech during calls too.

The wait is capped (`MicWaitMaxSec`, 90s). Something holding the mic forever should
mean a late line, not silence with no explanation.

`/speak` and `/play` aren't gated — you asked for those out loud.

When it won't talk and you want to know why:

```
node <plugin>/bin/agent-speak.js diag

Holds for mic      : WisprFlow
Microphone now     : HOLDING - C:\...\WisprFlow\app-1.6.897\Wispr Flow.exe
```

### Why it doesn't just read the thinking aloud

The obvious version of this feature — narrate the model's reasoning — isn't
available to build. Extended thinking isn't persisted: every `thinking` block on
disk is `{type, thinking: "", signature}`, with no text in it. The terminal draws
it from the live stream and keeps nothing.

So the reasoning is *authored* for the ear instead, by the agent, as it happens —
the same contract as the cue. Which is the better artefact anyway: raw thinking
read end to end would be exactly the unlistenable narration this plugin exists to
avoid.

## Commands

| Command | Does |
| --- | --- |
| `/agent-speak:play` | read the last full response aloud |
| `/agent-speak:tts pause` | pause, resume, stop, skip, or report status |
| `/agent-speak:tts mute` | silence this window until you unmute it |
| `/agent-speak:speak <text>` | speak a specific piece of text |

And one the agent calls itself, mid-turn:

```
node <plugin>/bin/agent-speak.js say "the line" --session <session_id>
```

Bare phrases work too — "play the full response", "pause", "stop talking",
"keep going" — no slash needed.

## Media keys

Your keyboard's transport keys drive playback, if you start the listener:

```
node <plugin>/bin/agent-speak.js hotkeys
```

| Key | While speaking | Otherwise |
| --- | --- | --- |
| ⏯ Play/Pause | pause ⇄ resume | passes through |
| ⏭ Next | skip forward 10s | passes through |
| ⏮ Previous | skip back 10s | passes through |

**The keys are only captured while speech is actually playing.** Every other
moment they go to Spotify, YouTube, whatever you're really listening to. That's
why this is a low-level keyboard hook rather than `RegisterHotKey`: a hook can
decide, per keypress, to hand the key back. `RegisterHotKey` can't.

The hook inspects three virtual-key codes and ignores every other key without
reading it. Nothing is recorded or sent anywhere; it can only write `play`,
`pause` or a number into two files under `~/.claude/agent-speak/`.

Not all keyboards emit key codes for media keys — some send HID consumer-control
usages that become `WM_APPCOMMAND` and never reach a keyboard hook. If yours
does that, `hotkeys trace` will log nothing when you press them.

## How the cue works

A `SessionStart` hook tells the agent, once per session, to write one line to
`~/.claude/agent-speak/speak-cues/<session_id>.txt` before finishing a turn. The
`Stop` hook speaks that line, then deletes it — so a cue can never be replayed on
a later turn. A turn that writes no cue is announced with a generic
`Response ready.`

A second file, `speak-labels/<session_id>.txt`, holds the session's name and is
spoken first. Write it once; it lasts the session.

## Configuration

Copy `config.example.json` to `~/.claude/agent-speak/config.json`. Every key is
optional. It lives outside the plugin directory on purpose: a plugin update
replaces the plugin, and your voice choice has to survive that.

Never put your API key in it — that's read from the environment.

## Files it owns

Everything lives in `~/.claude/agent-speak/`:

| File | Purpose |
| --- | --- |
| `config.json` | your settings |
| `speak-cues/`, `speak-labels/` | per-session copy |
| `.tts.pid` | which process is playing |
| `.tts.ctl`, `.tts.seek` | pause state and pending seek |
| `queue/`, `.tts.drain.pid` | lines waiting to be spoken, and who is speaking them |
| `speak-mute/` | which windows have asked for quiet |
| `.spoken-agents/` | which subagent completions have been announced already |
| `errors.log` | failures the script swallowed rather than break your turn |

## Porting

The plugin is deliberately split so this is tractable. Everything agent-facing —
hooks, commands, the cue protocol — talks to `bin/agent-speak.js` and never to
PowerShell. A cross-platform engine is a change behind that seam.

What's Windows-bound: MCI playback (`winmm.dll`), the `WH_KEYBOARD_LL` media-key
hook, and the SAPI5 fallback voice. The ElevenLabs call is already portable. The
media keys are the hard square — macOS needs an Accessibility permission and a
`CGEventTap`, and on Linux it's desktop-dependent.

## Licence

MIT.
