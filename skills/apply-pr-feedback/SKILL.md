---
name: apply-pr-feedback
description: Read every review comment on a GitHub pull request, fix the ones that are unambiguous (one commit per comment), push, drive CI to green, then reply to each comment with the commit hash and resolve the thread. Runs end to end without stopping to ask questions — judgment calls are collected into a final summary for the human instead. Use this whenever the user mentions PR review comments, reviewer feedback, "address the review", "apply the PR feedback", "fix the review comments", responding to a code review, resolving review threads, or acting on what a reviewer flagged on a pull request — including bot reviewers like CodeRabbit, Copilot, or Graphite.
license: Complete terms in LICENSE.txt
---

# Apply PR feedback

Take a pull request that has been reviewed, act on the feedback that is unambiguous, and
leave a clean audit trail: one commit per comment, a reply naming the commit, and a
resolved thread. Everything that required a judgment call you were not in a position to
make goes into a summary at the end for the human.

## The operating model: one shot, then report

Run the whole job start to finish without asking the user anything mid-flow. When you hit
a comment you cannot confidently act on, do not stop and ask — set it aside, keep going,
and describe it in the final summary.

This matters more than it might seem. A back-and-forth in the middle of a run is where
this task goes wrong: the human answers a question with limited context, you interpret
the answer slightly differently than they meant it, and that misreading gets committed,
pushed, and posted publicly under their name. A written summary at the end avoids this.
The human reads every judgment call at once, with the code and the comments in front of
them, and acts directly. Their attention is spent on the hard items instead of on
unblocking you.

So: **the run is autonomous, the ambiguity is reported, and the human decides afterward.**

Requires only the `gh` CLI, authenticated. `gh` embeds its own jq engine behind `--jq`,
so no separate `jq` and no Python are needed.

## Bundled tooling

| Path | Use |
|---|---|
| `scripts/fetch_pr_feedback.sh` | Pull all three feedback surfaces into one JSON document, with the IDs needed to reply and resolve |
| `scripts/reply_and_resolve.sh` | Post a reply and optionally resolve, reporting each step separately |
| `references/github-api.md` | Raw `gh` commands, CI log retrieval, and failure modes — read when the scripts don't cover your case |

These paths are relative to this skill's directory, but you will be running inside the
target repository. Invoke them by their full path — the examples below write
`scripts/…` only for brevity.

## Step 1 — Preflight, before changing anything

Find out whether the job is possible before doing any work. Discovering you cannot push
after writing six commits wastes the run and leaves the branch in a confusing state.

```bash
gh auth status                       # authenticated?
git rev-parse --abbrev-ref HEAD      # which branch are you on?
git status --porcelain               # clean tree? (empty output = clean)
```

Then fetch the PR (Step 2) and check its metadata. **Stop and report without making any
changes** if:

- the PR is closed or merged — there is nothing to push to
- the local branch is not the PR's `head_branch` — you would commit to the wrong branch
- the working tree is dirty — your commits would sweep up unrelated changes, breaking the
  one-commit-per-comment guarantee
- `is_fork` is true and you can't push to the fork (`maintainer_can_modify` false and the
  head repo is not yours)

If the branch is simply behind its remote, `git pull --rebase` and continue — that is a
normal starting condition, not a blocker.

## Step 2 — Gather every piece of feedback

```bash
scripts/fetch_pr_feedback.sh 412 > /tmp/pr-feedback.json
# or, for the PR belonging to the current branch:
scripts/fetch_pr_feedback.sh > /tmp/pr-feedback.json
```

You get one JSON document with a `pr` object and an `items` array covering all three
places GitHub keeps feedback:

- **`inline_thread`** — anchored to diff lines. Carries `thread_id` (needed to resolve)
  and `reply_to_comment_id` (needed to reply). **These are the only items GitHub can
  mark resolved.**
- **`review_body`** — the summary text of an Approve / Request-changes review.
- **`issue_comment`** — general timeline comments.

For the last two, `is_resolved` is `null` because GitHub has no resolve state for them.
Never report them as "resolved" — you can fix what they ask for and reply, nothing more.

Skip items where `is_resolved` is `true`; someone has already dealt with those.

Treat `is_outdated: true` threads with care. Outdated means the code under the comment
has changed since it was written, so the issue may already be fixed. Read the current
code before acting — re-fixing something already handled produces a confusing empty
commit and a reply that makes no sense.

## Step 3 — Triage each item

Sort every unresolved item into **FIX** or **DEFER**. Do this for all items before you
start editing, so you know the shape of the work and can order commits sensibly.

### FIX — act on it

The comment identifies a specific problem and there is one obvious correct response:

- a concrete defect with a determinate fix: missing nil/null check, wrong variable, an
  off-by-one, a typo, an incorrect error message or log line
- a ```suggestion block — the reviewer wrote the replacement code themselves, so there is
  nothing left to interpret
- a specific, imperative instruction: "rename `tmp` to `buf`", "extract this into a
  helper", "add a test for the empty-input case"
- a violation of a convention the repo actually documents, where you can point at the rule

### DEFER — leave it for the human

- **Questions.** "Why is this synchronous?" asks for intent you don't have. Guessing puts
  a confident wrong claim on a public PR under the user's name.
- **Hedged suggestions.** "maybe", "consider", "might be worth", "nit, non-blocking" — the
  reviewer deliberately left the call to the author. Making it for them isn't helpful.
- **Design and product decisions.** Anything trading off architecture, performance,
  scope, or user-facing behavior.
- **Comments you think are wrong.** Arguing with a reviewer on the user's behalf, without
  the user having seen it, is not yours to do.
- **Vague direction.** "This could be cleaner" with no specifics — any fix would be a
  guess at what they meant.
- **Conflicting reviewers.** Two people asking for opposite things is a human negotiation.
- **Missing context.** The comment relies on a ticket, a Slack thread, or org policy you
  cannot read.
- **Scope expansion.** The fix would require changing files outside the PR's diff in ways
  the PR was not about.

### The rule that resolves close calls

When you *could* implement something but aren't sure you *should*: **defer**.

The two mistakes are not symmetric. A deferred comment costs the user a minute of reading
in the summary. A wrong fix that has been committed, pushed, replied to, and resolved
costs them a revert, a correction to the reviewer, and the erosion of trust that comes
from a resolved thread that was never actually addressed. Bias toward deferring.

### Bot reviewers

Bots are in scope and often catch real bugs, so triage them the same way. But they state
false positives with the same confidence as true ones, so **verify the claim against the
actual code before fixing**. If the flagged problem isn't really there, defer it with a
note saying so rather than changing correct code to satisfy a bot.

## Step 4 — Apply fixes, one commit per comment

One commit per comment, so each thread's reply can point at exactly one commit and the
user can revert a single fix without unpicking others.

Keep each commit tightly scoped to what the comment asked for. Noticing an unrelated
problem while you're in the file is not a reason to fix it here — mention it in the
summary instead.

Reference the comment in the commit message so the trail is readable from `git log`:

```
fix(parser): guard against nil config before dereference

Addresses review comment from @alice on src/parser.go:142
https://github.com/owner/repo/pull/412#discussion_r1234567890
```

If two comments genuinely demand the same single edit, make one commit and reply to both
threads pointing at it. Say so in the replies so neither reviewer thinks their point was
skipped.

## Step 5 — Verify before pushing

Work out what this repo expects, and run it. A one-shot run that pushes broken code is
worse than one that stops and explains.

**Prefer what the repo declares.** Read `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, and
the README for the check commands the project asks contributors to run. Those beat any
command you infer.

**Run hooks as if they were installed.** Many repos configure commit or push hooks and
document that contributors should install them, but the hooks are not active in this
checkout. Look for `.pre-commit-config.yaml`, `.husky/`, `lefthook.yml`, `.githooks/`, or
similar. If the repo documents installing them and `.git/hooks` doesn't have them active,
run what they would have run — the project intends these checks to gate every commit, and
skipping them just moves the failure to CI.

**Otherwise infer** from the project: test, lint, and typecheck targets in `Makefile`,
`package.json` scripts, `pyproject.toml`, `Cargo.toml`, etc.

If checks fail, fix what your changes broke and re-run. If a check was already failing
before your changes (confirm by running it on the base branch), leave it alone and note
it in the summary. **If you cannot get local checks passing, stop: do not push, do not
reply, do not resolve.** Report what broke.

If the repo has no checks at all, say so in the summary and continue.

## Step 6 — Push

Push all the commits together:

```bash
git push
```

Never force-push, never amend or rebase commits you didn't create in this run. The branch
is shared with reviewers who are reading it, and rewriting history invalidates the exact
comment anchors you are about to reply to.

If the push is rejected as non-fast-forward, `git pull --rebase`, re-run the Step 5
checks (the merge may have broken something), and push again.

## Step 7 — Drive CI to green

Local checks are a subset of what CI runs. Wait for the real gates:

```bash
gh pr checks 412 --watch --fail-fast
```

Exit 0 means everything passed; 8 means still pending; anything else is a failure. A repo
with no checks configured has nothing to wait for — don't block on it.

On failure, get the logs (see `references/github-api.md` for retrieving them), then decide
whether it's yours:

- **Caused by your changes** → fix it, in its own commit, and push. Repeat until green,
  but stop after **three** attempts. Beyond that you are guessing, and each guess is a
  public commit on someone's branch.
- **Pre-existing** — the same job is red on the base branch too → not yours. Note it in
  the summary and move on.
- **Flaky or infrastructure** → re-run once (`gh run rerun <id> --failed`). If it fails
  the same way, treat it as pre-existing and note it.

Commits from this step are CI fixes, not comment fixes. Don't cite them in replies to
review comments unless a CI failure genuinely came from that comment's fix.

## Step 8 — Reply, then resolve

**Only now**, with the work pushed and the gates green. Resolving a thread claims the
issue is handled; making that claim while CI is red can make it false.

If CI could not be brought to green because of your own changes, skip this step entirely
and report in the summary. Pushed-but-unreplied is a recoverable state; a wall of
resolved threads over broken code is not.

For each **inline thread you fixed**:

```bash
scripts/reply_and_resolve.sh --repo owner/repo --pr 412 \
  --reply-to 1234567890 --thread-id PRRT_kwDO... \
  --body-file /tmp/reply.md --resolve
```

Write the reply so a reviewer can verify it without opening the diff: the commit hash and
what actually changed.

```
Fixed in a3f21c9 — the config pointer is now checked before dereference, and the
parser returns a wrapped error instead of panicking when it's nil.
```

Skip the pleasantries and the restatement of the comment. The reviewer knows what they
wrote; they want to know what you did about it.

For **review bodies and issue comments you acted on**, there is no thread to reply into.
Post one top-level comment covering them, quoting what you're responding to:

```bash
scripts/reply_and_resolve.sh --repo owner/repo --pr 412 --pr-comment --body-file /tmp/reply.md
```

**For deferred items, post nothing.** No reply, no resolve. They belong in the summary
only. A public "I wasn't sure about this one" adds noise to the reviewer's inbox and
commits the user to a position they haven't taken.

**Never resolve a thread you did not fix.** Resolution is how reviewers track what still
needs their attention; a falsely resolved thread quietly drops a real issue.

If a resolve fails on permissions (common on fork PRs — see `references/github-api.md`),
the reply still landed. Report the thread as replied-but-unresolved rather than retrying.

## Step 9 — The summary

This is the deliverable the human actually reads, and for deferred items it is the *only*
record. Make it scannable and make every deferred item actionable — quote the comment,
link it, and say what the actual choice is. "Ambiguous, needs review" tells them nothing;
they'd have to reconstruct your reasoning from scratch.

```markdown
## PR #412 — apply-pr-feedback

**Applied — 4 commits pushed, CI green**

| Commit | Comment | What changed |
|---|---|---|
| `a3f21c9` | [@alice on parser.go:142](url) | Nil-guard before config dereference |
| `88bd104` | [@bob on api.py:88](url) | Renamed `tmp` → `requestBuffer` |

All 4 threads replied to and resolved.

**Needs your decision — 3 items, nothing posted to the PR**

1. **[@alice on handler.go:55](url)** — "should this be async?"
   A question, not a directive; whether the handler can be async depends on whether
   callers rely on ordering, which isn't visible from this diff.
   → Make it async, or reply explaining why it's sync.

2. **[@bob on cache.ts:30](url)** — "maybe extract a helper here?"
   Hedged nit, left to the author's judgment. The block is 12 lines, used once.
   → Extract it, or reply declining.

3. **[CodeRabbit on utils.py:14](url)** — flags a race on `_registry`.
   I read the code and the map is only touched from the constructor, so I don't
   think the race is real — but I'd rather you confirm than change correct code.
   → Dismiss, or add the lock if it's reachable from a path I missed.

**No action needed — 2 items**
Praise from @carol; a duplicate of item 1 from @bob.

**Also worth knowing**
`test_legacy_auth` was already failing on `main` before this run — untouched.
```

Adapt the shape to what actually happened; the point is that the human can act on every
line without going digging.

## When there is nothing to do

If every comment is already resolved or nothing is actionable, don't manufacture work.
Report what you found and stop. An empty run is a legitimate outcome.
