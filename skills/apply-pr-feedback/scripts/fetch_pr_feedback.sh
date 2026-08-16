#!/usr/bin/env bash
# Collect every piece of review feedback on a GitHub pull request as one JSON document.
#
# GitHub scatters review feedback across three surfaces that use different APIs, and only
# one of them can be resolved:
#
#   1. inline_thread  - comments anchored to diff lines. Carries a GraphQL thread node ID,
#                       which is the ONLY way to mark a thread resolved.
#   2. review_body    - the summary text submitted with an Approve / Request-changes review.
#   3. issue_comment  - general timeline comments not attached to a review.
#
# Usage:
#   ./fetch_pr_feedback.sh                       # PR for the current branch
#   ./fetch_pr_feedback.sh 412
#   ./fetch_pr_feedback.sh https://github.com/o/r/pull/412
#   ./fetch_pr_feedback.sh 412 --repo owner/repo > feedback.json
#
# Requires only the `gh` CLI, authenticated. gh embeds its own jq engine, so no
# separate jq install is needed. No other dependencies.

set -euo pipefail

PR_ARG=""
REPO_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) PR_ARG="$1"; shift ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "the gh CLI is required but not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated - run: gh auth login"

# --- Work out which repo and PR to read -------------------------------------------

if printf '%s' "$PR_ARG" | grep -qE 'github\.com/[^/]+/[^/]+/pull/[0-9]+'; then
  OWNER=$(printf '%s' "$PR_ARG" | sed -E 's#.*github\.com/([^/]+)/([^/]+)/pull/([0-9]+).*#\1#')
  REPO=$(printf '%s' "$PR_ARG" | sed -E 's#.*github\.com/([^/]+)/([^/]+)/pull/([0-9]+).*#\2#')
  NUMBER=$(printf '%s' "$PR_ARG" | sed -E 's#.*github\.com/([^/]+)/([^/]+)/pull/([0-9]+).*#\3#')
else
  if [ -n "$REPO_ARG" ]; then
    case "$REPO_ARG" in
      */*) OWNER="${REPO_ARG%%/*}"; REPO="${REPO_ARG##*/}" ;;
      *) die "--repo must be OWNER/REPO, got: $REPO_ARG" ;;
    esac
  else
    NWO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) \
      || die "not inside a GitHub repo - pass --repo OWNER/REPO"
    OWNER="${NWO%%/*}"; REPO="${NWO##*/}"
  fi

  if [ -n "$PR_ARG" ]; then
    case "$PR_ARG" in
      *[!0-9]*|"") die "could not parse a PR number from: $PR_ARG" ;;
      *) NUMBER="$PR_ARG" ;;
    esac
  else
    NUMBER=$(gh pr view --json number --jq .number 2>/dev/null) \
      || die "no PR found for the current branch - pass a PR number or URL"
  fi
fi

# --- Paginated GraphQL ------------------------------------------------------------
#
# gh cannot re-filter a response already captured in a shell variable, so each page is
# fetched with a --jq filter that prints "hasNextPage<TAB>endCursor" on the first line
# and one compact JSON node per line after it. The loop reads the cursor off line 1 and
# accumulates the rest.

fetch_pages() {
  local query="$1" conn="$2" node_filter="$3"
  local cursor="" page info nodes acc=""

  while :; do
    if [ -n "$cursor" ]; then
      page=$(gh api graphql -f query="$query" \
        -f owner="$OWNER" -f repo="$REPO" -F number="$NUMBER" -f cursor="$cursor" \
        --jq "(.data.repository.pullRequest.${conn}.pageInfo | \"\\(.hasNextPage)\\t\\(.endCursor)\"), (.data.repository.pullRequest.${conn}.nodes[] | ${node_filter})")
    else
      page=$(gh api graphql -f query="$query" \
        -f owner="$OWNER" -f repo="$REPO" -F number="$NUMBER" \
        --jq "(.data.repository.pullRequest.${conn}.pageInfo | \"\\(.hasNextPage)\\t\\(.endCursor)\"), (.data.repository.pullRequest.${conn}.nodes[] | ${node_filter})")
    fi

    info=$(printf '%s\n' "$page" | head -n 1)
    nodes=$(printf '%s\n' "$page" | tail -n +2)
    [ -n "$nodes" ] && acc="${acc}${nodes}"$'\n'

    case "$info" in
      true*) cursor="${info#*$'\t'}" ;;
      *) break ;;
    esac
  done

  # Emit the accumulated objects comma-joined, without enclosing brackets, so the
  # three collections can be concatenated into one array even when some are empty.
  printf '%s' "$acc" | awk 'BEGIN{sep=""} NF{printf "%s%s", sep, $0; sep=","}'
}

# Join non-empty comma-separated fragments, skipping empties so we never emit "[, ]".
join_parts() {
  local out="" part
  for part in "$@"; do
    [ -n "$part" ] || continue
    if [ -n "$out" ]; then out="${out},${part}"; else out="$part"; fi
  done
  printf '%s' "$out"
}

# A comment counts as bot-authored if GitHub types the account as a Bot, the login
# carries the [bot] suffix, or it matches a known reviewer bot that uses a plain login.
BOT_TEST='(.author.__typename == "Bot")
  or ((.author.login // "") | test("\\[bot\\]$"))
  or ((.author.login // "" | ascii_downcase) as $l | [
        "coderabbitai","copilot","copilot-pull-request-reviewer","sonarcloud","codecov",
        "deepsource-autofix","sourcery-ai","graphite-app","cursor","greptileai","ellipsis-dev"
      ] | index($l) != null)'

THREADS_QUERY='
query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated isCollapsed
          path line startLine originalLine
          comments(first:100) {
            nodes { databaseId body createdAt url diffHunk author { login __typename } }
          }
        }
      }
    }
  }
}'

REVIEWS_QUERY='
query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviews(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id body state createdAt url author { login __typename } }
      }
    }
  }
}'

COMMENTS_QUERY='
query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      comments(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { databaseId body createdAt url author { login __typename } }
      }
    }
  }
}'

# thread_id feeds the resolveReviewThread mutation; reply_to_comment_id feeds the REST
# reply endpoint. Both are required to close the loop on an inline thread.
THREAD_SHAPE='select(.comments.nodes | length > 0) | {
  kind: "inline_thread",
  thread_id: .id,
  reply_to_comment_id: .comments.nodes[0].databaseId,
  is_resolved: .isResolved,
  is_outdated: .isOutdated,
  path: .path,
  line: (.line // .originalLine),
  start_line: .startLine,
  url: .comments.nodes[0].url,
  diff_hunk: .comments.nodes[0].diffHunk,
  comments: [.comments.nodes[] | {
    author: (.author.login // "ghost"),
    is_bot: ('"$BOT_TEST"'),
    body: .body,
    created_at: .createdAt,
    url: .url
  }]
}'

# is_resolved is null for these two surfaces because GitHub has no resolve state for them.
REVIEW_SHAPE='select((.body // "") | test("\\S")) | {
  kind: "review_body",
  review_id: .id,
  state: .state,
  is_resolved: null,
  author: (.author.login // "ghost"),
  is_bot: ('"$BOT_TEST"'),
  body: .body,
  created_at: .createdAt,
  url: .url
}'

COMMENT_SHAPE='{
  kind: "issue_comment",
  comment_id: .databaseId,
  is_resolved: null,
  author: (.author.login // "ghost"),
  is_bot: ('"$BOT_TEST"'),
  body: .body,
  created_at: .createdAt,
  url: .url
}'

THREADS=$(fetch_pages "$THREADS_QUERY" "reviewThreads" "$THREAD_SHAPE")
REVIEWS=$(fetch_pages "$REVIEWS_QUERY" "reviews" "$REVIEW_SHAPE")
COMMENTS=$(fetch_pages "$COMMENTS_QUERY" "comments" "$COMMENT_SHAPE")

# is_fork / maintainer_can_modify decide whether pushing is even possible - check
# before doing any work.
PR_META=$(gh api graphql \
  -f query='
    query($owner:String!, $repo:String!, $number:Int!) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$number) {
          number title url state isDraft isCrossRepository maintainerCanModify
          baseRefName headRefName headRefOid
          author { login }
          headRepositoryOwner { login }
        }
      }
    }' \
  -f owner="$OWNER" -f repo="$REPO" -F number="$NUMBER" \
  --jq '.data.repository.pullRequest | {
    number, title, url, state,
    is_draft: .isDraft,
    author: (.author.login // "ghost"),
    base_branch: .baseRefName,
    head_branch: .headRefName,
    head_sha: .headRefOid,
    is_fork: .isCrossRepository,
    maintainer_can_modify: .maintainerCanModify,
    head_owner: .headRepositoryOwner.login
  }')

[ -n "$PR_META" ] || die "no pull request #$NUMBER in $OWNER/$REPO"

printf '{\n  "repo": "%s/%s",\n  "pr": %s,\n  "items": [%s]\n}\n' \
  "$OWNER" "$REPO" "$PR_META" \
  "$(join_parts "$THREADS" "$REVIEWS" "$COMMENTS")"
