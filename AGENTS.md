# Agent Instructions — agent-speak

A Claude Code plugin for Windows that speaks a one-line cue when the agent finishes a turn, and reads the full response aloud on request.

This file is a **router**, not a manual. It holds only what applies to every
request. Everything else lives in `/docs` and is indexed below — open the file
that matches the work before starting it.

## Commands

| Command | What it does |
| --- | --- |
| `none yet` | Installs dependencies from the lockfile. |
| `none yet` | Builds the project. Run it before calling any change finished. |
| `node bin/agent-speak.js doctor` | Runs the tests. |
| `none yet` | Runs the linters. |

The default branch is `main`. Infer the layout from the
repository tree, which cannot drift out of date the way a list in this file can.

## Hard stops

These hold even if you read nothing else:

- **Never commit to `main`**, never force-push, never rewrite
  history, never delete a branch.
- **Never merge without a posted review.** Merge only after the review in
  [qa-review.md](docs/agent-workflows/qa-review.md) is on the pull request and
  its blocking findings are fixed. Never bypass branch protection.
- **Never close or delete a GitHub issue or comment.**
- **Never commit or print a real secret.** Name credentials; never values.
- **Never start a grilling session on your own initiative** — it is opt-in, by
  name only.

The complete list, which other documents cite by number, is
[docs/rules.md](docs/rules.md). Read it before generating code.

## Autonomy

Work runs from request to **merged pull request without stopping for
approval**: file the issue, branch, open the PR, implement, verify, push, post
a code review on the PR, fix what it finds, then merge with a merge commit.
Filing and updating issues, commenting, branching, committing, pushing, opening
pull requests and merging a reviewed one are all pre-authorized.

Routine judgement calls are yours to make. Pick the sensible option, state the
assumption in one line, and carry on to a finished change. Stop and ask only
when proceeding would be unsafe or irreversible, when a hard stop above is in
the way, or when a wrong guess would make the whole change useless. The
authorization and its limits are in
[docs/agent-workflows/pipeline.md](docs/agent-workflows/pipeline.md).

## Read before you work

| Before you… | Read |
| --- | --- |
| write any response, issue, PR body or comment | [response-style.md](docs/response-style.md) |
| generate any code | [rules.md](docs/rules.md) |
| write or cut a code comment | [comments.md](docs/comments.md) |
| write TypeScript or touch dependencies | [stack/typescript.md](docs/stack/typescript.md) |
| take on substantial, ambiguous or user-facing work | [agent-workflows/pipeline.md](docs/agent-workflows/pipeline.md) |
| scope a request into a filed issue | [agent-workflows/planning.md](docs/agent-workflows/planning.md) |
| create or update a work item | [agent-workflows/tracking.md](docs/agent-workflows/tracking.md) |
| implement a filed issue | [agent-workflows/implementation.md](docs/agent-workflows/implementation.md) |
| review a pull request | [agent-workflows/qa-review.md](docs/agent-workflows/qa-review.md) |
| run a grilling session — only when asked for by name | [agent-workflows/grilling.md](docs/agent-workflows/grilling.md) |
| add, rename or thin an agent skill | [agent-workflows/skills.md](docs/agent-workflows/skills.md) |
| record a decision that constrains future work | [decisions/README.md](docs/decisions/README.md) |
| check what the project is built on | [tech-stack.md](docs/tech-stack.md) |

When guidance conflicts: this file, then [docs/rules.md](docs/rules.md), then
the files under `docs/stack/` where they exist, then the rest of `/docs`, then
any tool-specific instruction file.

## Keep this file lean

A section that applies to only one kind of task does not belong here — it
belongs in `/docs` with a row in the table above, or in a skill. This file is
sent to the model on every request, so every line it carries is a line paid for
by requests that had nothing to do with it.
