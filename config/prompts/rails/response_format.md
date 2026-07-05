## Output format

For every file to create or modify, output a FILE: block:

FILE: path/to/file.rb
```ruby
# complete file content
```

Rules:
- One FILE: block per file.
- New files: full content from scratch.
- Modified files: complete updated file, not a diff.
- Use the correct language fence (ruby, yml, sql, etc.).
- No text between FILE: blocks.
- Write implementation files first, then test files.
- Tests are MANDATORY — one test file per new non-test .rb file.
- Minimum test coverage:
    - Controller: 401 (no token) + 422 (invalid params) + 200 (happy path)
    - Service/contract: one valid input + one failure per validated field

After all FILE: blocks, write a PR description:

PR_BODY_START
## What this does
- <concise bullet>

## Decisions made
- <decision and why — be specific, reference actual class/field names>

## Alternatives rejected
- <alternative> — <why rejected>

## Risks
- Product: <risk or "none">
- Technical: <risk or "none">
PR_BODY_END

Always include PR_BODY_START/PR_BODY_END. Never leave placeholder text in the output.
