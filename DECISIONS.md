# Decisions

## 2026-11-06: Deterministic recovery and deliberate targets

First releases enumerate reachable tag history with the same 500-commit ceiling
as comparison ranges. Missing timestamps fail before writes rather than inventing
a date. Legacy tags need explicit normalized versions and optional verified
ancestors; recovery does not infer a successor from unparsable tag names. PR
assignment may use a deliberate target while enforcement retains live refetches.
These are bounded changes to existing workflows; ADR-not-applicable: no new
architecture or authority is introduced. Independent review is required.
