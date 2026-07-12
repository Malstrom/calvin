## Goal

[one sentence — what this endpoint does, concrete and verifiable]

## Parent

#[epic issue number]

## Stack

- [ ] backend
- [ ] ios
- [ ] frontend

## Endpoint

- Method: [GET | POST | PATCH | DELETE]
- Path: [e.g. /api/v1/auth/magic_link]
- Auth required: [yes | no]
- Request body:
  ```json
  { "field": "type" }
  ```
- Response 2xx:
  ```json
  { "field": "type" }
  ```
- Response 4xx:
  ```json
  { "error": { "code": "string", "message": "string" } }
  ```

## DB Changes

- Migration: [description | none]
- Model changes: [new columns, validations, associations | none]

## Acceptance criteria

- [ ] [verifiable criterion — observable via HTTP, not implementation detail]
- [ ] [verifiable criterion]

## Notes

[edge cases, business constraints, things Calvin cannot infer from code]
