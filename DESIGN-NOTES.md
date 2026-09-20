# Design notes

Why agent-speak is built the way it is. The [README](README.md) covers what it
does and how to install it; this is the reasoning underneath, and the problems
that only showed up once it was running.

## The product decision: a doorbell, not a reading

Most "read my agent's output aloud" tools narrate the **response**. That fails
for a reason that has nothing to do with speech quality: an agent's answer is a
*document*. It has tables, file paths, code blocks and headings, all written to
be scanned with your eyes. Narrated end to end, you get several minutes of
unlistenable prose and no idea whether you need to act.

So this speaks a **handover** instead — one sentence, under fifteen words,
saying what finished and what you do next:

> "Issue 466, notification toast layout. The draft pull request is up and ready
> for review."

The full answer stays on screen, one command away. The agent writes the cue
itself, because only the agent knows which sentence matters.

Everything below follows from that decision.

## Decisions

### The agent writes the cue; the hook speaks it

A `SessionStart` hook injects an instruction telling the session to write one
line to `speak-cues/<session_id>.txt` before finishing a turn. The `Stop` hook
reads that file, speaks it, and **deletes it**.

Deleting is the load-bearing part. Without it, a turn that forgot to write a cue
would replay the *previous* turn's line — confidently announcing work that
already finished. A stale cue is worse than no cue, so a missing one falls back
to a generic "Response ready." That failure is honest; the other is a lie.

### Media keys: a low-level hook, not `RegisterHotKey`

Your keyboard's ⏯ ⏭ ⏮ keys drive playback — but only while speech is actually
playing. Every other moment they belong to Spotify.

`RegisterHotKey` can't do that. It claims a key globally for as long as it's
registered; there's no "handle this one, pass that one through." A
`WH_KEYBOARD_LL` hook can decide **per keystroke** whether to swallow the key or
return it to the system, which is exactly the conditional ownership this needs.

The hook inspects three virtual-key codes and ignores every other key without
reading it. It can only write `play`, `pause` or a number into two files.

### MCI, not `SoundPlayer`

`System.Media.SoundPlayer` can start and stop. That's all — so it cannot support
pause at any price, and `PlaySync()` blocks the process that called it.

MCI (`winmm.dll`) plays **asynchronously** against a named alias and supports
play, pause, resume, seek and status. Asynchronous is the real win: it leaves
the owning process free to watch a control file while audio runs, which is what
makes out-of-band pause possible at all.

### Escaping the host's job object

This one cost real time and is the most interesting bug in the repo.

Launching detached playback from the Node entry point **silently did nothing**.
The process started, printed a success line, and a moment later no process
existed.

Agent hosts run hook commands inside a **job object** that kills every descendant
when the command returns. Node's own `detached: true` does not escape it —
measured both ways, neither survived. PowerShell's `Start-Process` does escape,
because it launches through the shell.

But spawning it and exiting immediately isn't enough either: the launcher gets
torn down before it reaches `Start-Process`, so nothing is ever created. **The
launcher has to be waited on.** It costs about half a second.

There was a second failure hiding behind the first: `Start-Process
-ArgumentList` does no quoting of its own, so an argument containing a space
arrives as *two* arguments and the child dies binding its parameters — a silent
death that looks identical to "the feature is broken."

Both failure modes present as nothing happening. That's what made it expensive,
and why the fix carries its reasoning in a comment.

### The progress bar that made long speech impossible

The most expensive line in the engine is one that isn't there:
`$ProgressPreference = 'SilentlyContinue'`.

Windows PowerShell 5.1 redraws a console progress bar for **every chunk**
`Invoke-WebRequest -OutFile` writes, and the redraw costs far more than the
transfer itself. Measured on one 1500-character request: **44.6s with the bar,
3.1s without it** — the same bytes, fourteen times faster. Nothing was even
rendering it, because speech runs in a hidden window.

The interesting part is the second-order failure. That overhead silently capped
how much could ever be spoken: past roughly 700 characters a request exceeded
the timeout, so a long reply didn't merely lag — it **timed out and fell back to
the robotic offline voice**.

So the symptom was "ElevenLabs is unreliable for long responses." The cause was
a console progress bar nobody could see. Worth remembering whenever a fallback
path starts firing more than it should: a graceful degradation can hide the bug
that triggers it.

### A Node seam, so the Windows parts are replaceable

Everything agent-facing — hooks, slash commands, the cue protocol — talks to
`bin/agent-speak.js` and **never to PowerShell directly**.

That seam isn't decoration. The Windows-bound pieces are MCI playback, the
media-key hook, and the SAPI5 fallback voice; the ElevenLabs call is already
portable. A macOS or Linux engine is a change behind the seam, not a rewrite of
the plugin. It's also why installing on a non-Windows machine is harmless —
every hook exits quietly instead of erroring.

### Config lives outside the plugin directory

`~/.claude/agent-speak/config.json`, not a file in the repo. A plugin update
replaces the plugin directory, and your voice choice has to survive that.

### Failures degrade; they never break the turn

If ElevenLabs is unreachable, out of quota, or slow, playback falls back to the
offline Windows voice and keeps talking. Failures go to `errors.log` rather than
surfacing as a broken hook.

The reasoning: this is a **notification system**. A notifier that takes your
session down when a network call fails is worse than no notifier — and speech
is the one feature whose failure you cannot see on screen.

### Secrets are named, never printed

The API key is read from `ELEVENLABS_API_KEY` and never written to config, never
logged, never echoed. The `diag` command reports that the key was found, its
**length**, and whether it's valid — not its value.

This matters more than it looks: diagnostics output is what people paste into
issues and screen-record for demos.

## What I'd change next

- **Media keys don't work on every keyboard.** Some send HID consumer-control
  usages that become `WM_APPCOMMAND` and never reach a keyboard hook. `hotkeys
  trace` logs nothing when you press them, which is at least diagnosable, but
  the real fix is a second capture path.
- **The half-second launcher wait** is a tax on every playback start. It buys
  correctness against the job object, but a proper detach primitive would be
  better.
- **No tests around the PowerShell layer.** The Node seam is testable; the
  engine behind it is verified by hand.
