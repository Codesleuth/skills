# GitHub PR review API reference

Raw commands for the parts `scripts/post_pr_review.sh` doesn't cover, plus the failures
this endpoint actually produces and what each one means.

Everything here needs only the `gh` CLI. `gh` embeds its own jq engine behind `--jq`, so
no separate `jq` install is required.

## Contents

- [Resolving the repo and the PR](#resolving-the-repo-and-the-pr)
- [Reading the change](#reading-the-change)
- [Reading files without touching the working tree](#reading-files-without-touching-the-working-tree)
- [Working out which lines a comment can anchor to](#working-out-which-lines-a-comment-can-anchor-to)
- [Posting the review](#posting-the-review)
- [Reviews that already exist](#reviews-that-already-exist)
- [CI status, without running anything](#ci-status-without-running-anything)
- [Failure modes worth recognizing](#failure-modes-worth-recognizing)
- [The sandbox trap](#the-sandbox-trap)

## Resolving the repo and the PR

```bash
gh repo view --json nameWithOwner --jq .nameWithOwner   # OWNER/REPO you're standing in
gh pr view --json number --jq .number                   # PR for the current branch
gh pr view 412 --json state,isDraft,mergeable,headRefOid
```

`gh pr view` accepts a number, a URL, or nothing (current branch). Add `--repo O/R` to
read a PR in a repository you are not standing in — but see the note in `SKILL.md` about
reviewing a repo you don't have checked out.

## Reading the change

```bash
# Metadata, including the head SHA to anchor comments to
gh pr view 412 --json title,body,author,baseRefName,headRefName,headRefOid,\
additions,deletions,changedFiles,commits,labels,files

# The patch itself
gh pr diff 412 > /tmp/pr.patch
gh pr diff 412 --name-only

# Per-file status and counts. --paginate matters: this endpoint returns 30 per page,
# so a large PR silently loses files without it.
gh api repos/OWNER/REPO/pulls/412/files --paginate \
  --jq '.[] | "\(.status)\t+\(.additions)/-\(.deletions)\t\(.filename)"'

# The patch for one file only
gh api repos/OWNER/REPO/pulls/412/files --paginate \
  --jq '.[] | select(.filename == "src/parser.go") | .patch'

# Commit messages, which say what the author thought they were doing
gh pr view 412 --json commits --jq '.commits[] | "\(.oid[0:9])  \(.messageHeadline)"'
```

`status` is one of `added`, `removed`, `modified`, `renamed`, `copied`, `changed`,
`unchanged`. Renames carry `previous_filename`. Files with no `patch` field are binary or
too large for GitHub to diff — you cannot anchor a comment inside one.

Use `gh pr diff` plain, not `gh pr diff --patch`. Plain gives one unified diff of
base…head, which is the state the review comments on. `--patch` gives mbox output with one
message per commit, so its line numbers describe intermediate states — anchors derived
from it land in the wrong place on any PR with more than one commit.

## Reading files without touching the working tree

Fetch the PR head into its own ref namespace, then read blobs out of it. No checkout, no
branch created, no interference with whatever the user has in progress:

```bash
git fetch origin pull/412/head:refs/review-pr/412 --force
git fetch origin "$BASE_REF"                           # so the base is current

git show refs/review-pr/412:src/parser.go              # file as the PR leaves it
git show "origin/$BASE_REF:src/parser.go"              # file before the change
git diff "origin/$BASE_REF...refs/review-pr/412" -- src/ # scoped diff
git log --oneline "origin/$BASE_REF..refs/review-pr/412" # commits unique to the PR

git update-ref -d refs/review-pr/412                   # clean up when done
```

Confirm the fetch matches what you are reviewing:

```bash
[ "$(git rev-parse refs/review-pr/412)" = "$(gh pr view 412 --json headRefOid --jq .headRefOid)" ]
```

GitHub serves `pull/N/head` from the PR's **base** repository. If `origin` is the base
repository (the standard layout), `git fetch origin pull/412/head:...` works directly.
If you are standing in a fork checkout where `origin` is your fork and `upstream` is the
base repo, fetch from the base remote instead:

```bash
git fetch upstream pull/412/head:refs/review-pr/412 --force
# or using the base repo URL directly:
git fetch "https://github.com/${OWNER}/${REPO}.git" pull/412/head:refs/review-pr/412 --force
```

## Working out which lines a comment can anchor to

A comment's `line` is a line number **in the file**, on the side you name — not an offset
into the patch — and it has to fall inside a hunk. Guessing costs you the whole review:
one bad anchor rejects every comment in the request.

Derive the valid anchors from the patch instead. This prints every line on the RIGHT
(head) side that a comment may attach to, as `path:line`:

```bash
awk '
  /^diff --git / { inhunk = 0; next }
  /^\+\+\+ / && !inhunk { file = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
  /^@@/ { inhunk = 1; match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
  /^[+ ]/ { if (inhunk && file != "") print file ":" n++ }
' /tmp/pr.patch
```

The LEFT (base) side, for commenting on lines the PR deletes:

```bash
awk '
  /^diff --git / { inhunk = 0; next }
  /^--- / && !inhunk { file = ($0 == "--- /dev/null") ? "" : substr($0, 7); next }
  /^@@/ { inhunk = 1; match($0, /-[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
  /^[- ]/ { if (inhunk && file != "") print file ":" n++ }
' /tmp/pr.patch
```

Both track whether they are inside a hunk before treating a `+++`/`---` line as a file
header, because a deleted line of SQL (`-- comment`) renders as `--- comment` in a patch
and would otherwise be read as the start of a new file. `+++ /dev/null` and `--- /dev/null`
mark the deleted and added sides of a whole-file change, where that side has no lines to
anchor to.

To check a set of anchors before posting:

```bash
awk '...' /tmp/pr.patch > /tmp/valid-anchors.txt   # recipe above
grep -Fxq "src/parser.go:42" /tmp/valid-anchors.txt && echo ok || echo "not in the diff"
```

Context lines count — a comment can sit on an unchanged line as long as the diff shows it.
Anything outside the hunks belongs in the summary body instead.

## Posting the review

Preferred: `scripts/post_pr_review.sh`, which builds the payload, escapes the body, and
translates the errors below into something actionable. The endpoint underneath is:

```bash
gh api --method POST repos/OWNER/REPO/pulls/412/reviews --input payload.json
```

```json
{
  "commit_id": "9f2c1ab…",
  "event": "REQUEST_CHANGES",
  "body": "## Review\n\n…",
  "comments": [
    {"path": "src/parser.go", "line": 42, "side": "RIGHT", "body": "…"},
    {"path": "src/store.go", "start_line": 88, "line": 94, "side": "RIGHT", "body": "…"},
    {"path": "src/old.go", "line": 9, "side": "LEFT", "body": "…"}
  ]
}
```

| Field | Notes |
|---|---|
| `event` | `APPROVE`, `REQUEST_CHANGES`, `COMMENT`. **Omitting it creates a PENDING review** — saved as a draft, visible to nobody until submitted by hand. |
| `body` | Required for `COMMENT` and `REQUEST_CHANGES`; optional for `APPROVE`. |
| `commit_id` | Defaults to the PR head at the moment of the call. Passing the SHA you reviewed turns a mid-review push into a clean error instead of comments on unread code. |
| `line` | Line number in the file, on `side`. Must be inside a hunk. |
| `side` | `RIGHT` (head, default) for added and context lines; `LEFT` (base) for deleted ones. |
| `start_line` / `start_side` | Multi-line ranges. `start_line` must precede `line`, and both must fall within the same hunk. |

The whole payload is one transaction: if any comment is rejected, nothing is posted, so a
retry after fixing the anchor cannot double-post.

`subject_type: "file"` — a comment on a file rather than a line — is a parameter of the
single-comment endpoint (`POST /repos/O/R/pulls/N/comments`), not of the batched `comments`
array here. In a review, put file-level points in the summary body.

## Reviews that already exist

```bash
# Reviews on the PR, yours included
gh api repos/OWNER/REPO/pulls/412/reviews --paginate \
  --jq '.[] | "\(.id)\t\(.user.login)\t\(.state)\t\(.submitted_at)"'

# Every inline comment currently on the diff, to avoid repeating a point
gh api repos/OWNER/REPO/pulls/412/comments --paginate \
  --jq '.[] | "\(.user.login)\t\(.path):\(.line)\t\(.body[0:100])"'

# Who the API thinks you are
gh api user --jq .login
```

A submitted review cannot be edited into a different verdict, but the summary body can be
updated, and a stale blocking review can be dismissed by someone with write access:

```bash
gh api --method PUT repos/OWNER/REPO/pulls/412/reviews/REVIEW_ID \
  -f body="Updated: the nil guard landed in 3f9a1c2, so this is no longer blocking."

gh api --method PUT repos/OWNER/REPO/pulls/412/reviews/REVIEW_ID/dismissals \
  -f message="Superseded — the blocking issue was fixed in 3f9a1c2." -f event=DISMISS
```

Prefer a new review over dismissing an old one unless the old verdict is actually blocking
a merge it should not.

## CI status, without running anything

The PR's own CI has already executed the code, so read its result rather than running
tests yourself:

```bash
gh pr checks 412                                    # human-readable
gh pr checks 412 --json name,state,bucket,link      # machine-readable
gh run view RUN_ID --log-failed                     # why a job failed
```

Exit 0 means everything passed, 8 means still pending, anything else is a failure. A red
build is worth a line in the summary; chasing it is not this skill's job.

## Failure modes worth recognizing

| Symptom | Cause | Response |
|---|---|---|
| 422 `line must be part of the diff` | Anchor is outside every hunk, or numbered against the wrong side | Re-derive from the anchor recipe; move the point to the summary if the line isn't in the diff |
| 422 `start_line must precede line` / invalid hunk range | Range comment inverted, `start_side` disagrees with `side`, or range spans across hunk boundaries | Order them, match the sides, and ensure both fall within the same hunk |
| 422 `No commit found for SHA` / not part of the PR | The author pushed while you were reviewing | Re-read the head SHA and the diff, then post against the new head |
| 422 `Can not approve your own pull request` | Approving a PR your token authored | Post the same review as `COMMENT` |
| 422 with no obvious cause | Malformed payload — usually a comment missing `path`, `line`, or `body` | Re-run the script with `--dry-run` and inspect the JSON |
| 403 / `Resource not accessible` | Token lacks write access to the repo | Reviews need write access, or a fine-grained token with `Pull requests: write` |
| 404 on a repo you can see in a browser | Token can't read private repos, or the number is wrong | Check `gh auth status` scopes and the PR number |
| Review posted, but PENDING | `event` was omitted | Submit it, or delete the pending review and post again with `--event` |
| `The token in keyring is invalid` | Almost always the sandbox, not the token | See below |

## The sandbox trap

Inside a sandbox with no network hosts allowed, `gh` cannot reach GitHub and reports it as
`The token in keyring is invalid`. The message points at the credential, so the natural
next step is `gh auth refresh` — which is both useless here and disruptive, since it can
replace a perfectly good token.

Before believing any authentication error: re-run the same command with the sandbox
disabled. If it works there, the token was never the problem.
