# Triage Labels

The skills speak in five canonical triage roles. This repo uses the role names verbatim as its label
strings, so the mapping is the identity:

| Canonical role    | Label here        | Meaning                                  |
| ----------------- | ----------------- | ---------------------------------------- |
| `needs-triage`    | `needs-triage`    | Maintainer needs to evaluate this issue  |
| `needs-info`      | `needs-info`      | Waiting on reporter for more information |
| `ready-for-agent` | `ready-for-agent` | Fully specified, ready for an AFK agent  |
| `ready-for-human` | `ready-for-human` | Requires human implementation            |
| `wontfix`         | `wontfix`         | Will not be actioned                     |

When a skill names a role — "apply the AFK-ready triage label" — use the matching string above.

## These labels are new here

No issue in this repo carries any label today; the vocabulary arrives with `/triage`. Only `wontfix`
already exists, as a GitHub default ("This will not be worked on"). Create the other four before the
first triage pass:

```sh
gh label create needs-triage    --description "Maintainer needs to evaluate this issue"  --color FBCA04
gh label create needs-info      --description "Waiting on reporter for more information" --color D4C5F9
gh label create ready-for-agent --description "Fully specified, ready for an AFK agent"  --color 0E8A16
gh label create ready-for-human --description "Requires human implementation"            --color 1D76DB
```

Reuse `wontfix` as-is rather than creating a duplicate.

## `ready-for-agent` describes, it doesn't dispatch

No automation reads these labels. `ready-for-agent` records a judgment that the issue is specified well
enough for an AFK agent to pick up — applying it starts nothing. The repo's issue worker, which would
have run an agent at open time regardless of labels, is currently paused (see
[issue-tracker.md](./issue-tracker.md)).

## Labels triage doesn't own

Two other sets exist on the repo. Leave both alone:

- **Type labels** — `bug`, `enhancement`, `documentation`, `question`, `duplicate`, `invalid`,
  `good first issue`, `help wanted`. GitHub defaults describing *what* an issue is, orthogonal to the
  triage state above. An issue can carry one of each.
- **Bot-owned labels** — `autorelease: pending`, `autorelease: tagged` (release-please),
  `dependencies`, `github_actions` (dependabot). These are workflow state; editing them by hand
  desynchronizes the release pipeline.
