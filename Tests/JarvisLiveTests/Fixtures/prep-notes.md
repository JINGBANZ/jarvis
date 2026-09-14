# Interview prep notes

These are my own notes for behavioral questions. Every person named here is fictional.

## Disagreement with a teammate

### Situation

On the payments team, my teammate Priya wanted to rewrite the billing retry job in Go. The job
kept charging some customers twice after a timeout, and she believed the Python worker was too
slow and too tangled to fix.

### What I did

I agreed the worker was messy, but I argued that the duplicates came from the idempotency key,
not from the language. The key was built from the invoice id and the retry timestamp, so every
retry looked like a brand new charge to the payment provider.

I proposed that we fix the idempotency key in the existing Python worker first and hold the
rewrite until we had numbers. Priya was skeptical, so we agreed on a one-week spike with a
clear measure: the duplicate-charge rate from the billing dashboard.

I paired with Priya on the change so the fix was hers as much as mine. We kept the key stable
across retries and added a test that replays a timeout twice.

### Result

The duplicate-charge rate fell from 0.4% to 0.01% within the week. We dropped the rewrite,
and Priya later led the cleanup of the worker's retry loop. The lesson I took away is to agree
on the measurement before arguing about the solution.

## Pushing back on my manager

### Situation

My manager, Marcus Webb, wanted to ship the offline sync feature for a Friday launch. Marketing
had already scheduled the announcement.

### What I did

Our soak test had surfaced three open data-loss bugs. In each one, edits made offline were
silently dropped when two devices synced at the same time. I brought Marcus the three bug
reports with the reproduction steps and the number of affected test accounts.

I did not ask to cancel the launch. I proposed shipping the feature behind a feature flag and
running a two-week staged rollout, starting with internal accounts and then five percent of
users, with a rollback plan for each stage.

### Result

Marcus took the plan to marketing, and the launch slipped by one week. We fixed all three bugs
during the first stage of the rollout. The feature reached every user with zero data-loss
incidents.

## Values

- I push back with evidence and a concrete alternative, not just an objection.
- I agree on how we will measure success before we pick a solution.
- I would rather slip a date than lose a customer's data.
- Once a decision is made, I commit to it fully, even when I argued for something else.
