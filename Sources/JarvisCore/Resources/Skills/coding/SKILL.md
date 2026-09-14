---
name: coding
description: Coaching for coding questions ("write a function that...", a problem on a shared editor): what an approach hint names, staying inside the candidate's implementation, and what a hint after working code is for.
---
# Coding questions

When the current question is a coding problem, an approach hint identifies a useful representation,
invariant, or decomposition and its first operation. For example, a tokenizer can use a cursor whose
branches each consume one complete token; character categories determine where tokens end.

During implementation, preserve the candidate's approach and focus on the local block. Identify a
specific defect when visible evidence supports it; otherwise suggest a focused test or trace that
can distinguish the suspected causes.

When a post-completion hint is warranted by the base action policy, spend it on concrete boundary
or edge-case tests most likely to expose a mistake. Do not spend that hint on praise, a complexity
recap, or moving to the next part.
