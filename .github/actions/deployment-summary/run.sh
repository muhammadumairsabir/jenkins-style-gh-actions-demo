#!/usr/bin/env bash
set -euo pipefail

: "${INPUT_TITLE:=Deployment summary}"
: "${INPUT_ENVIRONMENT:?environment is required}"
: "${INPUT_TARGET_BRANCH:?target-branch is required}"
: "${INPUT_DEPLOYMENT_SUCCEEDED:?deployment-succeeded is required}"
: "${INPUT_INCLUDE_CHANGED_FILES:=true}"
: "${INPUT_MAX_CHANGED_FILES:=100}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

if ! [[ "$INPUT_MAX_CHANGED_FILES" =~ ^[0-9]+$ ]]; then
  echo "max-changed-files must be a non-negative integer" >&2
  exit 2
fi

slugify() {
  local value="$1"
  value="$(printf '%s' "$value" \
    | tr '[:upper:] ' '[:lower:]-' \
    | sed -E \
        -e 's/[^a-z0-9._/-]+/-/g' \
        -e 's#/{2,}#/#g' \
        -e 's#(^[./-]+|[./-]+$)##g')"

  if [[ -z "$value" ]]; then
    value="unknown"
  fi

  printf '%s' "$value"
}

escape_markdown_cell() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

ENV_SLUG="$(slugify "$INPUT_ENVIRONMENT")"
BRANCH_SLUG="$(slugify "$INPUT_TARGET_BRANCH")"
STATE_HASH="$(printf '%s' "${INPUT_ENVIRONMENT}|${INPUT_TARGET_BRANCH}" | sha256sum | cut -c1-12)"
STATE_TAG="deployment-state/${ENV_SLUG}/${BRANCH_SLUG}-${STATE_HASH}"
CURRENT_SHA="$(git rev-parse HEAD)"
CURRENT_SHORT="$(git rev-parse --short=7 "$CURRENT_SHA")"
CURRENT_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${CURRENT_SHA}"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

# The tag is mutable by design: it points to the revision from the most recent
# successful deployment for one environment + target-branch pair.
git fetch --force origin \
  "+refs/tags/${STATE_TAG}:refs/tags/${STATE_TAG}" \
  >/dev/null 2>&1 || true

BASE_SHA="$(git rev-parse --verify "refs/tags/${STATE_TAG}^{commit}" 2>/dev/null || true)"
BASE_SHORT=""
BASE_URL=""
DIFF_RANGE=""
COMPARE_URL=""
CHANGELOG_STATUS="first-deployment"
BASELINE_VALID=true

if [[ -n "$BASE_SHA" ]]; then
  BASE_SHORT="$(git rev-parse --short=7 "$BASE_SHA")"
  BASE_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${BASE_SHA}"
  DIFF_RANGE="${BASE_SHA}..${CURRENT_SHA}"
  COMPARE_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/compare/${BASE_SHA}...${CURRENT_SHA}"

  if [[ "$BASE_SHA" == "$CURRENT_SHA" ]]; then
    CHANGELOG_STATUS="no-changes"
  elif git merge-base --is-ancestor "$BASE_SHA" "$CURRENT_SHA"; then
    CHANGELOG_STATUS="changes-found"
  else
    CHANGELOG_STATUS="baseline-not-ancestor"
    BASELINE_VALID=false
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PR_FILE="$TMP_DIR/pull-requests.tsv"
DIRECT_FILE="$TMP_DIR/direct-commits.tsv"
UNKNOWN_FILE="$TMP_DIR/unclassified-commits.tsv"
CHANGED_FILE="$TMP_DIR/changed-files.tsv"
: > "$PR_FILE"
: > "$DIRECT_FILE"
: > "$UNKNOWN_FILE"
: > "$CHANGED_FILE"

COMMIT_COUNT=0
PR_COUNT=0
DIRECT_COUNT=0
UNKNOWN_COUNT=0
CHANGED_COUNT=0
ADDED_COUNT=0
MODIFIED_COUNT=0
DELETED_COUNT=0
RENAMED_COUNT=0
COPIED_COUNT=0

declare -A SEEN_PULL_REQUESTS=()

if [[ "$CHANGELOG_STATUS" == "changes-found" ]]; then
  mapfile -t FIRST_PARENT_COMMITS < <(
    git rev-list --first-parent --reverse "$DIFF_RANGE"
  )
  COMMIT_COUNT="${#FIRST_PARENT_COMMITS[@]}"

  git diff --name-status --find-renames --find-copies "$DIFF_RANGE" > "$CHANGED_FILE"

  CHANGED_COUNT="$(awk 'NF > 0 { n++ } END { print n + 0 }' "$CHANGED_FILE")"
  ADDED_COUNT="$(awk -F '\t' '$1 == "A" { n++ } END { print n + 0 }' "$CHANGED_FILE")"
  MODIFIED_COUNT="$(awk -F '\t' '$1 == "M" { n++ } END { print n + 0 }' "$CHANGED_FILE")"
  DELETED_COUNT="$(awk -F '\t' '$1 == "D" { n++ } END { print n + 0 }' "$CHANGED_FILE")"
  RENAMED_COUNT="$(awk -F '\t' '$1 ~ /^R/ { n++ } END { print n + 0 }' "$CHANGED_FILE")"
  COPIED_COUNT="$(awk -F '\t' '$1 ~ /^C/ { n++ } END { print n + 0 }' "$CHANGED_FILE")"

  for commit_sha in "${FIRST_PARENT_COMMITS[@]}"; do
    api_error="$TMP_DIR/api-error-${commit_sha}.txt"

    if ! pr_json="$(
      gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/repos/${GITHUB_REPOSITORY}/commits/${commit_sha}/pulls?per_page=100" \
        2>"$api_error"
    )"; then
      short_sha="$(git rev-parse --short=7 "$commit_sha")"
      subject="$(git show -s --format='%s' "$commit_sha")"
      printf '%s\t%s\n' "$short_sha" "$subject" >> "$UNKNOWN_FILE"
      UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
      continue
    fi

    matching_prs="$(
      jq -r --arg branch "$INPUT_TARGET_BRANCH" '
        .[]
        | select(.merged_at != null)
        | select(.base.ref == $branch)
        | [
            (.number | tostring),
            (.title | gsub("[\\t\\r\\n]"; " ")),
            .html_url,
            .user.login,
            .merged_at
          ]
        | @tsv
      ' <<< "$pr_json"
    )"

    commit_has_pr=false

    while IFS=$'\t' read -r pr_number pr_title pr_url pr_author pr_merged_at; do
      [[ -z "${pr_number:-}" ]] && continue
      commit_has_pr=true

      if [[ -z "${SEEN_PULL_REQUESTS[$pr_number]+present}" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$pr_number" "$pr_title" "$pr_url" "$pr_author" "$pr_merged_at" \
          >> "$PR_FILE"
        SEEN_PULL_REQUESTS["$pr_number"]=1
        PR_COUNT=$((PR_COUNT + 1))
      fi
    done <<< "$matching_prs"

    if [[ "$commit_has_pr" == "false" ]]; then
      short_sha="$(git rev-parse --short=7 "$commit_sha")"
      subject="$(git show -s --format='%s' "$commit_sha")"
      author="$(git show -s --format='%an' "$commit_sha")"
      commit_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${commit_sha}"
      printf '%s\t%s\t%s\t%s\n' \
        "$short_sha" "$subject" "$author" "$commit_url" \
        >> "$DIRECT_FILE"
      DIRECT_COUNT=$((DIRECT_COUNT + 1))
    fi
  done
fi

DEPLOYMENT_LABEL="failed"
if [[ "$INPUT_DEPLOYMENT_SUCCEEDED" == "true" ]]; then
  DEPLOYMENT_LABEL="succeeded"
fi

{
  echo "# ${INPUT_TITLE}"
  echo
  echo "## Deployment information"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Repository | \`${GITHUB_REPOSITORY}\` |"
  echo "| Environment | \`${INPUT_ENVIRONMENT}\` |"
  echo "| Target branch | \`${INPUT_TARGET_BRANCH}\` |"
  echo "| Deployment result | \`${DEPLOYMENT_LABEL}\` |"
  echo "| Current revision | [\`${CURRENT_SHORT}\`](${CURRENT_URL}) |"
  echo "| State tag | \`${STATE_TAG}\` |"
  echo "| Workflow run | [Open run](${RUN_URL}) |"

  if [[ -n "$BASE_SHA" ]]; then
    echo "| Previous successful revision | [\`${BASE_SHORT}\`](${BASE_URL}) |"
    echo "| Commit range | [\`${BASE_SHORT}..${CURRENT_SHORT}\`](${COMPARE_URL}) |"
  else
    echo "| Previous successful revision | Not initialized |"
  fi

  echo
  echo "## Changes since previous successful deployment"
  echo
} >> "$GITHUB_STEP_SUMMARY"

case "$CHANGELOG_STATUS" in
  first-deployment)
    {
      echo "> [!NOTE]"
      echo "> No successful deployment baseline exists yet for this environment and branch."
      echo "> A successful run will initialize the baseline at \`${CURRENT_SHORT}\`."
    } >> "$GITHUB_STEP_SUMMARY"
    ;;

  no-changes)
    echo "No commits have been introduced since the previous successful deployment." \
      >> "$GITHUB_STEP_SUMMARY"
    ;;

  baseline-not-ancestor)
    {
      echo "> [!WARNING]"
      echo "> The previous successful revision is not an ancestor of the current revision."
      echo "> The target branch may have been force-pushed or rewritten. The baseline will not be updated automatically."
    } >> "$GITHUB_STEP_SUMMARY"
    ;;

  changes-found)
    {
      echo "| Metric | Count |"
      echo "|---|---:|"
      echo "| First-parent commits | ${COMMIT_COUNT} |"
      echo "| Pull requests | ${PR_COUNT} |"
      echo "| Direct commits | ${DIRECT_COUNT} |"
      echo "| Unclassified commits | ${UNKNOWN_COUNT} |"
      echo "| Net changed files | ${CHANGED_COUNT} |"
      echo "| Added files | ${ADDED_COUNT} |"
      echo "| Modified files | ${MODIFIED_COUNT} |"
      echo "| Deleted files | ${DELETED_COUNT} |"
      echo "| Renamed files | ${RENAMED_COUNT} |"
      echo "| Copied files | ${COPIED_COUNT} |"
      echo
      echo "### Pull requests"
      echo
    } >> "$GITHUB_STEP_SUMMARY"

    if [[ ! -s "$PR_FILE" ]]; then
      echo "No associated pull requests were found for this range." >> "$GITHUB_STEP_SUMMARY"
    else
      {
        echo "| PR | Title | Author | Merged |"
        echo "|---:|---|---|---|"
      } >> "$GITHUB_STEP_SUMMARY"

      while IFS=$'\t' read -r pr_number pr_title pr_url pr_author pr_merged_at; do
        pr_title="$(escape_markdown_cell "$pr_title")"
        echo "| [#${pr_number}](${pr_url}) | ${pr_title} | @${pr_author} | \`${pr_merged_at}\` |" \
          >> "$GITHUB_STEP_SUMMARY"
      done < "$PR_FILE"
    fi

    {
      echo
      echo "### Direct commits"
      echo
    } >> "$GITHUB_STEP_SUMMARY"

    if [[ ! -s "$DIRECT_FILE" ]]; then
      echo "No direct commits were found." >> "$GITHUB_STEP_SUMMARY"
    else
      {
        echo "| Commit | Description | Author |"
        echo "|---|---|---|"
      } >> "$GITHUB_STEP_SUMMARY"

      while IFS=$'\t' read -r commit_short commit_subject commit_author commit_url; do
        commit_subject="$(escape_markdown_cell "$commit_subject")"
        commit_author="$(escape_markdown_cell "$commit_author")"
        echo "| [\`${commit_short}\`](${commit_url}) | ${commit_subject} | ${commit_author} |" \
          >> "$GITHUB_STEP_SUMMARY"
      done < "$DIRECT_FILE"
    fi

    if [[ -s "$UNKNOWN_FILE" ]]; then
      {
        echo
        echo "### Unclassified commits"
        echo
        echo "> [!WARNING]"
        echo "> GitHub's commit-to-pull-request API could not be queried for these commits, so they were not classified as PR or direct commits."
        echo
        echo "| Commit | Description |"
        echo "|---|---|"
      } >> "$GITHUB_STEP_SUMMARY"

      while IFS=$'\t' read -r commit_short commit_subject; do
        commit_subject="$(escape_markdown_cell "$commit_subject")"
        echo "| \`${commit_short}\` | ${commit_subject} |" >> "$GITHUB_STEP_SUMMARY"
      done < "$UNKNOWN_FILE"
    fi

    if [[ "$INPUT_INCLUDE_CHANGED_FILES" == "true" ]]; then
      {
        echo
        echo "### Changed files"
        echo
      } >> "$GITHUB_STEP_SUMMARY"

      if [[ ! -s "$CHANGED_FILE" ]]; then
        echo "No net file changes were found." >> "$GITHUB_STEP_SUMMARY"
      else
        {
          echo "| Status | File |"
          echo "|---|---|"
        } >> "$GITHUB_STEP_SUMMARY"

        rendered=0
        while IFS=$'\t' read -r file_status first_path second_path; do
          [[ -z "${file_status:-}" ]] && continue

          if (( rendered >= INPUT_MAX_CHANGED_FILES )); then
            break
          fi

          first_path="$(escape_markdown_cell "${first_path:-}")"
          second_path="$(escape_markdown_cell "${second_path:-}")"

          if [[ "$file_status" == R* || "$file_status" == C* ]]; then
            echo "| \`${file_status}\` | \`${first_path}\` → \`${second_path}\` |" \
              >> "$GITHUB_STEP_SUMMARY"
          else
            echo "| \`${file_status}\` | \`${first_path}\` |" \
              >> "$GITHUB_STEP_SUMMARY"
          fi

          rendered=$((rendered + 1))
        done < "$CHANGED_FILE"

        if (( CHANGED_COUNT > INPUT_MAX_CHANGED_FILES )); then
          echo >> "$GITHUB_STEP_SUMMARY"
          echo "Showing ${INPUT_MAX_CHANGED_FILES} of ${CHANGED_COUNT} changed files." \
            >> "$GITHUB_STEP_SUMMARY"
        fi
      fi
    fi
    ;;
esac

BASELINE_UPDATED=false
if [[ "$INPUT_DEPLOYMENT_SUCCEEDED" == "true" && "$BASELINE_VALID" == "true" ]]; then
  git tag --force "$STATE_TAG" "$CURRENT_SHA" >/dev/null
  git push origin "+refs/tags/${STATE_TAG}:refs/tags/${STATE_TAG}" >/dev/null
  BASELINE_UPDATED=true
fi

{
  echo
  echo "## Baseline result"
  echo

  if [[ "$BASELINE_UPDATED" == "true" ]]; then
    echo "The successful deployment baseline now points to [\`${CURRENT_SHORT}\`](${CURRENT_URL})."
  elif [[ "$INPUT_DEPLOYMENT_SUCCEEDED" != "true" ]]; then
    echo "The baseline was not updated because the deployment failed. The next run will compare against the same previous successful revision."
  else
    echo "The baseline was not updated because the previous revision is not an ancestor of the current revision."
  fi
} >> "$GITHUB_STEP_SUMMARY"
