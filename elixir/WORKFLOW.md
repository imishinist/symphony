---
tracker:
  kind: github
  provider:
    repo: "imishinist/symphony"
    token: $GITHUB_TOKEN
  required_labels:
    - symphony
  active_states:
    - open
  terminal_states:
    - closed
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/imishinist/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove --repo imishinist/symphony
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: >-
    codex --config shell_environment_policy.inherit=all
    --config 'permissions.symphony={extends=":workspace",filesystem={":workspace_roots"={".git"="write"}},network={enabled=true}}'
    --config 'default_permissions="symphony"'
    --config 'model="gpt-5.6-luna"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  permissions: symphony
---

You are working on a GitHub issue `{{ issue.identifier }}` in `imishinist/symphony`.

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. It may be a normal continuation or a retry after a failure.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat completed investigation or validation unless needed for new changes.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Number: {{ issue.id }}
Title: {{ issue.title }}
Current state: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Instructions

1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions.
2. Work only in the provided repository copy. Do not touch any other path.
3. Follow the repository's `AGENTS.md` instructions and required validation gates.
4. Only stop early for a true external blocker (missing required tools, auth, permissions, or secrets).
   Record blockers in the workpad before releasing the issue from the execution queue.
5. Final messages must report completed actions and blockers only. Do not include next steps for the user.

## Prerequisites and GitHub access

- Use the injected `github_api` tool for GitHub REST requests. A configured GitHub MCP server or
  authenticated `gh` CLI may be used when available.
- `github_api` uses Symphony's host-side authentication; tracker tokens are removed from the
  Codex child environment. Do not assume `GITHUB_TOKEN` or `GH_TOKEN` is available to shell commands.
- API paths use repository issue numbers (`{{ issue.id }}`), not identifiers such as `GH-42`.
- The repository is `imishinist/symphony`; the issue path is
  `/repos/imishinist/symphony/issues/{{ issue.id }}`.
- The `github_api` arguments are `method`, relative REST `path`, optional `params`, and optional JSON
  `body`. Check the returned status and body; handle pagination when listing comments or reviews.
- Git push requires working Git transport authentication separately from `github_api`. Try the
  documented repository authentication fallbacks before declaring publishing blocked.
- If all available access methods fail, preserve a concise blocker note in the local workspace.
  Update the workpad and release the queue label if issue writes remain available. If they do not,
  report the access blocker without claiming that remote updates succeeded.

## Queue and lifecycle

GitHub issue state is only `open` or `closed`. PR review and merge status determine the execution
phase; do not write custom issue states such as `In Progress` or `Human Review`.

- `open` with the `symphony` label: eligible for execution or continuation.
- `open` without `symphony`: outside the execution queue, including issues waiting for human review.
- `closed`: terminal; stop without implementation work.
- Keep the issue open during implementation and human review. Close it only after its PR is merged
  or a human explicitly closes it.
- At review handoff or an external blocker, update the workpad first, then remove only the issue's
  `symphony` label as the final remote operation. Label removal makes the issue ineligible and may
  stop the running agent during reconciliation. Preserve all other labels.
- A human re-adds `symphony` after requesting rework, approving a PR for merge, or resolving a blocker.
  On redispatch, re-read the existing PR and workpad to select the correct phase.
- Do not remove the PR's `symphony` label when releasing the issue from the execution queue.
- On retries, service restarts, or workspace recreation, recover progress from the issue workpad and
  linked PR before creating a branch or doing new implementation work.

## Related skills

- `commit`: produce clean, logical commits during implementation.
- `push`: keep the remote branch current and publish the PR.
- `pull`: merge the latest `origin/main` before implementation and handoff.
- `land`: after human approval, open and follow `.codex/skills/land/SKILL.md` until the PR is merged.
  Do not call `gh pr merge` directly. Use `github_api` for issue/comment operations if a skill refers
  to a different tracker.

## Step 0: Read current state and route

1. Fetch the issue by number, its labels, and all issue comments. If it is closed or no longer has
   `symphony`, stop without modifying it.
2. Find the single persistent comment headed `## Codex Workpad`. Reuse its comment ID for every
   progress update. GitHub issue comments do not have resolved/unresolved states.
3. Identify the linked PR from the workpad and issue timeline. Also check for an existing PR for
   the current branch. Verify that the PR belongs to this issue before reusing it.
4. Route according to the current PR state:
   - No PR: start or resume implementation.
   - Open PR with requested changes or actionable feedback: run the feedback/rework flow.
   - Open PR awaiting human approval: reconcile the workpad, then remove the issue queue label.
   - Open PR approved by a human, with no outstanding change requests: complete validation and the
     feedback sweep, then follow the `land` skill. Approval must apply to the latest changes;
     never treat a bot review or passing checks alone as human approval.
   - Merged PR: verify it completed this issue, update the workpad, then close the issue if needed.
   - Closed, unmerged PR: create a fresh branch from `origin/main` and restart from the current
     issue requirements. Do not reuse the closed PR's branch.
5. If no workpad exists and active work is needed, create it before analysis or implementation.
   If issue content and PR state disagree, record the discrepancy in that workpad and use the
   safest flow without merging or closing unfinished work.

## Step 1: Plan and reproduce

1. Update the workpad before new implementation work. Check off completed tasks and reconcile the
   plan, acceptance criteria, validation, blockers, and linked PR with current reality.
2. Include a compact environment stamp: `<host>:<abs-workdir>@<short-sha>`.
3. Write a hierarchical plan and explicit acceptance criteria as checkboxes.
   - Mirror issue-authored `Validation`, `Test Plan`, and `Testing` requirements as required checks.
   - For user-facing changes, include an end-to-end walkthrough of the changed interaction.
4. Review the plan for the smallest coherent design and material lifecycle risks.
5. Reproduce the current behavior before changing code; record a concrete command/output or stable
   observable effect in the workpad.
6. Use the `pull` skill to sync with `origin/main` before code edits. Record the merge source,
   result (`clean` or `conflicts resolved`), and resulting short `HEAD` SHA.
7. Create or reuse a branch dedicated to this issue. Recover an existing open PR branch after a
   workspace recreation instead of starting duplicate work.

## Step 2: Implement and validate

1. Implement the current workpad checklist, updating it after meaningful milestones.
2. Keep scope narrow. Record out-of-scope findings in the workpad; do not expand the implementation.
3. Run targeted tests while iterating, then all repository-required gates before handoff.
   - Execute every issue-provided validation/test-plan requirement.
   - For stateful changes, check startup, reload, restart, and failure recovery together.
   - Prove process health with synchronous calls or stable effects, not only a PID.
   - Revert temporary proof edits before committing.
4. Before every push, ensure required validation passes for the current changes.
5. Commit and push using the related skills. Create or update the PR with a body that follows the
   repository PR template and includes validation evidence.
6. Link the PR in the workpad and add an issue reference to the PR body (`Closes #{{ issue.id }}`
   when the PR fully resolves this issue). GitHub issue comments and Markdown links replace tracker
   attachment fields.
7. Ensure the PR has the `symphony` label; do not overwrite unrelated PR labels.
8. Merge the latest `origin/main` into the branch before handoff, resolve conflicts, and rerun the
   required checks after changes. Push any resulting commits and refresh the feedback sweep.
9. Reconcile every acceptance criterion and validation checkbox. Record the latest commit,
   validation results, PR URL, and any remaining blockers in the same workpad comment.

## PR feedback sweep (required)

Before review handoff and before merging:

1. Gather all feedback, including paginated results:
   - Top-level PR comments: `GET /repos/imishinist/symphony/issues/<pr>/comments`.
   - Inline review comments: `GET /repos/imishinist/symphony/pulls/<pr>/comments`.
   - Review summaries/states: `GET /repos/imishinist/symphony/pulls/<pr>/reviews`.
   - Check runs and commit statuses for the latest PR head SHA.
2. Treat every actionable human or bot comment as blocking until addressed in code/tests/docs or
   answered with explicit, justified pushback on the relevant thread.
3. Include each feedback item and its resolution in the workpad checklist.
4. Read any `Manual QA Plan` comment and use it to refine runtime/UI validation.
5. After feedback-driven edits, rerun required checks and push updates.
6. Repeat until no actionable comments remain and required checks pass for the latest head.

## Step 3: Human review and merge

1. Before review handoff, confirm:
   - Plan, acceptance criteria, and validation checklists accurately reflect completed work.
   - Required tests and PR checks pass for the latest commit.
   - All actionable PR feedback is resolved or explicitly answered.
   - The branch is pushed, the PR is linked, and its `symphony` label is present.
2. Update the workpad with a concise handoff note and PR link. Then remove the issue's `symphony`
   label to wait for human review; leave the issue open.
3. On redispatch after human feedback, run the feedback/rework flow. On redispatch after human
   approval, verify the approval and checks against the current PR head, then follow the `land`
   skill until the PR is merged.
4. After merge, update the workpad with the result, then close the issue if GitHub did not close it
   automatically. Never close the issue merely because a PR was opened or checks passed.

## Step 4: Feedback and rework

1. Re-read the issue, workpad, and all PR feedback. Record what needs to change before editing.
2. Reuse the open PR, its branch, and the persistent workpad. Do not discard progress or close an
   open PR solely because changes were requested.
3. Follow the implementation and feedback-sweep steps until requirements and checks pass.
4. Request a fresh human review after changes. Update the workpad and remove the issue queue label
   as the final remote operation; do not merge on an approval that predates required rework.

## External blockers

- Exhaust documented tool/authentication fallbacks first. Never claim a write, push, or validation
  succeeded without checking its result.
- If blocked, record what is missing, why it prevents completion, and the exact unblock condition
  in the workpad. Preserve the branch and partial work; do not close the issue.
- If issue writes work, remove the issue's `symphony` label only after the blocker note is saved.
  A human can requeue it once access or requirements are restored.
- Keep all progress, handoff, and blocker notes in the single workpad. Do not edit the issue body
  for planning or post separate completion-summary comments.

## GitHub REST operations

Use `github_api` with these relative paths and JSON bodies (all IDs below are numeric):

- Read issue: `GET /repos/imishinist/symphony/issues/{{ issue.id }}`.
- List workpad candidates: `GET /repos/imishinist/symphony/issues/{{ issue.id }}/comments`.
- Create workpad: `POST /repos/imishinist/symphony/issues/{{ issue.id }}/comments`,
  body `{"body": "## Codex Workpad\n..."}`.
- Edit workpad: `PATCH /repos/imishinist/symphony/issues/comments/<comment-id>`,
  body `{"body": "<full updated workpad>"}`.
- Release queue label: `DELETE /repos/imishinist/symphony/issues/{{ issue.id }}/labels/symphony`.
- Close completed issue: `PATCH /repos/imishinist/symphony/issues/{{ issue.id }}`,
  body `{"state": "closed", "state_reason": "completed"}`.

## Workpad template

Use this structure for the persistent comment, updating it in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1. Parent task
  - [ ] 1.1 Child task
- [ ] 2. Parent task

### Acceptance Criteria

- [ ] Criterion 1

### Validation

- [ ] Required checks: `<command>`

### PR

- None yet, or the linked PR URL.

### Notes

- <short progress note with timestamp>

### Blockers

- None, or the missing requirement and unblock condition.

### Confusions

- <include only when something was unclear during execution>
````
