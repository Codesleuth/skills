# GitHub PR feedback API reference

Raw commands for cases the bundled scripts don't cover. The scripts handle the common
path; reach for these when you need something bespoke.

Everything here needs only the `gh` CLI. `gh` embeds its own jq engine behind `--jq`,
so no separate `jq` install is required.

## Contents

- [The three feedback surfaces](#the-three-feedback-surfaces)
- [Reading feedback](#reading-feedback)
- [Replying](#replying)
- [Resolving threads](#resolving-threads)
- [Suggested changes](#suggested-changes)
- [CI checks and logs](#ci-checks-and-logs)
- [Branch and push state](#branch-and-push-state)
- [Failure modes worth recognizing](#failure-modes-worth-recognizing)

## The three feedback surfaces

They are genuinely different objects, which is why one script normalizes them:

| Surface | Anchored to | Can reply in-thread? | Can resolve? |
|---|---|---|---|
| Inline review thread | A diff line | Yes | **Yes** — GraphQL only |
| Review summary body | The review | No | No |
| Top-level PR comment | The PR timeline | No | No |

Resolving exists only for inline threads. For the other two the best available response
is a top-level PR comment that quotes what you're answering. Do not tell the user a
review body was "resolved" — GitHub has no such state for it.

## Reading feedback

Preferred: `scripts/fetch_pr_feedback.sh`, which returns all three surfaces with the IDs
needed for replying and resolving.

Quick looks without the script:

```bash
# Review summary bodies and their states
gh pr view 412 --json reviews \
  --jq '.reviews[] | {author: .author.login, state, body}'

# Top-level timeline comments
gh pr view 412 --json comments \
  --jq '.comments[] | {author: .author.login, body}'

# Inline comments via REST — note this gives you comments, NOT threads,
# so it has no thread ID and no isResolved. Use GraphQL when you need those.
gh api repos/OWNER/REPO/pulls/412/comments \
  --jq '.[] | {id, path, line, user: .user.login, body}'
```

The thread-level GraphQL query (thread ID, resolved and outdated state) is embedded in
`scripts/fetch_pr_feedback.sh` as `THREADS_QUERY` — read it there rather than retyping it.

## Replying

```bash
# Threaded reply on an inline review thread.
# comment_id is the databaseId of any comment already in that thread
# (fetch_pr_feedback.sh reports it as reply_to_comment_id).
gh api --method POST \
  repos/OWNER/REPO/pulls/412/comments/COMMENT_ID/replies \
  -f body="Fixed in abc1234 — added the nil guard before dereferencing."

# Top-level PR comment (the only response channel for review bodies / issue comments)
gh pr comment 412 --body-file reply.md
```

Use `--body-file` for anything multi-line; shell quoting mangles backticks and newlines.

## Resolving threads

REST has no endpoint for this. Only the GraphQL mutation works:

```bash
gh api graphql -f query='
mutation($threadId:ID!) {
  resolveReviewThread(input:{threadId:$threadId}) {
    thread { id isResolved }
  }
}' -F threadId="PRRT_kwDOABCD..."
```

To unresolve, the mutation is `unresolveReviewThread` with the same input shape.

Resolving requires write access to the repository. On a PR from a fork, the reviewer or
a maintainer may hold that permission while the PR author does not.

## Suggested changes

A reviewer's ```suggestion block is the reviewer's own literal replacement text for the
commented lines. Applying one by hand is just editing those lines to match the block.

GitHub can also batch-apply them in the web UI, which produces commits authored by the
reviewer. That conflicts with one-commit-per-fix and with authoring your own commit
messages, so prefer applying the edit yourself in a normal commit.

## CI checks and logs

```bash
# Block until checks finish. Exit 0 = all passed, 8 = still pending, other = failure.
gh pr checks 412 --watch --fail-fast

# Machine-readable status. `bucket` collapses state into pass/fail/pending/skipping/cancel.
gh pr checks 412 --json name,state,bucket,link,workflow

# Only the checks that actually gate merging
gh pr checks 412 --required --json name,bucket,link

# Failing logs. The run ID is the numeric segment of a check's `link`.
gh run view RUN_ID --log-failed
gh run view RUN_ID --json jobs --jq '.jobs[] | select(.conclusion=="failure") | .name'
```

To tell an unrelated failure from one you caused, check whether the same workflow is
already failing on the base branch:

```bash
gh run list --branch main --workflow ci.yml --limit 5 \
  --json conclusion,headSha,createdAt
```

A job that is red on the base branch too is pre-existing. Report it; don't chase it.

## Branch and push state

```bash
gh pr view 412 --json headRefName,headRefOid,isCrossRepository,maintainerCanModify,state

git rev-parse --abbrev-ref HEAD     # local branch
git status --porcelain              # empty means clean tree
git log --oneline @{u}..HEAD        # unpushed local commits
git fetch origin && git status -sb  # ahead/behind the remote
```

For a fork PR, `isCrossRepository: true` and the push remote is the fork, not `origin`.
If `maintainerCanModify` is false and you are not the fork owner, you cannot push —
find that out before writing any code.

## Failure modes worth recognizing

| Symptom | Cause | Response |
|---|---|---|
| `Could not resolve to a node` | Thread ID is stale or from another PR | Re-run the fetch script for fresh IDs |
| Resolve returns permission error | No write access, common on fork PRs | Reply anyway; report the thread as replied-but-unresolved |
| `Parent comment not found` (404) on the replies endpoint | `comment_id` isn't a review comment (it's an issue comment) | Use `gh pr comment` instead |
| `gh pr checks` exits 8 forever | No checks configured, or all still queued | Treat "no checks" as nothing to wait for; don't block indefinitely |
| Push rejected, non-fast-forward | Branch moved on the remote | `git pull --rebase`, re-run checks, push again |
