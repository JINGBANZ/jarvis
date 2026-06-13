# 0002 — Personal Tool First, Not a Product

**Status:** Accepted

## Context

Trying the existing tools surfaced a real market gap (abandoned competitors, frustrated users). The
temptation was to design for distribution from day one. But the original brief was a personal
Jarvis, and the hard constraint is a working MVP in under two days of autonomous build.

## Decision

**Build the personal tool first.** Optimize for getting something genuinely good working for one
user (me), fast. Do not pay the productization tax now: no auth, no billing, no onboarding, no
multi-provider abstraction beyond what's free.

We may keep cheap, product-friendly choices where they cost nothing extra (clean licensing, no
hard-coded secrets), but we do not design for scale yet.

## Consequences

- We can freely reuse open-source/GPL code and patterns as references.
- The MVP *is* the whole thing — no "core engine vs. product" split to manage.
- We hit the < 2-day goal.
- If it proves great, productization is a deliberate later project, not a prerequisite.
