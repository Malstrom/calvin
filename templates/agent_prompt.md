<!-- Agent prompt comment — posted on the task issue before adding label:agent.
     Read by the model during async execution together with a subset of .calvin/*.
     Rules:
       - Do NOT repeat content already in the issue body verbatim.
       - Do NOT serialize entire .calvin/* files.
       - Every sentence must carry information needed to implement the task.
         If it can be cut without loss, cut it.
       - Language: English only — mandatory, no exceptions.
-->

## Goal

[one concrete sentence — only if it adds precision beyond the issue Goal]

## Constraints

<!-- only rules from .calvin/conventions.yml and decisions.yml that directly apply to this task -->

- [constraint 1]
- [constraint 2]

## Tests

<!-- what to test and how, from .calvin/testing.yml, specific to this task.
     For each new test: write the method name in plain self-explanatory English.
     For each existing test file to extend: list the method names to add. -->

- [test case 1: plain-English method name + what it asserts]
- [test case 2]

## Depends on

[#N must be merged before starting | none]

## Context

<!-- only information NOT already in the issue body but critical to avoid mistakes -->

[e.g. Zeitwerk autoload rule, migration timestamp workaround, fixture gotcha]

## Files

<!-- For every file the agent must touch, include one block below.
     Label rules:
       REWRITE  — file exists and will be modified; include current content verbatim
       CREATE   — file does not exist; include boilerplate with named empty test(s)
       READ-ONLY — include for context only; agent must not modify it
     Never reference a file without a block if it will be changed.
     Never omit current content for a REWRITE file — the agent needs to know
     exactly where to insert code.
-->

### REWRITE: path/to/existing_file.rb

```ruby
# current content verbatim
```

### CREATE: path/to/new_test_file.rb

```ruby
# frozen_string_literal: true

require "test_helper"

class ExampleTest < ActiveSupport::TestCase
  test "plain English description of what is asserted" do
  end
end
```

### READ-ONLY: path/to/reference_file.rb

```ruby
# current content verbatim — agent reads this to understand context
```

## Expected output

<!-- Exhaustive list of files the commit must contain.
     The agent uses this as a self-check before finishing.
     Format: path — new | modified -->

- `path/to/file.rb` — new
- `path/to/other.rb` — modified
