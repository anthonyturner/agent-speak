# Non-negotiable rules

These are the rules that do not bend for convenience. Read them before
generating code or touching the repository's history.

**The numbering is stable.** Other documents cite these as "rule 7", "rule 12"
and so on. If a rule is retired, leave its number in place with a note rather
than renumbering the ones below it. A new rule takes the next free number.

**A pointer binds as hard as the text it points at.** Rules 2, 9, 11 and 15
state what they require and then point at the document that treats it fully, so
there is one copy to keep correct instead of two. The rule is the requirement;
the pointer is where the detail and the reasoning live. Following it is not
optional.

1. Read every relevant `/docs` instruction file before generating code.
2. Carry work through to a **merged** pull request without pausing for
   approval, per **How far an agent goes** in
   [agent-workflows/pipeline.md](agent-workflows/pipeline.md): file the issue,
   branch, commit, push, open the PR, post a code review on it, fix the real
   findings, then merge with a merge commit. Never merge a pull request that
   has no posted review, that still has a blocking finding, or whose checks
   fail.
3. Never force-push, rewrite history, delete branches, bypass branch
   protection, or commit directly to `main`. Merging goes
   through the pull request and nowhere else.
4. Never commit or print real secrets. Reference credentials by name only.
5. Preserve unrelated working-tree changes; stop if they block safe isolation.
6. Do not add or upgrade dependencies without discussing it first.
7. Do not reformat or change files unrelated to the task.
8. Run `none yet`, plus `none yet` and `node bin/agent-speak.js doctor`
   where the change touches what they cover, before considering a change
   complete. Report a failing check as a failure; never skip it silently. State
   explicitly when manual validation in the running app is still required.
9. Apply SOLID principles where they solve a real problem; do not force
   abstractions onto trivial code. The shape of the SOLID note a change
   report carries lives with the stage that writes it — see step 7 of
   **Implement and verify** in
   [agent-workflows/implementation.md](agent-workflows/implementation.md).
10. Before adding a module, service or component, check whether an existing one
    already owns that responsibility and extend or reuse it instead of
    duplicating logic. Never write a second implementation of behavior that
    already exists elsewhere in the codebase.
11. Track work in GitHub, and only in GitHub. A GitHub issue is the work item
    and its pull request is the change. Follow
    [agent-workflows/tracking.md](agent-workflows/tracking.md) for identity,
    branch naming, labels, hierarchy, and estimation. Never write to another
    tracker, and never re-introduce one without an ADR superseding
    [ADR-0002](decisions/0002-track-work-in-github-only.md).
12. Never close a GitHub issue by hand, and never delete an issue or a
    comment. Completion follows a merge of a reviewed pull request, and the
    merge closes the issue through `Closes #n`.
13. Never start a **grilling session** on your own initiative. Grilling is a
    relentless round-based interview that stress-tests a request before it is
    written down, defined in
    [agent-workflows/grilling.md](agent-workflows/grilling.md). It is
    opt-in: run it only when the requester asks for it by name — the
    `grill-me` skill, see [agent-workflows/skills.md](agent-workflows/skills.md)
    — and never as a self-imposed gate on filing an issue.
14. Decide rather than ask. The requester reads finished work on the merged
    pull request, not mid-task, so a routine judgement call is yours to make:
    pick the sensible option, state the assumption in one line in the response
    or the pull-request body, and carry on to a finished change. Do the parts
    that do not depend on an open question first. Stop and ask only when
    proceeding would be unsafe or irreversible, when the action is one of the
    ones forbidden by rules 3, 12 and 13 above, or when a wrong guess would
    make the whole change useless. An open question that a wrong answer would
    make expensive to revert is a reason to leave the pull request unmerged and
    say so, not a reason to guess and merge.
15. Write a comment only for a fact the code cannot show on its own — an
    outside constraint, a deliberately non-obvious choice, a safety margin and
    what it guards. Do not restate the code, and do not narrate the file's
    history; git and the pull request already hold that. See
    [comments.md](comments.md) for where cut content goes instead and which
    half of this a reviewer enforces rather than a linter.

## Stack rules

The rules above hold for every project. Rules that depend on the language or
framework live beside them and bind just as hard.

- TypeScript and npm: [stack/typescript.md](stack/typescript.md).

A project with no stack file has no stack rules yet. Add one under
`docs/stack/` when a constraint recurs, and link it here.
