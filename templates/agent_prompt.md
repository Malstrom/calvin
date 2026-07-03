<!-- Agent prompt comment — posted on the task issue before adding label:agent.
     Read by the model during async execution together with a subset of .calvin/*.
     Rules:
       - Do NOT repeat content already in the issue body verbatim.
       - Do NOT serialize entire .calvin/* files.
       - Max 5 entry points. If more are needed, the task is too wide.
       - Every sentence must carry information needed to implement the task.
         If it can be cut without loss, cut it.
       - Examples must reference existing code with a one-line summary, never paste full blocks.
-->

## Goal

[one concrete sentence — only if it adds precision beyond the issue Goal]

## Entry points

- `path/to/file.rb` — [role in this task]
- `path/to/other.rb` — [role in this task]

## Constraints

<!-- only rules from .calvin/conventions.yml that directly apply to this task -->

- [constraint 1]
- [constraint 2]

## Tests

<!-- what to test and how, from .calvin/testing.yml, specific to this task -->

- [test case 1: what condition, what expected result]
- [test case 2]

## Depends on

[#N must be merged before starting | none]

## Context

<!-- only information NOT already in the issue body but critical to avoid mistakes -->

[e.g. Zeitwerk autoload rule, migration timestamp workaround, fixture gotcha]

## Examples

<!-- precise references to existing code with a short summary of what must be replicated -->

- `path/to/existing_controller.rb` — [one line: what pattern to follow]
- `path/to/existing_contract.rb` — [one line: what to replicate]
