#!/usr/bin/env bash
# Post a reply to PR review feedback and optionally mark the thread resolved.
#
# Replying and resolving use two different APIs (REST and GraphQL), and resolving fails
# in ways worth telling apart - no write access, stale node ID, already resolved. This
# script does both in one call and reports each step separately, so a failed resolve
# never looks like a failed reply.
#
# Usage:
#   # Reply inside an inline review thread, then resolve it
#   ./reply_and_resolve.sh --repo o/r --pr 412 \
#       --reply-to 1234567890 --thread-id PRRT_kwDO... --body-file reply.md --resolve
#
#   # Reply without resolving (leaves the conversation open)
#   ./reply_and_resolve.sh --repo o/r --pr 412 --reply-to 1234567890 --body "..."
#
#   # Top-level PR comment - the only way to answer a review body or an issue
#   # comment, since neither supports threaded replies or resolving
#   ./reply_and_resolve.sh --repo o/r --pr 412 --pr-comment --body-file reply.md
#
# Requires only the `gh` CLI, authenticated. No other dependencies.

set -uo pipefail

REPO=""; PR=""; REPLY_TO=""; THREAD_ID=""; BODY=""; BODY_FILE=""
PR_COMMENT=0; DO_RESOLVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --reply-to) REPLY_TO="${2:-}"; shift 2 ;;
    --thread-id) THREAD_ID="${2:-}"; shift 2 ;;
    --body) BODY="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --pr-comment) PR_COMMENT=1; shift ;;
    --resolve) DO_RESOLVE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 2; }

[ -n "$REPO" ] || die "--repo OWNER/REPO is required"
[ -n "$PR" ] || die "--pr NUMBER is required"
[ -n "$REPLY_TO" ] || [ "$PR_COMMENT" -eq 1 ] \
  || die "pass either --reply-to <comment_id> or --pr-comment"
[ "$DO_RESOLVE" -eq 0 ] || [ -n "$THREAD_ID" ] || die "--resolve requires --thread-id"

if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die "no such file: $BODY_FILE"
  BODY=$(cat "$BODY_FILE")
fi
printf '%s' "$BODY" | grep -q '[^[:space:]]' || die "reply body is empty"

REPLY_OK=0
REPLY_URL=""
REPLY_ERR=""

if [ "$PR_COMMENT" -eq 1 ]; then
  # Top-level timeline comment.
  OUT=$(gh api --method POST "repos/${REPO}/issues/${PR}/comments" \
        -f body="$BODY" --jq .html_url 2>&1)
  STATUS=$?
else
  # Threaded reply. REPLY_TO is the databaseId of a comment already in that thread.
  OUT=$(gh api --method POST "repos/${REPO}/pulls/${PR}/comments/${REPLY_TO}/replies" \
        -f body="$BODY" --jq .html_url 2>&1)
  STATUS=$?
fi

if [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '^https://'; then
  REPLY_OK=1
  REPLY_URL="$OUT"
else
  REPLY_ERR="$OUT"
  # GitHub words this 404 as "Parent comment not found" on the replies endpoint and as
  # "Not Found" elsewhere, so match without regard to case.
  if printf '%s' "$OUT" | grep -qi 'not found'; then
    REPLY_ERR="$OUT (if this is a top-level comment rather than a review comment, use --pr-comment)"
  fi
fi

RESOLVE_STATUS="not_requested"
RESOLVE_ERR=""

if [ "$DO_RESOLVE" -eq 1 ]; then
  if [ "$REPLY_OK" -eq 1 ]; then
    # REST cannot resolve a thread; only this GraphQL mutation can.
    OUT=$(gh api graphql -f query='
      mutation($threadId:ID!) {
        resolveReviewThread(input:{threadId:$threadId}) {
          thread { id isResolved }
        }
      }' -F threadId="$THREAD_ID" \
      --jq .data.resolveReviewThread.thread.isResolved 2>&1)

    if [ "$OUT" = "true" ]; then
      RESOLVE_STATUS="resolved"
    else
      RESOLVE_STATUS="failed"
      RESOLVE_ERR="$OUT"
      case "$OUT" in
        *"Could not resolve to a node"*)
          RESOLVE_ERR="$OUT (stale thread_id - re-run fetch_pr_feedback.sh for fresh IDs)" ;;
        *[Pp]ermission*|*[Aa]ccess*)
          RESOLVE_ERR="$OUT (resolving needs write access to the repo; on a fork PR the head repo owner may need to do it)" ;;
      esac
    fi
  else
    # Resolving a thread whose reply failed would hide the comment with no explanation.
    RESOLVE_STATUS="skipped"
    RESOLVE_ERR="reply failed, so the thread was left open"
  fi
fi

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }

printf '{"reply_ok": %s, "reply_url": "%s", "reply_error": "%s", "resolve": "%s", "resolve_error": "%s"}\n' \
  "$([ "$REPLY_OK" -eq 1 ] && echo true || echo false)" \
  "$(esc "$REPLY_URL")" "$(esc "$REPLY_ERR")" \
  "$RESOLVE_STATUS" "$(esc "$RESOLVE_ERR")"

[ "$REPLY_OK" -eq 1 ] || exit 1
[ "$RESOLVE_STATUS" = "failed" ] && exit 1
exit 0
