---
title: "A process gate whose mechanism is stopping for a human leaves no evidence and cannot run unattended"
summary: "Four units ran a mandated test-design gate and the repository could not tell them from four that skipped it; committing the artifact first is what made the gate auditable."
module: AGENTS.md
date: 2026-07-28
problem_type: workflow_issue
component: development_workflow
severity: medium
source: "Issue #21, resolved after U11"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
tags:
  - process
  - autonomous-agents
  - auditability
  - code-review
  - tdd
applies_when:
  - "writing a process rule for an agent-driven or partly unattended workflow"
  - "a standards document mandates a step that produces no artifact"
  - "an approval step names an approver who is not present"
---

# A gate whose mechanism is a pause cannot run unattended

The standards document mandated a pre-implementation test-design gate. Its final step was
*"stop for human approval before implementation starts."*

The gate was followed. Every unit produced a real brief with acceptance criteria, named
regression risks and a per-scenario failure prediction. **None of it landed in the repository.**
The briefs existed only in conversation transcripts and pull-request descriptions. From the tree
alone there was no way to tell a unit that ran the gate from one that skipped it — not for a
future contributor, and not for a future agent.

And the mechanism itself did not work: in an unattended run there is nobody to stop for, so the
orchestrator had been approving in the human's place and disclosing the substitution in each pull
request. That substitution is defensible only while it is visible, and **a gate that produces no
artifact, approved by someone other than the person it names, is indistinguishable from no gate
at all once the conversation scrolls away.**

## What fixed it

**Commit the artifact, alone, as the first commit on the branch.** The brief goes to a versioned
directory; the commit ordering *is* the evidence, and `git log` is the audit trail. Nothing else
in a repository can distinguish a gate that ran from one that did not.

Three details that turned out to matter:

- **The brief names its own approver**, in the file, and says so when the orchestrator approved
  in the human's place. The disclosure travels with the artifact rather than with the pull
  request, which is discarded.
- **Departures are appended, never edited in.** A "revisions made during implementation" section
  records what the brief claimed and why it was wrong. Rewriting the original sections to match
  what shipped destroys the only record that the gate found anything.
- **The expected-failure prediction became a column in the test matrix** — for each scenario, the
  mechanism whose removal makes that test fail. Unlike a one-off red run, that claim stays
  checkable for the life of the test: delete the named mechanism and the named test must fail.

## The general rule

**Write the rule so it describes what actually happens.** A rule nobody can follow is worse than
a weaker rule everybody can — it gets quietly skipped, and then the *whole* document reads as
aspirational.

- Prefer a rule that produces a **durable artifact in the repository** over one that describes a
  transient behaviour, especially anywhere a step may be run unattended.
- If a step names an approver, make the artifact record **who actually approved**.
- Where a human pause is genuinely required, keep it — but do not let the pause be the *only*
  mechanism, because the pause leaves no trace.
- The same reasoning caught three other paths in this document pointing at files that had never
  existed. **A standards document that points at missing files trains readers to skim it**, at
  which point the rules that do work stop being read too.
