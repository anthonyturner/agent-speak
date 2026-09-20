---
description: List the voices on your ElevenLabs account, hear one, or make one the default
argument-hint: "[name or id] | preview <name> | list — omit to list"
allowed-tools: Bash(node:*)
---

Choose which ElevenLabs voice the plugin speaks in. Side-effect only: run the
command, report what it printed in a line or two, and nothing else. No summary,
no commentary on the voices themselves. The one exception is the closing line
the list is required to carry, below.

Arguments: $ARGUMENTS

The entry point is the same for all three steps:

```
node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" voice <list|preview|set> [name or id]
```

| Said | Run | Then reply |
| --- | --- | --- |
| nothing, `list`, `what voices`, `which voices` | `voice list` | the list, as a table |
| `preview X`, `try X`, `what does X sound like` | `voice preview X` | `Previewing X.` |
| `X`, `set X`, `use X`, `switch to X` | `voice set X` | the script's confirmation line |

A bare argument is a **set**, not a preview — "use Spuds Oxley" and "Spuds
Oxley" both mean change it. Only the words in the preview row above mean sample
it without changing anything.

## Reporting the list

`voice list` prints one row per voice: a `*` marking the one in use, then name,
category and id. Render it as a markdown table with the name, category and id
columns, and say which one is current. Keep the ids — they are how a voice with
an awkward name gets selected.

If the user then names a row by its number, resolve that number to the voice
**name** yourself and run `voice set <name>`. The script has no concept of row
numbers; they exist only in what you rendered.

### Always close the list with how to act on it

A table of 26 names and opaque ids is unusable if the reader has to go and find
out how to pick one. End every list with exactly these two lines, and put a real
name from the table just printed into each — never a `<placeholder>`:

```
/agent-speak:voice preview Harry     hear it first
/agent-speak:voice Harry             make it the default
```

Use a voice that is **not** the current one, so the example does something if
run. This closing block is the only addition the "nothing else" rule above
permits: no other next steps, and no suggestions about which voice to choose.

## When more than one voice matches

The script refuses to guess and prints the candidates instead. Show them and ask
which one — do not pick for the user, and do not retry with a longer guess. A
wrong guess here is heard rather than read, so it is worse than a question.

## What it costs

`list` and `set` are free. **`preview` synthesises a sample line and is billed**,
so preview when asked to, not as a flourish before setting — and never preview
several voices in a row unless that is what was asked for.

## Where the choice is stored

`voice set` writes `ElevenVoiceId` into `~/.claude/agent-speak/config.json`,
reading and rewriting that file so the user's other settings survive. It lives
outside the plugin, so a plugin update cannot overwrite it.

`node "${CLAUDE_PLUGIN_ROOT}/bin/agent-speak.js" diag` reports the active voice
along with the rest of the engine configuration. It speaks nothing and never
prints the key.
