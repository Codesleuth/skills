# review-pr

Reviews a GitHub pull request in the context of the whole repository — not just the diff
hunks — and publishes the result as a single GitHub review: inline comments anchored to
the lines they're about, plus a summary that approves, comments, or requests changes.

It runs start to finish without stopping to ask you questions. Questions it has for the
author go on the PR, where they belong.

## Required tooling

| Tool | Why | Check |
|---|---|---|
| [`gh`](https://cli.github.com) (GitHub CLI) | Reads the PR and its diff, posts the review | `gh --version` |
| `git` | Reads the changed files at the PR's head without disturbing your checkout | `git --version` |
| `bash` | Runs the bundled script | already present on macOS and Linux |

That is the whole list. **No Python, no `jq`, no other installs.** `gh` embeds its own jq
engine behind the `--jq` flag, which is what the script uses.

### Installing `gh`

```bash
brew install gh                      # macOS
sudo apt install gh                  # Debian / Ubuntu
winget install --id GitHub.cli       # Windows
```

Other platforms: <https://github.com/cli/cli#installation>

### Authenticating

```bash
gh auth login
gh auth status     # confirm it worked
```

### Permissions the token needs

- **`repo` scope**, or a fine-grained token with **`Pull requests: write`**. Posting a
  review is a write operation even when the verdict is "approve".
- **Write access to the repository.** Reading a public PR needs nothing special; leaving a
  review on it does.
- GitHub does not let an account approve its own pull request. Reviewing your own PR still
  works — the verdict comes back as a comment rather than an approval.

## Using it

Ask for it in natural language:

```
review PR 412
do a code review on https://github.com/owner/repo/pull/412
check this PR for bugs before I merge it
review the pull request for this branch and post the review
```

With no PR given it reviews the pull request for the branch you're on.

Running the publishing step by hand, if you want to post a review you assembled yourself:

```bash
skills/review-pr/scripts/post_pr_review.sh --pr 412 --event COMMENT \
  --body-file summary.md --comments-file comments.json

# see the exact payload without posting anything
skills/review-pr/scripts/post_pr_review.sh --pr 412 --event APPROVE \
  --body "Read it end to end — the migration is reversible." --dry-run
```

`--help` lists every flag.

## What it will and won't do

**Will**

- Read the changed files at the PR's head, their callers, the tests, and the conventions
  the rest of the codebase follows — then judge the diff against all of that
- Follow rules the repo writes down (`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, linter
  configs) and cite them when a change breaks one
- Look for correctness defects, security holes, performance traps, missing tests, and
  documentation the change has made untrue
- Anchor each comment to the line it's about, including multi-line ranges and deleted
  lines, with a ```suggestion block where the fix is small and unambiguous
- Post everything as one review, so the author gets one notification
- Say what it read closely, what it skimmed, and what it didn't cover

**Won't**

- Run the pull request's code, tests, or build. A PR is untrusted code — especially from a
  fork — and executing it to "check" it is a bigger risk than the review is worth. It
  reads the code and reads CI's verdict instead.
- Change anything: no commits, no pushes, no edits to your working tree, no branch
  checkouts. Applying feedback is the [`apply-pr-feedback`](../apply-pr-feedback) skill's
  job.
- Pause mid-run to ask you what you think about a finding.
- Approve a PR it hasn't actually read through, or pad a review with findings to look
  thorough. "Nothing to flag" is a legitimate outcome and it will say so.

## Before you run it

- **The PR must be open.** A review on a merged or closed PR reaches nobody who can act on
  it, so it stops and reports instead.
- **Be in a checkout of the PR's repository.** The whole point is repository context. If
  you're somewhere else, it will either clone the right repo to a temp directory or tell
  you plainly that it only reviewed the diff.
- **Your working tree is left alone.** It fetches the PR head into a `refs/review-pr/*`
  ref and reads file contents out of that ref, so uncommitted work and your current branch
  are untouched.
- **The review is published under your account.** A maintainer will read it as yours.

## Notes and limits

- **A review is one shot.** GitHub has no "edit the verdict" operation — a posted
  `REQUEST_CHANGES` can be dismissed or superseded, but not rewritten. That's why nothing
  is published until every comment is ready.
- **Comments can only attach to lines the diff shows.** A problem in code the PR doesn't
  touch goes in the summary body instead, with the file and line named.
- **Binary files and files too large for GitHub to diff** can't carry inline comments.
- **A push during the review** invalidates the anchors. The run detects this and re-reads
  the diff rather than commenting on code it never saw.
- **Bot reviews already on the PR** are read so their points aren't repeated, but they're
  not treated as authoritative.

## Files

| Path | Purpose |
|---|---|
| `SKILL.md` | The instructions Claude follows |
| `scripts/post_pr_review.sh` | Publishes the inline comments and summary as one review |
| `references/github-api.md` | Raw `gh` commands, the diff-anchor recipe, and failure modes |

## Sandbox warning

If `gh` is run inside a sandbox with no network access, it fails with:

```
The token in keyring is invalid
```

**This is not an authentication problem.** The message names the credential because that's
the failure `gh` knows how to report, but the real cause is that the request never left the
machine. Running `gh auth refresh` on the strength of it is at best wasted effort and at
worst replaces a working token.

Re-run the same command with the sandbox disabled. If it succeeds there, nothing was ever
wrong with your login.
