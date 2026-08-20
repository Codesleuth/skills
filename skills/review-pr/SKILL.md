---
name: review-pr
description: Review the changes a GitHub pull request makes, reading the surrounding code as the context needed to judge them, then publish the review to GitHub as inline comments on the diff plus a summary that approves, comments, or requests changes. Runs start to finish without stopping to ask questions. Use this whenever the user says "review this PR", "review pull request 412", "do a code review on PR #123", "check this PR for bugs and style", "look over these changes and leave feedback", "post a GitHub review", or asks for a second opinion on someone's pull request before it merges — including when all they give you is a PR number or a GitHub URL.
license: Complete terms in LICENSE.txt
---

# Review a pull request

Review the changes a pull request makes, then publish one review: inline comments on the
lines that need them, and a summary carrying the verdict.

**The diff is what you are reviewing.** Every finding is about a line this PR changed, and
that is where it gets commented. Read the surrounding code — as much of it as the change
demands — but read it to judge those lines correctly, not to go looking for problems of
its own. A defect in code the PR does not touch is not this review's business; if it is
genuinely blocking, one line in the summary names it and that is all.

The value is not in restating the diff — GitHub already shows the author what they
changed. It is in catching what the hunk alone cannot show: that the caller two files
away passes nil into the signature they just changed, that the convention every sibling
module follows is broken here, that the test no longer covers what its name claims. Those
are all findings about the changed lines. The rest of the codebase is how you find them,
not what you are reviewing.

## The operating model: read everything, post once

Run start to finish without asking the user anything mid-flow. Questions belong on the
PR, addressed to the author, where they become part of the review.

**One review, one request.** Every comment goes up in a single submission via
`scripts/post_pr_review.sh`. Posting comments one at a time sends the author a
notification each time, and a run that stops halfway leaves a partial review on their PR
with no verdict.

**The review is published under the user's account.** A maintainer reading it will assume
a human wrote it. That sets the bar: every inline comment should be something they would
act on, and every claim should be one you checked against the code rather than inferred
from the shape of the diff. A wrong comment stated confidently costs the author time and
costs the user credibility, and unlike a local edit it cannot be quietly undone.

Requires the `gh` CLI, authenticated, and `git`. `gh` embeds its own jq engine behind
`--jq`, so no separate `jq` and no Python are needed.

## Bundled tooling

| Path | Use |
|---|---|
| `references/review-angles.md` | The finding catalogue behind Step 4 — each angle in full, language footgun tables, high-risk domains, the sweep list. Read it before hunting |
| `scripts/post_pr_review.sh` | Publish the whole review — inline comments and summary — in one request |
| `references/github-api.md` | Raw `gh` commands, the anchor recipe, and failure modes — read when Step 6 fails or you need something the script doesn't cover |

These paths are relative to this skill's directory, but you will be running inside the
target repository, so invoke them by full path.

## Step 1 — Preflight

Find out whether the review is possible before reading several thousand lines of diff.

```bash
gh auth status                                    # authenticated?
gh repo view --json nameWithOwner --jq .nameWithOwner
gh pr view 412 --json number,state,isDraft,isCrossRepository,headRefName,headRefOid,author,\
baseRefName,title,body,additions,deletions,changedFiles,commits,labels
```

With no PR given, `gh pr view` on its own resolves the PR for the current branch. A URL
or a bare number both work as the argument.

**Stop and report** if the PR is closed or merged — a review posted after the fact reaches
nobody who can act on it. A draft PR is fine to review; say in the summary that it is
still a draft, since the author may not have finished.

**If `gh auth status` fails inside a sandbox, do not conclude the token is broken.** With
outbound network blocked, `gh` reports the failure as `The token in keyring is invalid`,
which is misleading. Re-run with the sandbox disabled before believing it.

**Check you have the code.** Judging a diff well needs the code around it. If the local
checkout is a different repository than the PR's, either clone the right one to a temp
directory (`gh repo clone OWNER/REPO /tmp/review-repo`) or say plainly in the final report
that you read the diff without that context — the review is still worth posting, but it
will miss whatever the hunks alone do not show, and passing it off as more is worse than
admitting the limit.

## Step 2 — Gather the change

```bash
gh pr diff 412 > /tmp/pr.patch    # plain, not --patch: that's per-commit mbox
gh api repos/OWNER/REPO/pulls/412/files --paginate \
  --jq '.[] | "\(.status)\t\(.additions)+/\(.deletions)-\t\(.filename)"'
```

Fetch the head commit so you can read files as the PR leaves them, without touching the
user's working tree:

```bash
git fetch origin pull/412/head:refs/review-pr/412 --force
git show refs/review-pr/412:src/parser.go        # the file as this PR leaves it
git show "origin/$BASE_REF:src/parser.go"        # the same file before the change
```

**Never check out the branch or modify the working tree.** It belongs to the user, it may
have uncommitted work in it, and reading blobs by ref gives you everything a checkout
would. Fetching into `refs/review-pr/*` keeps the branch namespace clean; drop the ref at
the end with `git update-ref -d refs/review-pr/412`.

Read the PR title, description, and commit messages before the code. They tell you what
the author was trying to do, which is what you are judging the code against. A change that
is correct but does something other than what the description claims is itself a finding.

Check whether you have already reviewed this PR:

```bash
gh api repos/OWNER/REPO/pulls/412/reviews --paginate \
  --jq '.[] | "\(.user.login)\t\(.state)\t\(.submitted_at)"'
gh api repos/OWNER/REPO/pulls/412/comments --paginate \
  --jq '.[] | "\(.user.login)\t\(.path):\(.line)\t\(.body[0:80])"'
```

Repeating a point someone already made — including one you made on an earlier run — reads
as not having looked. If a previous review exists, review what changed since it and say
so.

**If the diff is very large**, don't skim it uniformly. Rank the files by risk — auth,
money, migrations, concurrency, anything with `unsafe` or raw SQL in it — and spend your
attention there. Generated files, lockfiles, and vendored directories deserve a glance for
"should this be committed at all", nothing more. Say in the summary which files you read
closely and which you skimmed, so nobody mistakes silence for approval.

## Step 3 — Build the context you will judge the change against

A hunk can be locally correct and still wrong. These reads are how you settle that
question about the changed lines — they are not an invitation to review the code they
lead you through:

- **The whole file**, not the hunk. The nil check may be twenty lines up, or absent.
- **The callers.** `git grep -n "FunctionName" refs/review-pr/412`. A changed signature, a new
  error return, a nil that can now escape — the damage is at the call sites.
- **The project's own rules.** `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, the README,
  linter and formatter configs. A rule the repo states in writing is not a matter of your
  taste, and citing it is what makes the comment land. Note that a `CLAUDE.md` in a
  subdirectory governs that directory and below, not the whole repo.
- **The sibling implementations.** If six handlers do a thing one way and this one is the
  seventh doing it differently, that is worth a comment. If the codebase has a helper for
  exactly this, point at it by path.
- **The tests.** Do the new ones actually exercise the new behaviour, or do they assert
  the mock was called? Does an existing test still cover what its name claims?

Read for orientation here, not for verdicts. The point of this step is that by the time
you start hunting in Step 4 you already know what this code is supposed to do, who depends
on it, and what the project's conventions are — so a wrong line looks wrong to you instead
of merely unfamiliar.

## Step 4 — Hunt

Now look for defects. Read `references/review-angles.md` before you start and keep it
open — it holds each angle in full, the language footgun tables, the high-risk domains,
and the sweep list. This step is the discipline for running them; that file is the
content.

**Run the angles as separate passes over the same diff.** A single linear read finds the
bugs that look like bugs. The ones that ship are the ones that look fine in the hunk: the
guard that quietly disappeared, the caller two files away, the trap that is only a trap in
this language. Each angle is a different question, and it is only a second look if you ask
it independently — carrying "I already checked that function" from one angle into the next
turns the second into an echo of the first.

| # | Angle | The question it asks |
|---|---|---|
| 1 | Line by line, with the enclosing function | What input, state, timing, or platform makes this line wrong? |
| 2 | What the diff removed | What did this deleted line enforce, and where is it re-established? |
| 3 | Across the call graph | Does this break a caller, a callee, or a persisted boundary? |
| 4 | Language footguns | Does the diff introduce one of this language's classic traps? |
| 5 | Wrappers, proxies, delegation | Does every method route to the wrapped instance, and does the wrapper forward everything callers use? |
| 6 | State, concurrency, failure paths | What is left behind under retry, partial failure, or two of these at once? |
| 7 | Tests as evidence | Would this test still pass if the implementation were gutted? |

Angle 2 is the highest-yield and the one reviewers skip most often: additions announce
themselves, and a guard that is simply gone announces nothing.

Then the quality angles — reuse, simplification, efficiency, altitude — and the conventions
the repo writes down. Both are in the reference. They earn a non-blocking comment when the
better alternative is concrete and nameable, and silence when it isn't.

Rank what you find: correctness first, then security, then the quality angles. A crash and
a naming quibble are not the same finding, and a review that presents them at equal weight
has not done the ranking the author needs.

**Collect candidates; do not judge them yet.** An angle's job is to produce candidates,
not verdicts. Filtering while you hunt is what makes a review shallow — the
plausible-but-uncertain finding is the first thing self-censorship throws away, and it is
often the one that turns out to be real. Record each candidate with:

| Field | What it holds |
|---|---|
| `file` / `line` | Where the comment will anchor — a line this PR changed |
| `summary` | One sentence: what is wrong |
| `failure scenario` | Concrete inputs or state → the wrong output, crash, or cost |
| `evidence` | The line, or the other file's line, that proves it |

The failure scenario is the load-bearing one. "This might not handle nulls" is a worry;
"`Load` returns `nil, nil` when the config file is absent, so line 42 dereferences nil and
panics on first boot" is a finding. If you cannot write the concrete version, you have not
finished thinking — either finish, or let it go.

Budget around eight candidates per angle and stop there. Past that you are padding, and
padding is what buries the real findings.

**Finish with the sweep list.** One more pass as a fresh reviewer holding the candidate
list, looking only for what is *not* on it: moved code that dropped a guard, a default
that flipped, a constant changed in one of the two places it lives. The reference has the
full list. If nothing new surfaces, return nothing.

Two rules decide whether a candidate survives into Step 5:

**Verify before you write.** If you cannot point at the line that proves the problem, you
do not have a finding — you have a guess, and it belongs in the summary as a question or
not at all.

**Check that the line is one this PR changed.** If the proof lands on code the diff never
touches, what you have found is a pre-existing problem: worth at most a sentence in the
summary, never an inline comment, and not a reason to withhold approval of the change in
front of you.

## Step 5 — Decide what to say, and what verdict to give

Take the candidate list from Step 4 in one deliberate pass, with all of it in front of you.
Merge only the genuinely identical findings — same defect, same location, same reason. Two
angles flagging one line for different reasons is two findings, and the overlap is a signal
that the line deserves attention rather than a duplicate to collapse.

Then decide, one candidate at a time, whether it earns a comment at all.

### What earns an inline comment

A specific problem, at a specific line, with enough for the author to act without asking
you what you meant. The useful shape is: what is wrong, why it matters here, and what to
do instead.

```
`cfg` is dereferenced on line 42 but only checked for nil on line 51, so the
default path (config file absent — `Load` returns nil, nil) panics. Moving the
check above the dereference covers it.
```

Suggest concrete code where the fix is small and unambiguous; GitHub renders a
`suggestion` block as a one-click apply, which is the fastest possible path from comment
to fix.

### What does not earn one

- **Anything a formatter or linter owns.** Quote style, import order, line length. The
  tooling wins that argument without your help.
- **Restating the diff.** "This adds a new parameter" tells the author nothing.
- **Preference dressed as a defect.** If it works and the codebase has no rule about it,
  either let it go or mark it clearly as optional.
- **The same nit twelve times.** Comment once, and say "same in `foo.go`, `bar.go`, and
  four other places" — a wall of identical comments buries the findings that matter.
- **Speculation.** "This might break under load" without a mechanism is noise the author
  cannot act on.

One genuine note about something done well is worth including when it's true and specific.
Manufactured praise is not.

### The verdict

| Verdict | When |
|---|---|
| `REQUEST_CHANGES` | Something is materially broken: a defect that reaches production, a security hole, a silent behaviour change for existing callers, data loss or a migration that cannot roll back. Reserve it for things that must change before merge. |
| `COMMENT` | Findings worth reading but nothing blocking — suggestions, questions, edge cases the author may have already considered, non-blocking cleanups. Also the right choice when you are unsure enough that a maintainer, not you, should make the call. |
| `APPROVE` | You read it, it does what it says, and you found nothing that needs to change. |

`REQUEST_CHANGES` blocks the merge and puts the PR back in the author's court, so spend it
on things that are actually wrong rather than on things you would have done differently.
Equally, don't downgrade a real defect to a polite `COMMENT` — a blocking problem stated
as a mild suggestion gets merged.

**When there is nothing to flag, say so and mean it.** Post an `APPROVE` (or a `COMMENT`
if the PR is yours — GitHub rejects self-approval) whose body names what you checked:
which files you read, what you verified, what you deliberately did not cover. A clean
review that shows its work is useful. Inventing a finding to look thorough is not.

## Step 6 — Publish

Write the inline comments to a JSON file. Each entry needs `path`, `line`, `side`, and
`body`:

```json
[
  {
    "path": "src/parser.go",
    "line": 42,
    "side": "RIGHT",
    "body": "`cfg` is dereferenced here but only nil-checked on line 51, so the\nconfig-absent path panics.\n\n```suggestion\n\tif cfg == nil {\n\t\treturn ErrNoConfig\n\t}\n```"
  },
  {
    "path": "src/store.go",
    "start_line": 88,
    "line": 94,
    "side": "RIGHT",
    "body": "This query runs once per row from the loop above — an N+1 against `users`. `FindAllByIDs` in `store/batch.go` does the same job in one round trip."
  }
]
```

**Anchoring is where this step fails.** GitHub rejects the whole review — every comment,
not just the bad one — if any anchor is not part of the diff. The rules:

- `line` is a line number **in the file on that comment's side**, not an offset into the
  patch.
- `side: "RIGHT"` is the head version, and covers added (`+`) and context lines. Use it
  unless you are commenting on something that was deleted.
- `side: "LEFT"` is the base version, for lines the PR removes. `line` is then numbered
  in the *old* file.
- The line must fall inside a hunk. A line the diff never shows cannot carry a comment,
  however relevant it is — put that point in the summary body instead.
- For a range, add `start_line` (and `start_side` if it differs); `start_line` must come
  before `line`. Both `start_line` and `line` must fall within the same hunk of the file
  — GitHub rejects a range that straddles a hunk boundary.

To get the set of lines you are allowed to anchor to, derive them from `/tmp/pr.patch` rather
than counting by eye — `references/github-api.md` has a one-line recipe that prints every
valid `path:line` on the RIGHT side. Checking your anchors against that list before
posting turns the most common failure into a non-event.

Then post the review:

```bash
~/.claude/skills/review-pr/scripts/post_pr_review.sh --repo owner/repo --pr 412 --commit 9f2c1ab \
  --event REQUEST_CHANGES --body-file /tmp/summary.md \
  --comments-file /tmp/comments.json
```

`--commit` defaults to the PR head the script reads at post time, but pass the SHA you
actually reviewed (`headRefOid` from Step 2) so that a push landing mid-review fails
loudly instead of anchoring your comments to code you never read. `--dry-run` prints the
payload without posting, which is the cheap way to check the JSON before spending the
call.

The script prints `{"status": "posted", "review_id": …, "html_url": …}` on success. On
failure it prints the API error plus a hint naming the fix. The two you should expect:

- **A line is not part of the diff** — re-derive that anchor, or drop the comment and fold
  its point into the summary. Then post again; nothing was published, so there is nothing
  to clean up.
- **The commit is no longer the PR head** — the author pushed while you were reading.
  Re-read the diff for the new head before posting, since your findings may no longer
  apply.

Write the summary body to a file rather than passing it inline; shell quoting mangles
backticks and newlines. A shape that works:

```markdown
## Review

One-paragraph read on what the PR does and whether it does it.

**Blocking**
- `src/parser.go:42` — panics when the config file is absent. (inline)

**Non-blocking**
- `src/store.go:88` — N+1 against `users`; `FindAllByIDs` exists. (inline)
- The migration has no rollback. Intentional?

**Checked and fine:** the retry backoff, the new error paths, the fixture updates.
**Not covered:** `vendor/`, the generated protobuf files.
```

Naming what you did not review is not a hedge — it tells the maintainer where they still
need their own eyes.

## Step 7 — Report to the terminal

Short, and enough to judge the review without opening GitHub:

```
Reviewed owner/repo#412 — "Add retry to the upload client"
Verdict: REQUEST_CHANGES · 3 inline comments · https://github.com/owner/repo/pull/412#pullrequestreview-987654321

Blocking
  src/parser.go:42   nil config dereferenced before the check — panics when no config file
Non-blocking
  src/store.go:88    N+1 query in the loop; store/batch.go:FindAllByIDs covers it
  src/retry.go:15    backoff caps at 2s while the client timeout is 30s — worth a comment

Read closely: src/parser.go, src/store.go, src/retry.go, tests/retry_test.go
Skimmed: vendor/, *.pb.go
```

If anything went wrong — an anchor you had to drop, files you could not read, a push that
landed mid-review — say it here. This is the only place the user sees it.

## What this skill does not do

- **It does not run the code.** A PR, especially from a fork, is untrusted code; executing
  its tests or build to "check" it hands it your machine. Read it instead. If the repo's
  CI already ran, `gh pr checks 412` tells you what passed without running anything.
- **It does not fix anything.** No commits, no pushes, no edits to the working tree.
  Applying review feedback is the `apply-pr-feedback` skill's job, and it should be the
  author's decision to invoke it.
- **It does not approve to be agreeable.** An approval means the code was read.
