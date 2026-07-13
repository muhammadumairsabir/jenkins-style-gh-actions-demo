#!/usr/bin/env bash

set -euo pipefail

: "${INPUT_TITLE:?title is required}"
: "${INPUT_ENVIRONMENT:?environment is required}"
: "${INPUT_TARGET_BRANCH:?target-branch is required}"
: "${INPUT_GITHUB_TOKEN:?github-token is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"

REPOSITORY_PATH="${GITHUB_WORKSPACE}/${INPUT_REPOSITORY_PATH:-source}"
REPORT_DIR="${GITHUB_WORKSPACE}/${INPUT_REPORT_DIR:-deploy-reports}"
STATE_PREFIX="${INPUT_STATE_PREFIX:-poc-deployment-state}"
UPDATE_BASELINE="${INPUT_UPDATE_BASELINE:-true}"
INCLUDE_CHANGED_FILES="${INPUT_INCLUDE_CHANGED_FILES:-true}"
INCLUDE_DEPLOY_LOG="${INPUT_INCLUDE_DEPLOY_LOG:-true}"
DEPLOY_LOG_LINES="${INPUT_DEPLOY_LOG_LINES:-100}"

mkdir -p "$REPORT_DIR"

# A failed actions/checkout invocation can leave a .git directory behind without
# a valid checked-out commit. Validate HEAD itself rather than only testing for
# the existence of .git. The summary step uses if: always(), so it must remain
# capable of reporting an earlier checkout failure without masking that failure
# with "ambiguous argument HEAD".
if ! git -C "$REPOSITORY_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1   || ! git -C "$REPOSITORY_PATH" rev-parse --verify HEAD >/dev/null 2>&1; then
  DEPLOY_STATUS="$(cat "$REPORT_DIR/deploy-status.txt" 2>/dev/null || echo failed)"
  SSH_AGENT_STATUS="$(cat "$REPORT_DIR/ssh-agent-status.txt" 2>/dev/null || echo unknown)"
  RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

  {
    echo "# ${INPUT_TITLE}"
    echo ""
    echo "## Included in This Deployment"
    echo ""
    echo "> [!WARNING]"
    echo "> The target branch was not checked out successfully, so commits and pull requests cannot be calculated."
    echo "> Review the earlier **Verify target branch** and **Checkout target branch** steps."
    echo ""
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Environment | \`${INPUT_ENVIRONMENT}\` |"
    echo "| Target branch | \`${INPUT_TARGET_BRANCH}\` |"
    echo "| Repository path | \`${INPUT_REPOSITORY_PATH:-source}\` |"
    echo "| Checkout status | \`unavailable\` |"
    echo ""
    echo "## Status"
    echo ""
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Job Status | \`${DEPLOY_STATUS}\` |"
    echo "| SSH Agent Status | \`${SSH_AGENT_STATUS}\` |"
    echo "| Workflow Run | [Open run](${RUN_URL}) |"
  } >> "$GITHUB_STEP_SUMMARY"

  if [[ "$INCLUDE_DEPLOY_LOG" == "true" && -f "$REPORT_DIR/deploy.log" ]]; then
    {
      echo ""
      echo "## Log"
      echo ""
      printf '%s\n' '```text'
      tail -n "$DEPLOY_LOG_LINES" "$REPORT_DIR/deploy.log" || true
      printf '%s\n' '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  echo "::warning::Target checkout is unavailable at $REPOSITORY_PATH. The summary was generated without Git changes."
  exit 0
fi

cd "$REPOSITORY_PATH"

sanitize_ref_component() {
  printf '%s' "$1" \
    | tr '[:upper:] ' '[:lower:]-' \
    | sed -E \
        -e 's/[^a-z0-9._/-]+/-/g' \
        -e 's#/{2,}#/#g' \
        -e 's#(^[./-]+|[./-]+$)##g'
}

sanitize_table_text() {
  local value="$1"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

ENV_SLUG="$(sanitize_ref_component "$INPUT_ENVIRONMENT")"
BRANCH_SLUG="$(sanitize_ref_component "$INPUT_TARGET_BRANCH")"
STATE_TAG="${STATE_PREFIX}/${ENV_SLUG}/${BRANCH_SLUG}"
STATE_REF="refs/tags/${STATE_TAG}"

DEPLOY_STATUS="$(cat "$REPORT_DIR/deploy-status.txt" 2>/dev/null || echo unknown)"
SSH_AGENT_STATUS="$(cat "$REPORT_DIR/ssh-agent-status.txt" 2>/dev/null || echo unknown)"

if [[ -s "$REPORT_DIR/deployed-sha.txt" ]]; then
  CURRENT_SHA="$(tr -d '[:space:]' < "$REPORT_DIR/deployed-sha.txt")"
else
  CURRENT_SHA="$(git rev-parse HEAD)"
fi

if ! git cat-file -e "${CURRENT_SHA}^{commit}" 2>/dev/null; then
  echo "::error::Current deployed SHA is not available locally: $CURRENT_SHA"
  exit 2
fi

CURRENT_SHORT_SHA="$(git rev-parse --short=7 "$CURRENT_SHA")"
CURRENT_COMMIT_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${CURRENT_SHA}"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

# Read the previous successful deployment marker for this environment and branch.
git fetch --no-tags origin \
  "+${STATE_REF}:${STATE_REF}" \
  >/dev/null 2>&1 || true

PREVIOUS_SHA="$(git rev-parse --verify "${STATE_REF}^{commit}" 2>/dev/null || true)"
PREVIOUS_SHORT_SHA=""
DIFF_RANGE=""
CHANGESET_STATUS="first-deployment"

PR_FILE="$REPORT_DIR/included-prs.tsv"
COMMIT_FILE="$REPORT_DIR/included-commits.tsv"
DIRECT_COMMIT_FILE="$REPORT_DIR/direct-commits.tsv"
CHANGES_FILE="$REPORT_DIR/changed-files.tsv"
COUNTS_FILE="$REPORT_DIR/change-counts.env"

: > "$PR_FILE"
: > "$COMMIT_FILE"
: > "$DIRECT_COMMIT_FILE"
: > "$CHANGES_FILE"

TOTAL=0
ADDED=0
MODIFIED=0
DELETED=0
RENAMED=0
COPIED=0
PR_COUNT=0
COMMIT_COUNT=0
DIRECT_COMMIT_COUNT=0

if [[ -n "$PREVIOUS_SHA" ]]; then
  PREVIOUS_SHORT_SHA="$(git rev-parse --short=7 "$PREVIOUS_SHA")"
  DIFF_RANGE="${PREVIOUS_SHA}..${CURRENT_SHA}"

  if git merge-base --is-ancestor "$PREVIOUS_SHA" "$CURRENT_SHA"; then
    CHANGESET_STATUS="success"

    git diff \
      --name-status \
      --find-renames \
      --find-copies \
      "$DIFF_RANGE" > "$CHANGES_FILE"

    TOTAL="$(awk 'NF > 0 { count++ } END { print count + 0 }' "$CHANGES_FILE")"
    ADDED="$(awk -F '\t' '$1 == "A" { count++ } END { print count + 0 }' "$CHANGES_FILE")"
    MODIFIED="$(awk -F '\t' '$1 == "M" { count++ } END { print count + 0 }' "$CHANGES_FILE")"
    DELETED="$(awk -F '\t' '$1 == "D" { count++ } END { print count + 0 }' "$CHANGES_FILE")"
    RENAMED="$(awk -F '\t' '$1 ~ /^R/ { count++ } END { print count + 0 }' "$CHANGES_FILE")"
    COPIED="$(awk -F '\t' '$1 ~ /^C/ { count++ } END { print count + 0 }' "$CHANGES_FILE")"

    mapfile -t ALL_COMMITS < <(git rev-list --reverse "$DIFF_RANGE")
    mapfile -t FIRST_PARENT_COMMITS < <(git rev-list --first-parent --reverse "$DIFF_RANGE")

    COMMIT_COUNT="${#ALL_COMMITS[@]}"

    for commit_sha in "${ALL_COMMITS[@]}"; do
      short_sha="$(git rev-parse --short=7 "$commit_sha")"
      subject="$(git show -s --format='%s' "$commit_sha")"
      author="$(git show -s --format='%an' "$commit_sha")"
      commit_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${commit_sha}"

      subject="${subject//$'\t'/ }"
      subject="${subject//$'\r'/ }"
      subject="${subject//$'\n'/ }"
      author="${author//$'\t'/ }"

      printf '%s\t%s\t%s\t%s\n' \
        "$short_sha" "$subject" "$author" "$commit_url" \
        >> "$COMMIT_FILE"
    done

    declare -A SEEN_PULL_REQUESTS=()

    for commit_sha in "${FIRST_PARENT_COMMITS[@]}"; do
      api_url="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/commits/${commit_sha}/pulls?per_page=100"

      if ! response="$(
        curl --fail --silent --show-error --location \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "$api_url"
      )"; then
        echo "::warning::Could not resolve pull requests for commit ${commit_sha}."
        response='[]'
      fi

      matching_prs="$(
        RESPONSE="$response" TARGET_BRANCH="$INPUT_TARGET_BRANCH" python3 - <<'PY'
import json
import os

try:
    payload = json.loads(os.environ["RESPONSE"])
except (KeyError, json.JSONDecodeError):
    payload = []

target = os.environ["TARGET_BRANCH"]

for pr in payload if isinstance(payload, list) else []:
    base = (pr.get("base") or {}).get("ref")
    if not pr.get("merged_at") or base != target:
        continue

    fields = [
        str(pr.get("number", "")),
        str(pr.get("title", "")).replace("\t", " ").replace("\r", " ").replace("\n", " "),
        str(pr.get("html_url", "")),
        str((pr.get("user") or {}).get("login", "unknown")),
        str(pr.get("merged_at", "")),
    ]
    print("\t".join(fields))
PY
      )"

      commit_has_pr=false

      while IFS=$'\t' read -r pr_number pr_title pr_url pr_author pr_merged_at; do
        [[ -z "${pr_number:-}" ]] && continue
        commit_has_pr=true

        if [[ -n "${SEEN_PULL_REQUESTS[$pr_number]+exists}" ]]; then
          continue
        fi

        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$pr_number" "$pr_title" "$pr_url" "$pr_author" "$pr_merged_at" \
          >> "$PR_FILE"

        SEEN_PULL_REQUESTS["$pr_number"]=1
      done <<< "$matching_prs"

      if [[ "$commit_has_pr" == "false" ]]; then
        short_sha="$(git rev-parse --short=7 "$commit_sha")"
        subject="$(git show -s --format='%s' "$commit_sha")"
        author="$(git show -s --format='%an' "$commit_sha")"
        commit_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${commit_sha}"

        subject="${subject//$'\t'/ }"
        subject="${subject//$'\r'/ }"
        subject="${subject//$'\n'/ }"
        author="${author//$'\t'/ }"

        printf '%s\t%s\t%s\t%s\n' \
          "$short_sha" "$subject" "$author" "$commit_url" \
          >> "$DIRECT_COMMIT_FILE"
      fi
    done

    PR_COUNT="$(awk 'NF > 0 { count++ } END { print count + 0 }' "$PR_FILE")"
    DIRECT_COMMIT_COUNT="$(awk 'NF > 0 { count++ } END { print count + 0 }' "$DIRECT_COMMIT_FILE")"
  else
    CHANGESET_STATUS="baseline-not-ancestor"
  fi
fi

cat > "$COUNTS_FILE" <<EOF
TOTAL=$TOTAL
ADDED=$ADDED
MODIFIED=$MODIFIED
DELETED=$DELETED
RENAMED=$RENAMED
COPIED=$COPIED
EOF

printf '%s\n' "${DIFF_RANGE:-No previous successful deployment}" > "$REPORT_DIR/diff-range.txt"
printf '%s\n' "$CHANGESET_STATUS" > "$REPORT_DIR/changed-files-status.txt"

{
  echo "# ${INPUT_TITLE}"
  echo ""
  echo "## Included in This Deployment"
  echo ""
} >> "$GITHUB_STEP_SUMMARY"

if [[ "$CHANGESET_STATUS" == "first-deployment" ]]; then
  {
    echo "> [!NOTE]"
    echo "> No previous successful deployment exists for environment \`${INPUT_ENVIRONMENT}\` and branch \`${INPUT_TARGET_BRANCH}\`."
    echo "> A successful run will establish the first baseline."
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
elif [[ "$CHANGESET_STATUS" == "baseline-not-ancestor" ]]; then
  {
    echo "> [!WARNING]"
    echo "> The previous deployment revision is not an ancestor of the current revision."
    echo "> The branch may have been force-pushed or rewritten, so a reliable changeset cannot be displayed."
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
fi

{
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Environment | \`${INPUT_ENVIRONMENT}\` |"
  echo "| Target branch | \`${INPUT_TARGET_BRANCH}\` |"
  echo "| State tag | \`${STATE_TAG}\` |"

  if [[ -n "$PREVIOUS_SHA" ]]; then
    previous_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${PREVIOUS_SHA}"
    echo "| Previous successful deployment | [\`${PREVIOUS_SHORT_SHA}\`](${previous_url}) |"
  else
    echo "| Previous successful deployment | Not available |"
  fi

  echo "| Current deployed commit | [\`${CURRENT_SHORT_SHA}\`](${CURRENT_COMMIT_URL}) |"
  echo "| Pull requests included | **${PR_COUNT}** |"
  echo "| Commits included | **${COMMIT_COUNT}** |"
  echo "| Direct branch commits | **${DIRECT_COMMIT_COUNT}** |"

  if [[ -n "$PREVIOUS_SHA" ]]; then
    compare_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/compare/${PREVIOUS_SHA}...${CURRENT_SHA}"
    echo "| Comparison | [Open comparison](${compare_url}) |"
  fi

  echo ""
} >> "$GITHUB_STEP_SUMMARY"

if [[ "$CHANGESET_STATUS" == "success" ]]; then
  echo "### Pull Requests" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"

  if [[ "$PR_COUNT" -eq 0 ]]; then
    echo "No pull requests targeting \`${INPUT_TARGET_BRANCH}\` were included." >> "$GITHUB_STEP_SUMMARY"
    echo "" >> "$GITHUB_STEP_SUMMARY"
  else
    {
      echo "| PR | Title | Author | Merged |"
      echo "|---:|---|---|---|"
    } >> "$GITHUB_STEP_SUMMARY"

    while IFS=$'\t' read -r pr_number pr_title pr_url pr_author pr_merged_at; do
      [[ -z "${pr_number:-}" ]] && continue
      pr_title="$(sanitize_table_text "$pr_title")"
      echo "| [#${pr_number}](${pr_url}) | ${pr_title} | @${pr_author} | \`${pr_merged_at}\` |" \
        >> "$GITHUB_STEP_SUMMARY"
    done < "$PR_FILE"

    echo "" >> "$GITHUB_STEP_SUMMARY"
  fi

  echo "### Commits" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"

  if [[ "$COMMIT_COUNT" -eq 0 ]]; then
    echo "No commits were introduced since the previous successful deployment." >> "$GITHUB_STEP_SUMMARY"
    echo "" >> "$GITHUB_STEP_SUMMARY"
  else
    {
      echo "| Commit | Description | Author |"
      echo "|---|---|---|"
    } >> "$GITHUB_STEP_SUMMARY"

    while IFS=$'\t' read -r commit_short subject author commit_url; do
      [[ -z "${commit_short:-}" ]] && continue
      subject="$(sanitize_table_text "$subject")"
      author="$(sanitize_table_text "$author")"
      echo "| [\`${commit_short}\`](${commit_url}) | ${subject} | ${author} |" \
        >> "$GITHUB_STEP_SUMMARY"
    done < "$COMMIT_FILE"

    echo "" >> "$GITHUB_STEP_SUMMARY"
  fi

  if [[ "$DIRECT_COMMIT_COUNT" -gt 0 ]]; then
    {
      echo "### Direct Branch Commits"
      echo ""
      echo "| Commit | Description | Author |"
      echo "|---|---|---|"
    } >> "$GITHUB_STEP_SUMMARY"

    while IFS=$'\t' read -r commit_short subject author commit_url; do
      [[ -z "${commit_short:-}" ]] && continue
      subject="$(sanitize_table_text "$subject")"
      author="$(sanitize_table_text "$author")"
      echo "| [\`${commit_short}\`](${commit_url}) | ${subject} | ${author} |" \
        >> "$GITHUB_STEP_SUMMARY"
    done < "$DIRECT_COMMIT_FILE"

    echo "" >> "$GITHUB_STEP_SUMMARY"
  fi
fi

{
  echo "## Build Information"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Repository | \`${GITHUB_REPOSITORY}\` |"
  echo "| Workflow | \`${GITHUB_WORKFLOW}\` |"
  echo "| Run Number | \`#${GITHUB_RUN_NUMBER}\` |"
  echo "| Environment | \`${INPUT_ENVIRONMENT}\` |"
  echo "| Target Branch | \`${INPUT_TARGET_BRANCH}\` |"
  echo "| Workflow Ref | \`${GITHUB_REF_NAME}\` |"
  echo "| Deployed Commit | [\`${CURRENT_SHORT_SHA}\`](${CURRENT_COMMIT_URL}) |"
  echo "| Triggered By | \`${GITHUB_ACTOR}\` |"
  echo "| Workflow Run | [Open run](${RUN_URL}) |"
  echo ""
  echo "## Status"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Job Status | \`${DEPLOY_STATUS}\` |"
  echo "| SSH Agent Status | \`${SSH_AGENT_STATUS}\` |"
  echo "| Changed Files Status | \`${CHANGESET_STATUS}\` |"
  echo ""
  echo "## Git Change Summary"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Diff Range | \`${DIFF_RANGE:-not available}\` |"
  echo ""
  echo "| Type | Count |"
  echo "|---|---:|"
  echo "| Total changed files | ${TOTAL} |"
  echo "| Added | ${ADDED} |"
  echo "| Modified | ${MODIFIED} |"
  echo "| Deleted | ${DELETED} |"
  echo "| Renamed | ${RENAMED} |"
  echo "| Copied | ${COPIED} |"
} >> "$GITHUB_STEP_SUMMARY"

if [[ "$INCLUDE_CHANGED_FILES" == "true" ]]; then
  {
    echo ""
    echo "## Changed Files"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"

  if [[ ! -s "$CHANGES_FILE" ]]; then
    echo "No changed files detected or no previous successful baseline exists." >> "$GITHUB_STEP_SUMMARY"
  else
    {
      echo "| Status | File |"
      echo "|---|---|"
    } >> "$GITHUB_STEP_SUMMARY"

    while IFS=$'\t' read -r status file extra; do
      [[ -z "${status:-}" || -z "${file:-}" ]] && continue
      file="$(sanitize_table_text "$file")"
      extra="$(sanitize_table_text "${extra:-}")"

      if [[ "$status" == R* || "$status" == C* ]]; then
        echo "| \`${status}\` | \`${file}\` → \`${extra}\` |" >> "$GITHUB_STEP_SUMMARY"
      else
        echo "| \`${status}\` | \`${file}\` |" >> "$GITHUB_STEP_SUMMARY"
      fi
    done < "$CHANGES_FILE"
  fi
fi

if [[ "$INCLUDE_DEPLOY_LOG" == "true" && -f "$REPORT_DIR/deploy.log" ]]; then
  {
    echo ""
    echo "## Log"
    echo ""
    printf '%s\n' '```text'
    tail -n "$DEPLOY_LOG_LINES" "$REPORT_DIR/deploy.log" || true
    printf '%s\n' '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

# The tag moves only after the deployment itself succeeded.
if [[ "$UPDATE_BASELINE" == "true" ]]; then
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git tag --force "$STATE_TAG" "$CURRENT_SHA"

    if git push origin "+${STATE_REF}:${STATE_REF}"; then
      {
        echo ""
        echo "> [!TIP]"
        echo "> Successful-deployment baseline updated to \`${CURRENT_SHORT_SHA}\`."
      } >> "$GITHUB_STEP_SUMMARY"
    else
      {
        echo ""
        echo "> [!WARNING]"
        echo "> Deployment succeeded, but the baseline tag could not be updated. Check workflow token permissions."
      } >> "$GITHUB_STEP_SUMMARY"
      exit 1
    fi
  else
    {
      echo ""
      echo "> [!NOTE]"
      echo "> Deployment did not succeed. The previous successful baseline was retained."
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi
