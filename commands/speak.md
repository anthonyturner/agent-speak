---
description: Speak the text you pass in, aloud
argument-hint: "[text to speak]"
allowed-tools: Bash(node:*), Write
---

Speak a specific piece of text aloud. To replay the previous response instead,
use `/agent-speak:play`.

Side-effect only: run it, reply with a single short line, nothing else.

Arguments: $ARGUMENTS

Write the argument text **exactly as the user typed it** to `speak-text.txt` in
your scratchpad directory, then run:

```
node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" speak "<that file>" "<session label>"
```

Then reply: `Speaking.`

Route the text through a file rather than the command line so quotes,
apostrophes and newlines survive intact.

Never reword, shorten, expand or comment on the text you were asked to speak.
The session label is the one addition, and the script prepends it rather than
editing the text - so do not paste the label into the text as well, or it is
said twice.

## Narrating mid-turn

This command speaks *now*, interrupting whatever is playing. To say something
while you are still working — a decision worth overhearing — use `say` instead,
which queues behind anything already waiting:

```
node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" say "the line" --session <session_id>
```

One sentence on the decision and why it went that way. Not a running commentary:
a few in a long turn, none in a short one.

## The cue, which matters more than this command

Most of what this plugin says is not `/speak`. At the end of every turn the user
hears one short line saying the work is done. **You write that line**, before you
finish the turn, to:

```
~/.claude/agent-speak/speak-cues/<session_id>.txt
```

One sentence, under about fifteen words, for the ear: what is done and what the
user does next. No paths, URLs, code or markdown. Do not summarise the response -
the cue is a doorbell, not an abstract, and the full response is one command
away. A turn with no cue is announced with a generic `Response ready.`

Write a session label once, to
`~/.claude/agent-speak/speak-labels/<session_id>.txt`, naming what this session
is about - an issue number and title, or the repository and task. It is spoken
before the cue so the user can tell which window is talking. Rewrite it when the
session moves on.

`<session_id>` is the name of this session's transcript file under
`~/.claude/projects/<project>/`.

## Checking the setup

`node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" diag` prints which engine is
active, whether the ElevenLabs key and voice id are configured, and how much
quota is left. It speaks nothing and never prints the key.
