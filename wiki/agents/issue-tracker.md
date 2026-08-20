# Issue tracker: GitHub

Issues and specs live as GitHub issues on [`JINGBANZ/jarvis`](https://github.com/JINGBANZ/jarvis). Use
the `gh` CLI; it infers the repo from the clone you're standing in, so no `--repo` flag is needed —
including from a worktree under `.claude/worktrees/`.

## Opening an issue starts an agent — read this first

`.github/workflows/issue-worker.yml` fires on `issues: [opened]`. When the author has write, maintain, or
admin permission (you, running as the owner), an autonomous agent immediately picks the issue up,
implements it end to end, runs the suite, and opens a PR ending in `Fixes #<n>` — or, if the issue isn't
actionable as written, comments there explaining why instead. Nothing about this is opt-in and no label
gates it.

What that means for the skills:

- **Filing is executing.** There is no inbox here. Don't open an issue as a note-to-self, a placeholder,
  or a "let's discuss" — it will be built.
- **A batch of tickets is a batch of agents.** `/to-tickets` publishing eight issues starts eight
  concurrent runs and can produce eight PRs. Publish only tickets you want implemented now; hold the
  rest until you do.
- **`ready-for-agent` is a description, not a trigger.** The run already happened at open time. Applying
  the label later doesn't start one, and no triage label can call one back — cancel the workflow run
  instead.
- **Dependency order is advisory to the agents, not enforced.** They start together regardless of the
  blocking edges recorded below.

`.github/workflows/issue-opener.yml` also files an issue on its own, daily at 19:07 UTC (03:07 Beijing, UTC+8),
which then trips the worker. An unfamiliar recent issue may be its work, not yours.

## Operations

- **Create**: `gh issue create --title "..." --body "..."` — heredoc for multi-line bodies. See the
  warning above before you run it.
- **Read**: `gh issue view <number> --comments`
- **List**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`,
  adding `--label` / `--state` filters as needed.
- **Comment**: `gh issue comment <number> --body "..."`
- **Label**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

**"Publish to the issue tracker"** means create a GitHub issue. **"Fetch the relevant ticket"** means
`gh issue view <number> --comments`.

## Numbers are shared with PRs, and PRs dominate

GitHub draws issues and PRs from one sequence. This repo has 27 issues against 157 PRs, so an
unqualified `#142` is much more likely a PR. Resolve with `gh pr view <n>`, falling back to
`gh issue view <n>` — not the other way round.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo starts treating external PRs as feature
requests; `/triage` reads this flag.)_

Every PR here is the owner's or `github-actions[bot]`'s release-please PR, so there is nothing external
to triage. If that changes, `yes` runs PRs through the same labels and states as issues:

- **Read**: `gh pr view <number> --comments`, plus `gh pr diff <number>`.
- **List external PRs**: `authorAssociation` is not a `gh pr list --json` field — it exists only on the
  REST API, as `author_association`:
  ```sh
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq \
    '[.[] | select(.author_association == "CONTRIBUTOR" or .author_association == "FIRST_TIME_CONTRIBUTOR" or .author_association == "NONE")
        | {number, title, body, author: .user.login, labels: [.labels[].name]}]'
  ```
  That drops `OWNER`/`MEMBER`/`COLLABORATOR`. The payload carries no comments — read those per PR with
  `gh pr view <number> --comments`.
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`.

## Working an issue

The repo's own rules in [`../../AGENTS.md`](../../AGENTS.md) govern the change itself, not this file.
The ones that bite when closing an issue out: work in an isolated worktree, never commit to `main`,
[Conventional Commits](https://www.conventionalcommits.org/), run the Gate
(`swift build && ./scripts/run-tests.sh`) and show its output, and open a PR — which squash-merges with
the PR number in the subject.

Link the PR to its issue with `Fixes #<n>` in the body so the merge closes it.

## Wayfinding operations

Used by `/wayfinder`. The **map** is one issue; **child** issues are its tickets. Both GitHub features
this relies on — sub-issues and issue dependencies — are enabled on this repo, so use them rather than
any body-text fallback.

- **Map**: an issue labelled `wayfinder:map` holding the Notes / Decisions-so-far / Fog body:
  `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue attached to the map through the sub-issues endpoint, labelled
  `wayfinder:<type>` (`research` / `prototype` / `grilling` / `task`). Assigned to the driving dev once
  claimed.
- **Blocking**: native issue dependencies, which are UI-visible and machine-readable:
  ```sh
  gh api --method POST repos/{owner}/{repo}/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>
  ```
  `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/{owner}/{repo}/issues/<n> --jq .id`)
  — not its `#number`, not its `node_id`. Read the live gate back from
  `issue_dependencies_summary.blocked_by`, which counts open blockers only.
- **Frontier query**: the map's open children, minus any with `blocked_by > 0` or an assignee; first in
  map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me` — the session's first write.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, `gh issue close <n>`, then append a context
  pointer to the map's Decisions-so-far.

Remember that every child ticket you file starts its own agent run.
