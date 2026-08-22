# Issue tracker: GitHub

Issues and specs live as GitHub issues on [`JINGBANZ/jarvis`](https://github.com/JINGBANZ/jarvis). Use
the `gh` CLI; it infers the repo from the clone you're standing in, so no `--repo` flag is needed —
including from a worktree under `.claude/worktrees/`.

## Automation: the issue worker is paused

`.github/workflows/issue-worker.yml` fires on `issues: [opened]` and, for an author with write
permission, runs an agent that implements the issue end to end and opens a PR. **It is currently
disabled**, so filing an issue here just files it. Publish tickets freely.

The pause is repo state rather than a code change — the workflow file is untouched. `gh workflow list
--all` reports it as `disabled_manually`; `gh workflow enable "Issue Worker"` restores it. If it is ever
turned back on, filing becomes executing: a batch of tickets becomes a batch of concurrent agent runs
and PRs, started together regardless of any blocking edges between them. Re-read this section before
publishing in bulk if the status above has changed.

`.github/workflows/issue-opener.yml` is still active and files an issue on its own daily at 19:07 UTC
(03:07 Beijing, UTC+8). With the worker paused, those issues wait for someone to pick them up instead of
being worked automatically.

## Operations

- **Create**: `gh issue create --title "..." --body "..."` — heredoc for multi-line bodies.
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
