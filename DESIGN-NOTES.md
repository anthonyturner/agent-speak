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

### Narration is authored, because thinking cannot be read

The obvious way to speak an agent's reasoning is to read its thinking aloud. It
is not possible, and the reason is worth writing down so nobody tries again.

Extended thinking is not persisted. It appears in the transcript as a block, but
the block is `{type, thinking: "", signature}` — across the eight most recent
transcripts of one project, all **407** of them carried no text at all. The
terminal renders thinking from the live stream and keeps none of it, so there is
nothing on disk for a hook to read.

Nor would it be worth reading. Raw reasoning is a working note: it backtracks, it
lists options it discards, it is written to nobody. Narrated end to end it is the
same failure as narrating the response, which is the thing this plugin exists to
avoid.

So narration follows the cue's contract instead — **the agent writes the line,
the hook speaks it** — moved from the end of the turn to the middle of it. The
`SessionStart` brief authorises it at decision points and steers hard away from a
running commentary, because the failure mode here is not silence, it is a voice
that will not stop.

### A subagent is identified by its `Agent` call, not by its own transcript

`SubagentStop` says that *a* subagent finished. It does not say which, and the
subagent's own conversation is not persisted either: 195 `Agent` tool_use blocks
across this machine's transcripts, and not one entry flagged `isSidechain`.

What *is* on disk, in the parent's transcript, is the call that started it —
carrying `subagent_type` and a `description` already written for a human to read.
That is the announcement, and it costs nothing to produce.

Matching the right call is the part that needed thought, because a fan-out does
not finish in spawn order. The finished agent is taken to be the oldest
un-announced call whose `tool_result` has landed; announced ids are kept per
session so nothing is said twice. When no result has landed yet, the oldest
un-announced call is a better guess than saying nothing — being a beat early
about which of your own agents returned is a small error, and silence is not.

### Narration queues; the cue still interrupts

`Invoke-Speech` stops whatever is playing before it starts. That is right for one
line at the end of a turn: the newest handover is the only one worth hearing.

It is wrong for narration, which arrives in bursts — a decision, another, then
three subagents reporting in. Interrupting would mean hearing the first syllable
of each and the whole of none. So narration goes through a queue drained by one
process at a time, holding a lock file taken with `CreateNew` because that is
atomic and two simultaneous lines must not both decide they are the drainer.

Three details are load-bearing:

- **The drainer re-checks after releasing the lock.** A line queued in the moment
  between "queue is empty" and "lock released" is one nobody is coming back for:
  its own process already tried for the lock, failed and exited. Without the
  re-check that line waits for an unrelated future line to wake it.
- **A stale lock is never trusted.** The end-of-turn cue kills whatever is
  speaking — by design — and if that is the drainer, the lock outlives it. Left
  alone, narration would go silent from then on and stay silent.
- **The queue is trimmed from the front.** A backlog means the listener is
  already behind, and what they want is the thought that just happened.

The cue keeps interrupting, and that is the point rather than an oversight: when
the turn ends, narration still in flight is stale, and clearing the decks for the
handover is the right call.

### Mute is per session, and speaking is the default

The unit is the session, because that is what a person means by "be quiet" — this
window, not the four others that are working fine. It needed no new machinery:
the session id is the transcript's file name, which is already how labels and cues
are keyed, so a mute is a marker file named after it.

Speaking is the default rather than opt-in. Opt-in never surprises you, but it
fails the other way: a window you forgot to unmute is a window that finished an
hour ago and never said so, and there is nothing to notice. A doorbell that
sometimes does not ring is worse than one that occasionally rings when you would
rather it did not.

Two boundaries make it behave:

- **Mute does not cover `/speak` or `/play`.** Those are someone asking out loud
  to hear something. A flag set an hour ago in another context should not overrule
  the sentence they just typed.
- **A muted window still consumes its cue file.** Skipping the read instead would
  bank them, and unmuting would empty an hour of stale handovers over the user —
  the same failure the cue delete already exists to prevent, arriving later and
  in bulk.

### Cues queue, because windows were cutting each other off

`Invoke-Speech` kills whatever is playing, regardless of which session queued it.
With one window that is invisible. With four it means the window you are not
looking at ends a turn and cuts off the sentence you were listening to, and no
setting changes it, because it is not a setting.

So cues go through the narration queue too, and queue entries carry the session
that wrote them. A cue clears **its own** session's pending lines and then queues:
within a window the handover still supersedes everything that window was in the
middle of saying, which is what the cue is for, while another window's pending
line is left alone because it is still its present tense.

Notifications are the deliberate exception and still interrupt. A window raising
one is blocked waiting for its user; making it queue behind another window's
sentence is the one case where waiting your turn is the wrong behaviour.

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
