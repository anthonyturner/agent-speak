---
description: Read the last full response aloud
allowed-tools: Bash(node:*)
---

Play the previous response aloud, in full.

This is the counterpart to the one-line cue spoken at the end of every turn: the
cue says the work is done, this reads the work. Side-effect only - run it, reply
with a single short line, and nothing else.

Run:

```
node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" play <session_id>
```

Pass this session's id if you know it - it is the name of this session's
transcript file under `~/.claude/projects/<project>/`, and the `session_id`
field every hook receives. Without it the script falls back to whichever
transcript was written most recently, which is the wrong session whenever more
than one is open.

Then reply: `Playing.`

Playback is detached, so the turn ends immediately and the user can still pause,
skip or stop it. Do not wait for it to finish.

**These bare phrases are this command**, with or without the slash: "play the
full response", "play it back", "read that out", "replay", "say it again". Run
it rather than discussing it.

Two things this deliberately skips:

- **Short acknowledgements.** Replies like "Playing." land in the transcript as
  the newest assistant message, so a second replay would read the
  acknowledgement back instead of the answer. Anything under 400 characters is
  skipped in favour of the last real answer, unless every candidate is short.
- **Code blocks, paths and URLs.** They are unlistenable read character by
  character, and are stripped before speaking.
