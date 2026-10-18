# Extract a structured JSON answer

Call `extractStructuredOutput(reply, request)` after fixed decoding or a completed
stream. It is a separate, provider-neutral validation barrier. Text deltas alone
do not establish a completed answer. The original request must declare
`JsonObject`, `JsonSchema`, or `JsonSchemaDocument`.

```cangjie
match (extractStructuredOutput(reply, request)) {
    case LlmWireResult.Ok(result) => match (result.outcome) {
        case LlmWireStructuredOutputOutcome.Valid(value) => println(value.stringify())
        case _ => println("The reply is not a validated structured answer")
    }
    case LlmWireResult.Err(error) => println(error.code)
}
```

The result distinguishes `Valid`, `InvalidJson`, `SchemaViolation`,
`UnsupportedSchema`, `Incomplete`, and `Refused`. `rawText` preserves the exact
candidate text, including whitespace, for attempted extraction. Refusal and
incomplete outcomes return before copying or parsing text and use `rawText=None`.
Even complete JSON cannot turn a refused or truncated choice into `Valid`.

Multi-choice replies require `choiceIndex: Some(index)`; the number is the
choice's index, not its array position. Missing or duplicate selected indices
return errors. Unselected choices are not extracted.

With message spans, extraction selects the unique Final message, or the unique
Unspecified message when there is no Final message. Multiple candidates are
ambiguous. Text blocks in the selected message are joined in order with no
separator. Zero-block messages retain their boundary and yield invalid empty
JSON. Conflicting explicit message/text phases and invalid spans are rejected.
Without spans, the legacy choice is one implicit message: Final text takes
precedence over Unspecified text. Analysis and Commentary text are excluded.
The extractor does not invent message boundaries lost from legacy data.

Known reasoning and native replay blocks are not answer text. A completed choice
with tool calls or audio is rejected as a mixed answer. Refused/incomplete outcomes take
precedence over that extraction check.

`JsonObject` requires a JSON object. Named and document schema formats validate
against their raw declared schema and may accept arrays or scalars. The provider
request's `strict` metadata does not select the local validation policy. The
extractor defaults to `LlmWireToolInputValidationMode.Strict`; subset mode reports
a provable violation first, otherwise unknown constraints remain unsupported.
`Disabled` is rejected. See [schema validation](schema-validation.md).

Extraction never removes Markdown fences, repairs malformed JSON, normalizes the
returned raw text, or accepts trailing garbage. An invalid JSON outcome retains
the original candidate separately from the error. Diagnostics use fixed messages
and bounded evidence instead of embedding the answer text.
Invalid JSON includes the parser's zero-based UTF-8 `byte_offset` when available;
the diagnostic does not copy the parser message or candidate text.

`maxTextBytes` defaults to 8 MiB and can only be lowered to a positive limit. The
sum is checked before concatenation. JSON byte/depth and shared schema-work
limits return outer `LimitExceeded` errors, rather than `InvalidJson` or schema
violations. Lowered depth limits apply before the parser allocates the DOM.
Selection and option errors also use the outer Result; provider-answer outcomes
use the six outcome cases. Observed usage is attached to returned errors.

`fixtures/structured-output.json` contains hand-authored fixed/stream expectations
for eight named dialects. The public consumer verifies both against the oracle,
including 1/3/7/full SSE chunks and LF/CRLF framing:

```sh
support/provider_probe/target/release/bin/main check-structured fixtures/structured-output.json
```

This offline fixture check does not establish live-provider support or execution.
