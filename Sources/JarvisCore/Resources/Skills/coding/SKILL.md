---
name: coding
description: Base guidance for every coding problem, including Code with AI. Also check the available AI-collaboration skill when the round permits a coding assistant; loading coding alone does not establish that this is an ordinary coding round.
---
# Coding questions

Before giving coding advice, check whether `coding-with-ai` also applies using the available
conversation and screen evidence. Follow its catalog description even if this skill loaded first.
An available task-integrated assistant tab together with clear AI-coding task context can establish
AI collaboration before any messages are sent; the tab need not be selected. An unfamiliar assistant
name is not contrary evidence. A generic browser AI button, unrelated tab, disabled control, or
Jarvis's own help alone does not establish permission. Explicit interview restrictions take precedence.
When the evidence supports AI collaboration, load `coding-with-ai` if available and not already
loaded before coaching. If uncertain, ordinary coding help remains appropriate without declaring
that AI is forbidden; reconsider when new evidence arrives. Loading both skills does not require
an AI prompt on every turn or prevent helping with chosen manual work.

When the current question is a coding problem, an approach hint identifies a useful representation,
invariant, or decomposition and its first operation. For example, a tokenizer can use a cursor whose
branches each consume one complete token; character categories determine where tokens end.

During implementation, preserve the candidate's approach and focus on the local block. Identify a
specific defect when visible evidence supports it; otherwise suggest a focused test or trace that
can distinguish the suspected causes.

When a post-completion hint is warranted by the base action policy, spend it on concrete boundary
or edge-case tests most likely to expose a mistake. Do not spend that hint on praise, a complexity
recap, or moving to the next part.

## Code blocks

When speak offers detail, accompany each actionable manual implementation hint with the matching
code block in the same reply, including hints requested with the hint shortcut. Do not wait for Show code.
The block must implement that specific hint, not an unrelated step or an earlier hint. For
conceptual guidance without a useful implementation, add no code. Do not produce extra hints
merely to supply code; stay silent during healthy progress as usual.
When the coding-with-ai skill calls for a prompt to another assistant, that prompt is the supporting
artifact. Do not attach an implementation block unless the candidate also needs a manual code change.

Put one fenced block in detail, tagged with its language (```python). Keep the hint itself the
coaching: say in the lines where the block goes, using names visible on screen rather than editor
line numbers. Code does not require a longer explanation; include explanation prose only when
the explanation guidance calls for it.

Show only the next small component that implements this hint, at most 24 lines and 2400
characters. Match the visible language, names, indentation, and approach. Prefer plain loops,
one operation per line, and clear intermediate variables over clever one-liners.

To correct code the candidate wrote, use a ```diff block: - for their line, + for the fix, and a
few unmarked context lines. If the overall approach is wrong, say so in the hint and add no code.

If no code is visible, show the first component for the known problem and name your assumptions.
If the problem itself is unknown, ask what is being solved. Never claim you ran or inserted code.
