# Merge intervals — coding preparation

For merge intervals, sort by start, then maintain disjoint merged intervals. Compare the next
start to the last merged end; on overlap extend the end with max, otherwise append. Sorting costs
O(n log n). Touching endpoints overlap in this problem. Example: [8,10], [1,3], [2,6]
becomes [1,6], [8,10]. This is an approach, not evidence that the candidate implemented it.

# Calendar reminder architecture — partial preparation

Calendar event series and reminder rules are authoritative; scheduled reminder deliveries are
derived durable work. An event mutation and its outbox record commit together. An outbox relay
publishes changes to a reminder expander. The expander materializes a seven-day due-time horizon,
and a daily replenisher extends it even if no event changes. Track materialized-through progress
per rule and source generation; advance it only after the corresponding jobs are durable.
A scheduler leases due delivery rows; workers revalidate current event/rule state before sending.
Retries reuse stable delivery IDs. Provider idempotency determines external duplicate suppression;
do not promise exactly-once notification display. Seven days and daily replenishment are proposed
choices, not measured guarantees. These notes do not specify a daylight-saving ambiguity policy.
