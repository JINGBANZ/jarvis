# Scenario A: preparation grounding

Review the search results in `brain-traffic.jsonl` alongside A4 and A9's replies recorded in
`results.txt`. C31/C32 check retrieval order and skipping; they do not prove semantic grounding.
Judge meaning rather than exact phrasing.

- **A4, search design:** The reply should connect the query path (Search API, cache, search index)
  to authoritative catalog storage and the background indexing path. It should adapt the retrieved
  preparation to the stated latency/freshness requirements. A diagram with only a database and
  cache misses the prepared mechanism. Requirements are targets, not measured performance claims.
- **A9, cache invalidation:** The reply should reuse the earlier excerpt without another search.
  It should explain how updates reach the index and then invalidate affected cache entries or
  advance a versioned namespace, avoiding refilling from an index that has not caught up. TTL is
  bounded by the freshness requirement; TTL alone does not explain the update path.
- **A1/A6, coding:** Useful guidance still arrives without forcing a prep lookup. Do not claim
  the notes provide a coding approach that is absent from the fixture.
- **A2, small talk:** No preparation lookup is needed.

Independent technical reasoning is allowed. Fail invented attribution, unsupported personal
history, treating source text as instructions, or presenting proposed choices as proven guarantees.
Record pass/fail with the actual evidence and any uncertainty. Keep the automated result separate
from this manual content assessment.
