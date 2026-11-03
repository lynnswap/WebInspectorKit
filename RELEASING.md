# Releasing WebInspectorKit

The approved tag is created before the Release workflow validates the commit and publishes its draft. Failed or cancelled validation leaves the tag available and the draft unpublished. WebInspectorKit is distributed through its Git tag and GitHub's source archives; this workflow does not upload binary assets.

## Start a release

Review the version, title, notes, full target commit SHA, and automatic publication plan before starting. The workflow and `Scripts/release.py` must already be merged into `main`. Use Python 3, Git, and a GitHub CLI authenticated with permission to create releases and dispatch workflows:

```sh
python3 Scripts/release.py start v0.8.0 \
  --repo lynnswap/WebInspectorKit \
  --target <full-40-character-commit-sha> \
  --notes-file /path/to/release-notes.md
```

Replace the example values with the approved release. The title defaults to the version; use `--title` to override it or `--prerelease` for a prerelease.

The command creates a draft and tag pinned to the full SHA, or reuses them when their targets and content match. The tag makes the approved version available to package consumers immediately. It then dispatches `release.yml` from `main` with the draft ID, target SHA, and a fingerprint of the approved publication fields. It reports the draft URL, tag, and dispatch acceptance without waiting for publication. Saving a draft in GitHub's UI alone does not create a tag or start Actions.

## Validation and publication

The Release workflow replaces the former Release Validation workflow and keeps its full Native runtime coverage. It calls the shared CI with `all_native_runtimes: true`: Native compatibility tests run on every supported installed runtime, and workspace tests run on the latest OS. Both test paths check out the approved SHA. CI script tests run at the workflow's revision so they cover the publication automation in use. Separate release runs do not cancel each other's CI.

Only the final publish job has `contents: write`, and it runs the release script from the workflow's `main` commit. Tests receive no release secret. Publication uses `GITHUB_TOKEN` by default.

Before publication, the script checks the draft's target, tag name, title, notes, and prerelease state against the approved content. Uploaded assets are rejected because this is a source-only release. The existing lightweight or annotated tag must resolve to the tested SHA; publication does not create or move tags. The same draft is then published with the approved metadata explicitly supplied, preserving the notes and prerelease state. Stable releases use GitHub's legacy latest-release selection; prereleases are not marked latest.

Do not edit the draft, upload assets, or move its tag while checks run. GitHub does not provide a transaction covering tag references, assets, and release publication, so maintainers must serialize those external operations.

## Recover a failed release

- If tag creation fails, update the caller's GitHub CLI credentials or address the tag rule failure, then repeat the same start command. A matching draft is reused.
- If dispatch fails or its response is uncertain, inspect [Release workflow runs](https://github.com/lynnswap/WebInspectorKit/actions/workflows/release.yml) before retrying: GitHub may have accepted the request. The matching tag and draft remain available.
- If validation fails or is cancelled, address the failure and use GitHub's re-run controls. A change to the release target or approved metadata requires a newly reviewed invocation; an old run will not publish changed content.
- If publication fails, the correct tag and draft remain. Re-run the failed publish job to resume without moving the tag. Re-running an already successful publication is a no-op.
- Tag creation uses the caller's authenticated GitHub CLI credentials. For historical commits whose workflow files differ from current branch tips, these credentials need **Contents: write** and **Workflows: write**, or the classic `repo` and `workflow` scopes. Update those credentials and repeat the same start command if GitHub rejects tag creation. Repository tag rules still apply. See [GitHub's reference-creation permissions](https://docs.github.com/en/rest/git/refs#create-a-reference).

## Verify changes to the release flow

These checks exercise the release protocol with an in-memory GitHub service and lint the workflows without creating releases, tags, or workflow runs:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .github/scripts/tests -p 'test_*.py'
actionlint
git diff --check
```
