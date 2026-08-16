# apply-pr-feedback

Applies review feedback on a GitHub pull request end to end: reads every review comment,
fixes the ones that are unambiguous as one commit each, pushes, waits for CI to go green,
then replies to each comment with the commit hash and resolves the thread.

Anything that needed a judgment call is **not** acted on and **not** posted to the PR. It
is collected into a summary at the end for you to decide on.

## Required tooling

| Tool | Why | Check |
|---|---|---|
| [`gh`](https://cli.github.com) (GitHub CLI) | Reads reviews, posts replies, resolves threads, watches CI | `gh --version` |
| `git` | Commits and pushes the fixes | `git --version` |
| `bash` | Runs the two bundled scripts | already present on macOS and Linux |

That is the whole list. **No Python, no `jq`, no other installs.** `gh` embeds its own jq
engine behind the `--jq` flag, which is what the scripts use.

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

If you see `The token in keyring is invalid`, refresh it:

```bash
gh auth refresh -h github.com
```

### Permissions the token needs

- **`repo` scope** — read the PR, post comments, push commits.
- **Write access to the repository** — required to resolve review threads. Replying works
  without it; resolving does not. On a pull request from a fork, the fork owner or a
  maintainer may hold this permission when you don't. The skill reports any thread it
  replied to but could not resolve rather than failing the run.

## Using it

Ask for it in natural language. Any of these will do:

```
apply the PR feedback on 412
address the review comments on this PR
fix what the reviewers flagged and resolve the threads
```

With no PR given it uses the pull request for the branch you're on.

## Before you run it

The skill checks these and stops with an explanation rather than doing something
surprising, but knowing them saves a wasted run:

- **Be on the PR's head branch.** Commits go to the branch you have checked out.
- **Have a clean working tree.** Uncommitted changes would be swept into the fix commits
  and break the one-commit-per-comment guarantee.
- **The PR must be open.** Nothing to push to on a merged or closed PR.

## What it will and won't do

**Will**

- Fix concrete defects, apply reviewers' ```suggestion blocks, and follow specific
  instructions like "rename this" or "add a test for the empty case"
- Make one commit per comment, each citing the comment it addresses
- Run the checks your repo documents — including hooks the repo says to install but that
  aren't active in your checkout
- Push, then watch CI and fix failures its own changes caused, up to three attempts
- Reply with the commit hash and what changed, then resolve the thread
- Triage bot reviewers (CodeRabbit, Copilot, Graphite) the same as humans, after checking
  their claims against the real code

**Won't**

- Ask you questions in the middle of a run — judgment calls go in the final summary
- Post anything on the PR about comments it decided not to act on
- Resolve a thread it did not actually fix
- Force-push, amend, or rebase commits it didn't create in that run
- Push when local checks fail, or reply and resolve when CI is red from its own changes

## Notes and limits

- **Only inline review threads can be resolved.** GitHub has no resolve state for review
  summary bodies or top-level PR comments, so those get a fix and a reply, nothing more.
  The skill will not claim otherwise.
- **Already-resolved threads are skipped**, on the assumption someone handled them.
- **Outdated threads** (the code moved since the comment) are checked against current code
  before anything is changed, since the issue is often already fixed.
- **This skill writes to a shared branch and posts publicly under your account.** Review
  the summary it produces; the deferred items are the ones that still need you.

## Files

| Path | Purpose |
|---|---|
| `SKILL.md` | The instructions Claude follows |
| `scripts/fetch_pr_feedback.sh` | Collects all three feedback surfaces into one JSON document |
| `scripts/reply_and_resolve.sh` | Posts a reply and optionally resolves the thread |
| `references/github-api.md` | Raw `gh` commands, CI log retrieval, and failure modes |

Both scripts are runnable on their own if you want to inspect a PR's feedback without
letting the skill change anything:

```bash
scripts/fetch_pr_feedback.sh 412 | less
```
