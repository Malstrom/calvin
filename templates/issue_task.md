## Goal

[one sentence — what this task does, concrete and verifiable]

## Parent

#[epic issue number]

## Stack

- [ ] backend
- [ ] ios
- [ ] frontend

## DB Changes

<!-- omit if no schema changes -->

- Migration: [description or none]
- Model changes: [new columns, validations, associations or none]

## Endpoint

<!-- omit if no HTTP endpoint is created or modified -->

- Method: [GET | POST | PATCH | DELETE]
- Path: [e.g. /api/v1/auth/guest]
- Auth required: [yes | no]
- Request body: `{ field: type, ... }`
- Response [2xx]: `{ field: type, ... }`
- Response [4xx]: `{ error: { code, message } }`

## Entry points

<!-- files, classes or routes that are the starting point for implementation -->

- `path/to/file.rb` — [role]
- `path/to/other.rb` — [role]

## Acceptance criteria

- [ ] [verifiable criterion 1]
- [ ] [verifiable criterion 2]

## Dependencies

[#N must be merged first | none]

## Notes

<!-- edge cases, gotchas, do-not-touch rules — optional -->

## Examples

<!-- references to existing code that must be replicated or adapted -->

- `path/to/existing.rb` — [one line summary of what to replicate]
