# Jenkins-style main deployment summary

This demo uses one manually dispatched workflow. The baseline is the `head_sha` of the previous successful run of the same workflow on `main`.

## Install

Copy `.github/workflows/main-deployment-summary.yml` to the `main` branch and push it.

## Required test order

### 1. Establish the initial successful baseline

Run the workflow before merging any demo feature into `main`:

```bash
gh workflow run main-deployment-summary.yml \
  --ref main \
  -f deployment_result=success

gh run watch --exit-status
```

The first summary reports that no previous successful baseline exists.

### 2. Create five feature branches from the current main SHA

```bash
git switch main
git pull --ff-only origin main
BASE_SHA="$(git rev-parse HEAD)"

for i in 1 2 3 4 5; do
  BRANCH="feat/demo-${i}"
  git switch --create "$BRANCH" "$BASE_SHA"
  mkdir -p demo-features
  printf 'feature %s\n' "$i" > "demo-features/feature-${i}.txt"
  git add "demo-features/feature-${i}.txt"
  git commit -m "Add demo feature ${i}"
  git push --set-upstream origin "$BRANCH"
done

git switch main
```

Do not delete these feature branches after the `dev` or `staging` merges.

### 3. Merge all five feature PRs into dev

```bash
for i in 1 2 3 4 5; do
  PR_URL="$(
    gh pr create \
      --base dev \
      --head "feat/demo-${i}" \
      --title "Feature ${i} for dev" \
      --body "Demo validation of feature ${i} in dev."
  )"

  gh pr merge "$PR_URL" --merge
done
```

### 4. Merge all five feature PRs into staging

```bash
for i in 1 2 3 4 5; do
  PR_URL="$(
    gh pr create \
      --base staging \
      --head "feat/demo-${i}" \
      --title "Feature ${i} for staging" \
      --body "Demo validation of feature ${i} in staging."
  )"

  gh pr merge "$PR_URL" --merge
done
```

### 5. Merge all five feature PRs into main

```bash
for i in 1 2 3 4 5; do
  PR_URL="$(
    gh pr create \
      --base main \
      --head "feat/demo-${i}" \
      --title "Feature ${i} for production" \
      --body "Demo production promotion of feature ${i}."
  )"

  gh pr merge "$PR_URL" --merge
done
```

Do not run the deployment workflow between these five main merges.

### 6. Run one successful main deployment

```bash
gh workflow run main-deployment-summary.yml \
  --ref main \
  -f deployment_result=success

gh run watch --exit-status
```

Expected summary:

```text
PRs merged into main: 5
Direct commits: 0
Net changed files: 5
```

Only the five PRs whose base branch is `main` are shown. The ten corresponding PRs into `dev` and `staging` are excluded.

### 7. Verify a no-change deployment

Run the workflow again without merging anything:

```bash
gh workflow run main-deployment-summary.yml \
  --ref main \
  -f deployment_result=success
```

Expected:

```text
PRs merged into main: 0
Direct commits: 0
Net changed files: 0
```

### 8. Verify failed deployment retention

Create and merge one more PR into main, then intentionally fail the deployment:

```bash
git switch main
git pull --ff-only origin main
git switch --create feat/demo-failed-deployment

echo 'failed deployment test' > demo-features/failed-deployment.txt
git add demo-features/failed-deployment.txt
git commit -m 'Add failed deployment test feature'
git push --set-upstream origin feat/demo-failed-deployment

PR_URL="$(
  gh pr create \
    --base main \
    --head feat/demo-failed-deployment \
    --title 'Feature retained after failed deployment' \
    --body 'Tests the previous-successful-run baseline.'
)"

gh pr merge "$PR_URL" --merge

gh workflow run main-deployment-summary.yml \
  --ref main \
  -f deployment_result=failure
```

The failed run displays that PR, but it does not become the next baseline. Run the workflow successfully:

```bash
gh workflow run main-deployment-summary.yml \
  --ref main \
  -f deployment_result=success
```

The same PR must appear again. This confirms that the comparison starts at the previous successful deployment, not the previous attempted deployment.

## Important behavior

Do not add a normal `push` trigger to this test workflow when testing the five-PR batch. A push workflow would run after every separate PR merge into `main`, so each successful run would normally advance the baseline and report only the newly merged PR.
