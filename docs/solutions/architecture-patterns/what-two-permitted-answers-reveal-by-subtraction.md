---
title: "A privacy guarantee can be intact in every tier and still recoverable by subtraction"
summary: "Two APIs a single legitimate caller may hold at once differed by exactly the opt-out set, so the protected fact was one subtraction away with all four tiers holding."
module: lib/hospitality_coms/rooms
date: 2026-07-28
problem_type: architecture_pattern
component: database
severity: critical
source: "PR #25 (U6)"
root_cause: scope_issue
resolution_type: code_fix
tags:
  - privacy
  - information-leak
  - inference
  - authorization
  - threat-model
applies_when:
  - "designing a redaction, opt-out, or visibility rule"
  - "one actor can legitimately hold two roles at once"
  - "reviewing whether an access-control tier actually protects the fact it names"
---

# What two permitted answers reveal by subtraction

A worker could opt out of a venue's chat room, and the design protected that opt-out four ways:
the record lived in a zone the employer's database role could not reach, no grant existed, a
row-level security policy covered it, and every query filtered it.

All four held against an **employer session**. None of them mattered.

The room's member roll subtracted suspensions. A separate, entirely legitimate API returned the
venue's active engagements without subtracting them. And **a manager is also a worker** — one
human, holding an employer scope and a person scope at the same venue, entirely within their
rights on both. Reading the two lists and subtracting gives exactly the set of people who opted
out.

The protected fact was one subtraction away with every tier intact.

## The fix was to remove the difference, not to add a tier

The roll is now defined as *the venue's active engagements*, suspensions included — identical by
construction to the other list, and a test pins the two returning the same ids. Suspension
governs the suspended person's **own** access alone: they cannot read the room, send to it, or
see it in their list, and nobody else's answer changes.

Nothing was lost, which is what made this the right fix rather than a compromise: the room
carries full history, so the person reads what was said while they were away the moment they
return.

## What to do differently

- **Enumerate what an attacker can *derive* from two permitted answers, not only what each
  answer discloses.** Set differences, counts, response lengths, timing, and ordering are the
  usual leaks. A rule of thumb: if two endpoints compute over the same underlying set with
  different filters, their difference is a published fact.
- **Look hardest where one actor legitimately holds two roles.** The tiers here were all designed
  against a *different* principal. The person who defeats them is not an attacker at all.
- **Prefer removing the difference to adding a guard.** A fifth tier on the room roll would have
  left the arithmetic available through any future endpoint over the same set; making the two
  lists equal by construction closes it permanently, and a test can state the equality.
- **Write the residues down.** Related surfaces here carry recorded disclosures rather than
  silent ones — a presence tracker keyed on a per-venue id rather than a person id, and three
  named residues in its moduledoc, so the next unit decides deliberately instead of rediscovering.
