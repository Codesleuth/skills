#!/usr/bin/env bash
# Publish a complete pull request review - every inline comment plus the summary and the
# verdict - in one request.
#
# Posting comments one at a time emails the author once per comment and leaves a
# half-finished review on the PR if the run stops midway. The reviews endpoint takes the
# whole review as a single payload, so it lands as one event with one notification.
#
# Usage:
#   ./post_pr_review.sh --pr 412 --event COMMENT \
#       --body-file summary.md --comments-file comments.json
#
#   ./post_pr_review.sh --repo owner/repo --pr 412 --event APPROVE \
#       --body "Checked the migration against the existing schema - it holds."
#
#   ./post_pr_review.sh --pr 412 --event REQUEST_CHANGES --body-file summary.md \
#       --comments-file comments.json --commit 9f2c1ab --dry-run
#
# Arguments:
#   --pr NUMBER          required
#   --event EVENT        APPROVE | REQUEST_CHANGES | COMMENT (required)
#   --repo OWNER/REPO    defaults to the repository you are standing in
#   --body TEXT          summary body; required for COMMENT and REQUEST_CHANGES
#   --body-file FILE     read the summary from a file - preferred, no shell quoting
#   --comments-file FILE JSON array of {path, line, side, body} inline comments
#   --commit SHA         head commit to anchor to; read from the PR when omitted
#   --dry-run            print the payload instead of posting it
#
# Prints one JSON object on stdout - review_id, html_url, state, commit_id, status - and
# sends diagnostics for the failures this endpoint actually produces to stderr.
#
# Requires only the `gh` CLI, authenticated. No jq, no Python.

set -uo pipefail

REPO=""; PR=""; EVENT=""; BODY=""; BODY_FILE=""; COMMENTS_FILE=""; COMMIT=""
DRY_RUN=0

# Print the header comment block above, so --help can never drift from the real flags.
usage() { awk 'NR>1 && /^#/ { sub(/^#[[:space:]]?/, ""); print; next } NR>1 { exit }' "$0"; }

die() { echo "error: $*" >&2; exit 2; }
hint() { echo "hint: $*" >&2; }
need_gh() { command -v gh >/dev/null 2>&1 || die "the gh CLI is required but not installed"; }

validate_json() {
  local file="$1" desc="$2"
  local err
  err=$(awk '
    BEGIN { in_str = 0; esc = 0; depth = 0; err = 0 }
    {
      len = length($0)
      for (i = 1; i <= len; i++) {
        c = substr($0, i, 1)
        if (in_str) {
          if (esc) {
            esc = 0
          } else if (c == "\\") {
            esc = 1
          } else if (c == "\"") {
            in_str = 0
          }
        } else {
          if (c == "\"") {
            in_str = 1
          } else if (c == "{" || c == "[") {
            stack[++depth] = c
          } else if (c == "}") {
            if (depth == 0 || stack[depth] != "{") {
              print "unexpected '\''}'\'' at line " NR; err = 1; exit 1
            }
            depth--
          } else if (c == "]") {
            if (depth == 0 || stack[depth] != "[") {
              print "unexpected '\'']'\'' at line " NR; err = 1; exit 1
            }
            depth--
          }
        }
      }
      if (in_str && !esc) {
        print "unescaped newline inside string literal at line " NR; err = 1; exit 1
      }
    }
    END {
      if (!err) {
        if (in_str) { print "unclosed string literal at EOF"; exit 1 }
        if (depth > 0) { print "unclosed " stack[depth] " at EOF"; exit 1 }
      }
    }
  ' "$file" 2>&1) || die "$desc is not valid JSON: $err"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--pr|--event|--body|--body-file|--comments-file|--commit)
      [ $# -ge 2 ] || die "$1 requires a value" ;;
  esac
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --comments-file) COMMENTS_FILE="$2"; shift 2 ;;
    --commit) COMMIT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Validate before spending an API call -----------------------------------------

case "$PR" in
  "") die "--pr NUMBER is required" ;;
  *[!0-9]*) die "--pr must be a number, got: $PR" ;;
esac

# Omitting the event would create a PENDING review - invisible to everyone until it is
# submitted by hand, which is never what a finished review wants.
case "$EVENT" in
  APPROVE|REQUEST_CHANGES|COMMENT) ;;
  "") die "--event is required: APPROVE, REQUEST_CHANGES or COMMENT" ;;
  *) die "--event must be APPROVE, REQUEST_CHANGES or COMMENT, got: $EVENT" ;;
esac

if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die "no such file: $BODY_FILE"
  BODY=$(cat "$BODY_FILE")
fi

# GitHub rejects a blank body on these two events; catching it here costs nothing and
# saves a confusing 422.
if [ "$EVENT" != "APPROVE" ] && ! printf '%s' "$BODY" | grep -q '[^[:space:]]'; then
  die "$EVENT needs a summary body - pass --body-file FILE or --body TEXT"
fi

if [ -n "$COMMENTS_FILE" ]; then
  [ -f "$COMMENTS_FILE" ] || die "no such file: $COMMENTS_FILE"
  case "$(tr -d '[:space:]' < "$COMMENTS_FILE" | cut -c1-1)" in
    "[") ;;
    "") die "--comments-file is empty - omit the flag if there are no inline comments" ;;
    *) die "--comments-file must hold a JSON array of {path, line, side, body} objects" ;;
  esac
  validate_json "$COMMENTS_FILE" "--comments-file"
fi

# --- Resolve the repo and the commit being reviewed -------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  REPO="${REPO:-owner/repo}"
  COMMIT="${COMMIT:-HEAD}"
else
  if [ -z "$REPO" ]; then
    need_gh
    if ! REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1); then
      echo "$REPO" >&2
      die "could not resolve repository name (pass --repo OWNER/REPO)"
    fi
  fi
  case "$REPO" in
    */*) ;;
    *) die "--repo must be OWNER/REPO, got: $REPO" ;;
  esac

  # Anchoring to the SHA you actually read means a comment can never land on a line the
  # author changed after you fetched the diff - GitHub rejects it instead.
  if [ -z "$COMMIT" ]; then
    need_gh
    if ! COMMIT=$(gh api "repos/${REPO}/pulls/${PR}" --jq .head.sha 2>&1); then
      echo "$COMMIT" >&2
      die "could not read the head commit of ${REPO}#${PR}"
    fi
  fi
fi

# --- Build the payload ------------------------------------------------------------

# JSON-escape a string with the tools every POSIX box already has. Tab and newline are
# kept and escaped; the other control characters are dropped, since none of them belong
# in a review body and a stray one produces a payload GitHub rejects as malformed JSON.
json_escape() {
  printf '%s' "$1" \
    | LC_ALL=C tr -d '\001-\010\013-\037' \
    | LC_ALL=C awk '
        BEGIN { ORS = "" }
        {
          if (NR > 1) printf "\\n"
          s = $0
          gsub(/\\/, "\\\\", s)
          gsub(/"/, "\\\"", s)
          gsub(/\t/, "\\t", s)
          printf "%s", s
        }'
}

PAYLOAD=$(mktemp "${TMPDIR:-/tmp}/pr-review.XXXXXX") || die "could not create a temp file"
trap 'rm -f "$PAYLOAD"' EXIT

{
  printf '{"commit_id": "%s", "event": "%s"' "$COMMIT" "$EVENT"
  if printf '%s' "$BODY" | grep -q '[^[:space:]]'; then
    printf ', "body": "%s"' "$(json_escape "$BODY")"
  fi
  if [ -n "$COMMENTS_FILE" ]; then
    printf ', "comments": '
    cat "$COMMENTS_FILE"
  fi
  printf '}\n'
} > "$PAYLOAD"

validate_json "$PAYLOAD" "review payload"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "would POST repos/${REPO}/pulls/${PR}/reviews" >&2
  cat "$PAYLOAD"
  exit 0
fi

# --- Post -------------------------------------------------------------------------

need_gh

OUT=$(gh api --method POST "repos/${REPO}/pulls/${PR}/reviews" --input "$PAYLOAD" \
      --jq '[(.id | tostring), .html_url, .state, .commit_id] | @tsv' 2>&1)
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  IFS=$'\t' read -r REVIEW_ID HTML_URL STATE COMMIT_ID <<< "$OUT"
  printf '{"status": "posted", "review_id": %s, "html_url": "%s", "state": "%s", "commit_id": "%s"}\n' \
    "$REVIEW_ID" "$HTML_URL" "$STATE" "$COMMIT_ID"
  exit 0
fi

# The endpoint fails in a handful of recognisable ways, and the raw message rarely names
# the fix. Say what to do about each rather than making the caller guess.
echo "$OUT" >&2

case "$OUT" in
  *"must be part of the diff"*|*"line must be part of"*|*"pull_request_review_thread"*)
    hint "an inline comment points at a line outside the diff. 'line' is numbered in the file on that comment's side - RIGHT for added and context lines, LEFT for removed ones - and must fall inside a hunk. Re-derive the anchors from the patch, drop the ones you cannot place, and retry." ;;
  *"start_line must precede"*|*"start_side"*)
    hint "a multi-line comment has start_line at or after line; start_line must come first, and start_side must match the side it is numbered against." ;;
  *"No commit found for SHA"*|*"not part of the pull request"*|*"commit_id"*)
    hint "the commit is not the PR head any more - the author pushed while you were reviewing. Re-read the head SHA, re-derive the diff, and post against the new one." ;;
  *"approve your own"*|*"Can not approve"*)
    hint "GitHub does not let an account approve its own pull request. Post the same review with --event COMMENT." ;;
  *"HTTP 400"*|*"Problems parsing JSON"*|*"parse error"*)
    hint "GitHub could not parse the review payload as JSON. Run with --dry-run to inspect the generated payload, and check that --comments-file contains valid JSON with properly escaped strings (newlines as \\n, quotes as \\\")." ;;
  *"HTTP 403"*|*"Resource not accessible"*)
    hint "the token cannot write to ${REPO}. Reviews need write access, or a fine-grained token with 'Pull requests: write'." ;;
  *"HTTP 401"*|*"keyring is invalid"*|*"authentication"*|*"credentials"*)
    hint "authentication was rejected. Inside a sandbox with no network this is what blocked outbound requests look like - re-run with the sandbox disabled before assuming the token expired." ;;
  *"HTTP 404"*|*"Not Found"*)
    hint "no pull request #${PR} in ${REPO} that this token can see. Check the repo and number, and that the token can read private repos if this one is private." ;;
  *"HTTP 422"*|*"Unprocessable"*)
    hint "GitHub parsed the request but rejected its contents. Run again with --dry-run and check the payload: comments need path, line, side and body, and the array must be valid JSON." ;;
  *"dial tcp"*|*"no such host"*|*"connection refused"*|*"context deadline exceeded"*)
    hint "the request never reached GitHub. In a sandboxed shell outbound network is blocked - re-run with the sandbox disabled." ;;
esac

printf '{"status": "failed", "review_id": null, "html_url": null, "state": null, "commit_id": "%s"}\n' \
  "$COMMIT"
exit 1
