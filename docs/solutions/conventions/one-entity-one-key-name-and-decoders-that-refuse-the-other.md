---
title: "One entity, one key name — and a decoder that refuses the other spelling"
summary: "The same entity acquired two key names on one API surface three separate times; a tolerant decoder is what makes the divergence permanent and invisible."
module: lib/hospitality_coms_web
date: 2026-07-28
problem_type: convention
component: documentation
severity: medium
source: "PR #29 (U8), PR #35 and PR #39 (U12)"
root_cause: inadequate_documentation
resolution_type: code_fix
tags:
  - api-design
  - naming
  - serialization
  - decoders
  - contract-testing
applies_when:
  - "rendering one domain concept through more than one code path"
  - "a client decoder accepts either of two key names"
  - "fixing a naming divergence across an API surface"
---

# One entity, one key name — and a decoder that refuses the other

Three separate times in one codebase, one concept ended up with two key names on one surface:

- a message was `id` in the send reply and the history, and `message_id` in the live push;
- an instant was `sent_at` in the reply and the history, and `at` in the push;
- a status was the string `"declined"` when written and the atom `:declined` when read, from
  the same table, with the test suite asserting **both spellings four lines apart** — inside a
  comment congratulating itself on having removed exactly that divergence.

Each fix found further callers the ticket had not named. The last one turned up a *sixth*
caller: fixing only the five named would have left the defect standing on the other half of the
API.

## The divergence usually has a real reason — preserve it

`at` was not a typo. It came from a generic function stamping every notification, where "when
this notice happened" is the right name — a request, a decline and a disconnection were not
*sent*. Flattening everything to `sent_at` would have been the wrong fix and would have passed
every assertion in the file.

The right fix: the message push now goes through a wrapper that calls the generic stamp and
renames the one key. The generic function remains the only place an instant becomes a string, so
**a sixth kind of notification added later still gets the default name**. The mutation that
proves the split is intact: renaming the generic key globally fails *only* the test that reads
all five notification kinds.

## The cure is a decoder that refuses

**A tolerant decoder that accepts either spelling makes the divergence permanent and
invisible.** Here the client carried two decoders, each deliberately refusing the other's key —
which is why fixing the server needed no client change at all, and why the fix could be *verified
rather than assumed*: the client already demanded the correct spelling.

The test count went **down** when the two decoders collapsed into one, and a shrinking test count
is good evidence the duplication is actually gone.

## What to do differently

- **Route every rendering of a concept through one function**, so a new caller inherits the
  convention by default rather than by discipline.
- **Make decoders strict.** Refuse the wrong key rather than accepting both. A parser that
  tolerates your inconsistency guarantees you will never find it.
- **Pin whole key sets, not one field.** A test here named "in a reply, a history entry, *and* a
  push" checked a single field of the push. It now asserts the push's entire key set against the
  reply's.
- **Include the writers.** "Four readers, one shape" was true of the readers; the writer was a
  fifth caller outside the rule and answered the raw database struct. Give writers an explicit
  constructor onto the same render type.
- Adopt a mechanical convention (`<entity>_id`, never a bare `id`, for anything crossing the
  wire) so that the two spellings cannot both look reasonable.
