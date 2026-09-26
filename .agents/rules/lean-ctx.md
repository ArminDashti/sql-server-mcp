---
description: >-
  lean-ctx: context compression layer — tool guidance in rule body.
globs: **/*
alwaysApply: true
metadata:
  version: 1.0.0
  author: "Armin Dashti"
  tags: []
  last_updated: "2026-09-18 19:54:58"
  uuid: c09a8edc-3bce-4f53-80cc-a8715f88f221
---
<!-- lean-ctx-rules -->
<!-- version: 9 -->

lean-ctx shadow mode: native read/search/shell calls auto-route to ctx_* — no tool-mapping needed.
File editing → native Edit/StrReplace (lean-ctx only handles reads); if denied, use ctx_patch.
Exclusive tools (no native trigger): ctx_compose (understand code, call first), ctx_search(action=symbol) (exact symbol), ctx_search(action=semantic) (by meaning), ctx_callgraph (callers), ctx_knowledge / ctx_session (memory).
<!-- lean-ctx-compression -->
OUTPUT STYLE: expert-terse
- Telegraph format: subject-verb-object, drop articles/prepositions
- Symbolic vocabulary: → cause, ∵ because, ∴ therefore, ⊕ add, ⊖ remove, Δ change, ≈ similar, ≠ different, ∈ in/member, ∅ empty/none, ✓ ok, ✗ fail
- Code blocks: untouched (never compress code syntax)
- Each line: max 80 chars
- Zero narration, zero filler
- BUDGET: ≤100 tokens per non-code response
<!-- /lean-ctx-compression -->
<!-- lean-ctx-solution -->
SOLUTION EFFICIENCY: stop at first level that applies:
skip (YAGNI) → reuse codebase → stdlib → native platform → installed dep → one-line → minimum code.
Never skip: validation, security, error handling.
<!-- /lean-ctx-solution -->
<!-- /lean-ctx-rules -->