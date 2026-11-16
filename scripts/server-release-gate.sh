#!/usr/bin/env bash
# Exact-main release gate for a server that deploys by pulling main (cron).
#
# The same contract as scripts/release-eligible.sh, for production hosts that
# have curl and jq but no gh CLI and no interactive login. Read-only; it never
# deploys, fetches or writes anything. Exit 0 means "this exact SHA may ship".
#
#   server-release-gate.sh --repo OWNER/REPO --sha 40_HEX_SHA \
#       --token-file /path/to/read-only-token \
#       --workflow ci-gate.yml [--workflow ...] \
#       --job backend-build [--job ...] [--require-sonar]
#
# A release is eligible only when ALL of these hold:
#   1. the SHA is the current main head (checked first and again last);
#   2. a merged pull request into main has this SHA as its merge commit
#      (a direct push to main never qualifies);
#   3. the latest main-push run of every named workflow for this SHA
#      completed with success (a PR run or an older main run does not count);
#   4. every named job has a completed, successful check run on this SHA
#      (missing, pending, skipped, neutral, cancelled or failed all block);
#   5. with --require-sonar, the independent "SonarCloud Code Analysis"
#      quality gate passed on this SHA (a scanner job finishing is not enough);
#   6. no commit status context on this SHA is failing or pending.
# Any API error, truncated response or unexpected shape blocks the release.
#
# The token must be a fine-grained, read-only GitHub token (Contents, Pull
# requests, Actions, Checks and Commit statuses: read) in a file that only its
# owner can read (mode 0600 or 0400). It is passed to curl on stdin, never as a
# command-line argument, so it does not appear in the process list or logs.
#
# Install a reviewed copy OUTSIDE the checkout that cron fetches, so a newly
# fetched (not yet validated) commit can never replace its own gate.
set -Eeuo pipefail

API="https://api.github.com"
usage() {
  echo "Usage: $0 --repo OWNER/REPO --sha 40_HEX_SHA --token-file FILE --workflow FILE.yml [...] --job NAME [...] [--require-sonar]"
}
fail() { printf 'RELEASE BLOCKED: %s\n' "$*" >&2; exit 1; }

repo='' sha='' token_file='' sonar=0
jobs=() workflows=()
while (($#)); do
  case "$1" in
    --repo|--sha|--token-file|--job|--workflow)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --repo) repo=$2 ;;
        --sha) sha=$2 ;;
        --token-file) token_file=$2 ;;
        --job) jobs+=("$2") ;;
        --workflow) workflows+=("$2") ;;
      esac
      shift 2 ;;
    --require-sonar) sonar=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'invalid repository'
[[ "$sha" =~ ^[a-f0-9]{40}$ ]] || fail 'invalid SHA'
((${#jobs[@]} > 0 && ${#workflows[@]} > 0)) || fail 'required jobs/workflows missing'
for job in "${jobs[@]}"; do [[ -n "$job" ]] || fail 'empty job name'; done
for wf in "${workflows[@]}"; do [[ "$wf" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || fail "invalid workflow name: $wf"; done
for tool in curl jq stat; do command -v "$tool" >/dev/null || fail "missing $tool"; done

[[ -n "$token_file" && -f "$token_file" && -r "$token_file" && ! -L "$token_file" ]] ||
  fail 'read-only GitHub token file is not configured'
perms="$(stat -c '%a' "$token_file")" || fail 'cannot read token file permissions'
[[ "$perms" =~ ^[0-7]{3,4}$ ]] || fail 'cannot validate token file permissions'
(( (8#$perms & 0077) == 0 )) || fail 'token file must not be readable by group or others (use chmod 600)'
token="$(tr -d '\r\n' < "$token_file")"
[[ "$token" =~ ^[A-Za-z0-9_]+$ ]] || fail 'token file is empty or malformed'

# One fixed host, one fixed repository; the token travels on stdin only.
api() {
  local path="$1" response
  response="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -fsS --retry 0 --connect-timeout 5 --max-time 25 --config - \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$API/repos/$repo/$path")" || fail "GitHub API unavailable for $path"
  jq -e . >/dev/null 2>&1 <<< "$response" || fail "invalid GitHub API response for $path"
  printf '%s\n' "$response"
}
main_head() { api 'git/ref/heads/main' | jq -r '.object.sha // empty'; }

# 1. Still main.
[[ "$(main_head)" == "$sha" ]] || fail 'SHA is not the current main head'

# 2. Merged-PR provenance.
api "commits/$sha/pulls?per_page=100" | jq -e --arg sha "$sha" '
  type == "array" and any(.[]; .merged_at != null and .base.ref == "main"
                              and .merge_commit_sha == $sha)' >/dev/null ||
  fail 'no merged main PR has this SHA as its merge commit'

# 3. Latest main-push run of each workflow is a success.
for wf in "${workflows[@]}"; do
  state="$(api "actions/workflows/$wf/runs?head_sha=$sha&event=push&per_page=100" | jq -r --arg sha "$sha" '
    if (.total_count | type) != "number" or .total_count > 100 then "truncated"
    else
      [.workflow_runs[] | select(.head_sha == $sha and .event == "push" and .head_branch == "main")]
      | sort_by(.created_at, (.run_attempt // 1))
      | if length == 0 then "missing"
        else last | if .status == "completed" then (.conclusion // "missing") else "pending" end
        end
    end')"
  [[ "$state" == success ]] || fail "workflow $wf on main push: $state"
done

# 4 and 5. Named exact-SHA check runs.
if ((sonar)); then jobs+=('SonarCloud Code Analysis'); fi
checks="$(api "commits/$sha/check-runs?per_page=100")"
jq -e --arg sha "$sha" '
  (.total_count | type) == "number" and .total_count == (.check_runs | length)
  and all(.check_runs[]; .head_sha == $sha)' >/dev/null <<< "$checks" ||
  fail 'truncated or inconsistent check-run response'
for job in "${jobs[@]}"; do
  jq -e --arg name "$job" '
    [.check_runs[] | select(.name == $name)] as $m
    | ($m | length) > 0 and all($m[]; .status == "completed" and .conclusion == "success")
  ' >/dev/null <<< "$checks" || fail "required check not green: $job"
done

# 6. Commit statuses: the latest state of every context must be success.
api "commits/$sha/status" | jq -e '
  (.statuses | type) == "array"
  and ([.statuses | group_by(.context)[] | sort_by(.updated_at // .created_at // "") | last]
       | all(.[]; .state == "success"))' >/dev/null ||
  fail 'a commit status context is failing or pending'

# 1 again: main must not have moved while we were checking.
[[ "$(main_head)" == "$sha" ]] || fail 'main moved during verification'
printf 'RELEASE ELIGIBLE: %s %s\n' "$repo" "$sha"
