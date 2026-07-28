---
title: "A rule stated in prose is enforced by nobody — replace it with a structure, then attack the check"
summary: "Five invariants held only by docstrings, and four rounds of a structural test being repaired after each escape it could not see."
module: test-suite
date: 2026-07-28
problem_type: best_practice
component: testing_framework
severity: high
source: "PRs #16, #19, #22, #23, #25, #29, #34, #35, #37, #38"
root_cause: inadequate_documentation
resolution_type: test_fix
tags:
  - invariants
  - static-analysis
  - constraints
  - structural-tests
  - code-review
applies_when:
  - "a rule is documented in a moduledoc, comment, or design doc and enforced nowhere"
  - "writing a lint or structural test to hold an architectural rule"
  - "reviewing a claim that some layer 'always' or 'never' does something"
---

# Enforce a convention structurally, then attack the check

## Part one: prose enforces nothing

Five invariants in this project were stated in documentation and held by nobody. Every one was
discovered by somebody simply trying the forbidden thing:

- **"Exactly one founding grant per venue"** appeared in three docstrings. A reviewer inserted
  two; both succeeded. Now a partial unique index — chosen over a CHECK, because *a CHECK sees
  one row and this rule is about the table.*
- **Authority lineage** was recorded in a composite foreign key and never consulted, so any
  grant could revoke any other. The schema paid for the structure and the code ignored it.
- **A maximum name length** lived only in a changeset, so bulk inserts bypassed it. Now a check
  constraint that the changeset *names*, so the database's refusal comes back as a field error
  rather than an exception.
- **A hand-maintained module list** in a zone guard could drift from the schemas it classified.
  Replaced by deriving the table names from the schema itself, so classification and sweep
  cannot disagree.
- **`MATCH FULL` on composite foreign keys** was an architectural rule pinned nowhere. Writing
  the inventory out as a test is what found a fourth `MATCH SIMPLE` key nobody had documented.

The same disease affects counts. Four separate prose miscounts accumulated across units,
because *nothing checks a number in a sentence.* **State rules as inventories a test quantifies
over, not as counts in prose** — and treat a comment that misdescribes working code as a defect
with a delay on it, because the next author will code against it.

## Part two: your structural check has escapes, and they are the idiomatic ones

Having replaced convention with a mechanical check, this project then repaired that check four
times. The pattern of the repairs is the transferable part.

1. **Read the compiled artifact, not the source.** A check that no module outside one place
   imports the query builder was first written as a prefix filter over module names — and an
   inline query compiles to the *bare* builder module, which the filter missed. Measured, not
   assumed.
2. **An allowlist is a hole.** The same check carried an eight-entry exemption list; a sibling
   composing a query fragment matched an exempt entry and walked through. The allowlist is gone,
   and its removal was proved by planting a violation.
3. **The invisible form is the one that gets copied.** A check that "only one module deletes",
   read out of the compiled import table, was **blind to a delete nested inside a transaction
   closure** — which is precisely the idiom the permitted module itself uses five times. So the
   unenforceable form was the one a future author would copy from the exemplar. Now swept at the
   AST level, with a control that parses three synthetic sources, one of each shape.
4. **Record what the check provably cannot see.** The same family of checks does not catch a
   query with no interpolation, because it expands entirely at compile time. That limit is
   written down beside the check rather than left for someone to discover as a bug.

And when several mechanisms each have a blind spot, use several: one build property here is
asserted four ways, including a CI compile step, because reading the import table cannot see a
struct expansion or a typespec.

## The discipline

1. Find the rule that is stated and unenforced. Try to break it; you usually can.
2. Replace it with the strongest structure available — a constraint, an index, a type, a
   compile-time check — preferring one the database or compiler holds over one your code does.
3. **Then attack your own check.** Plant a violation in every syntactic form you can think of,
   especially the form the exemplar module itself uses.
4. Make the test read the same thing the build system reads, rather than a copy of its value.
5. Write down the forms the check cannot see.
