# Interview prep notes

These are my own notes for behavioral questions. Every person named here is fictional.

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

## Framing

When a question asks about a disagreement with a teammate, I open with the shared goal we both wanted, so the conflict reads as two good engineers weighing tradeoffs rather than a fight. I name the teammate once, describe their position fairly, and say what they got right before I explain where I disagreed. The story should show how the disagreement was settled: what we measured, who we asked, and how long we gave the experiment. I keep the conflict itself to a sentence or two and spend most of the answer on what I did next, because interviewers listen for how I work through tension, not for who was right. I avoid blaming the teammate or the process, and I never tell a conflict story where the other person looks careless. If the disagreement ended with me being wrong, I say so plainly and explain what I learned. I finish with the result in numbers when I have them, then one sentence on how things stood with that teammate afterward, since a good conflict story ends with the two of us still working well together.

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

## Mistakes to avoid

The weakest conflict stories I have practiced share a few habits, and I check every answer against them. Staying vague about the disagreement makes it sound invented, so I state the concrete technical question we split on, such as which service should own retries or whether a schema change needed a migration window. Turning the teammate into a villain makes me look hard to work with, so I describe the constraints they were under and the part of their view I still agree with. Rushing past my own part hides the one thing the interviewer asked about, so I slow down on the conversation where we resolved the conflict and quote what I actually said. Picking a disagreement that never mattered wastes the question, so I choose one where the team would have shipped something worse without the discussion. Telling two conflicts at once confuses the listener, so I pick one teammate, one disagreement, and one story, and I leave the rest for follow-ups. Ending on the conflict instead of the repair leaves the wrong impression, so the last thing I say is how we worked together afterward. When a follow-up asks what I would change, I name a specific moment, such as raising the concern a week earlier or pairing sooner, rather than a general promise to communicate more.

## Follow-up questions

After a conflict story, interviewers often ask how I would handle the same disagreement if the teammate were more senior, or what I do when a conflict does not resolve at all. For a senior teammate, I still bring the numbers and ask for a time-boxed experiment, and I say that deferring to experience is fine once we have agreed how to check the result. For a conflict that stays open, I describe writing down both options with their risks and costs, agreeing on who owns the call, and committing to it once it is made, even if my option lost. Another common follow-up is how the teammate would describe the disagreement today, and my answer should match the story I already told: we argued about the approach, never about each other, and we still review each other's code. Some interviewers ask for a second example, so I keep a shorter one ready about a teammate who wanted to skip tests to hit a demo date, where we agreed to test only the payment path first. If they ask what I learned across these stories, I say that most conflict on a team comes from different information, not different goals, so sharing what each of us knows early prevents most of it.
