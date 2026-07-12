## Goal

[one sentence — what this job does, concrete and verifiable]

## Parent

#[epic issue number]

## Stack

- [ ] backend
- [ ] ios
- [ ] frontend

## Job

- Trigger: [event name | cron expression]
- Payload:
  ```json
  { "field": "type" }
  ```
- Side effects: [what it writes / reads / calls externally]
- Idempotent: [yes | no] — [one sentence why]
- On failure: [retry with backoff | dead letter queue | ignore | raise]

## Acceptance criteria

- [ ] [verifiable criterion — observable side effect or state change]
- [ ] [verifiable criterion]

## Notes

[edge cases, business constraints, things Calvin cannot infer from code]
