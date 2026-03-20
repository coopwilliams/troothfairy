Process one Obsidian tagged block and return JSON only.

Ticket ID: {{TICKET_ID}}
Route: {{ROUTE_NAME}} (`{{ROUTE_ID}}`)
File: {{FILE_PATH}}
Line number: {{LINE_NUMBER}}
Tag: #{{TAG_CHAR}} ({{TAG_LABEL}})

Exact tagged line:
```
{{TAGGED_LINE}}
```

Block content:
```
{{BLOCK_CONTENT}}
```

{{FULL_FILE_SECTION}}{{DIRS_SECTION}}Return ONLY valid JSON matching this schema:
```json
{{RESULT_SCHEMA_TEXT}}
```

Rules:
- Do not edit the vault file directly.
- `response_lines` must be an array of relative bullet lines. The first inserted line should usually start with `- #Ω{{TAG_CHAR}}` unless the correct output is a no-op success.
- For nested children under your first bullet, use leading tabs in `response_lines`.
- For `#©`, use `outcome: no_op_success` with an empty `response_lines` array when the assertion is correct.
- Use `append_failure_marker: true` for degraded outcomes.
- Do not wrap the JSON in markdown fences.
