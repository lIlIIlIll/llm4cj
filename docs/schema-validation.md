# Validate a declared JSON schema

`validateReplyToolInputs(reply, transcript, mode:, limits:)` validates completed
tool arguments against the active tool definition. Tool identity and visibility
are checked in every mode, including `Disabled`.

`Strict` preflights the entire schema before checking the instance. Unsupported
keywords or malformed forms produce `llm.tool_schema_unsupported`, including
rules inside unused properties, items, definitions and combinator branches.
`ValidateSupportedSubset` checks the known constraints first: a provable failure
produces `llm.tool_arguments_schema_violation`; otherwise any unsupported rule
produces `llm.tool_schema_unsupported`. It never returns success after skipping
unknown rules. This changes the previous subset mode's skip-and-succeed behavior.

The supported keywords are `type`, `properties`, `required`,
`additionalProperties`, `items`, `enum`, `const`, `minimum`, `maximum`,
`exclusiveMinimum`, `exclusiveMaximum`, `minLength`, `maxLength`, `minItems`,
`maxItems`, `minProperties`, `maxProperties`, `allOf`, `anyOf` and `oneOf`.
Supported schema-valued positions accept objects or boolean schemas.
`additionalProperties` can contain a schema. Existing tool/request root-object
requirements remain in effect.

Combinators require nonempty arrays of schemas. `oneOf` requires exactly one
matching branch. An unknown branch is not counted as a match or a failure;
unknown rules in unused subtrees also prevent a branch from being a definite
match. Two definite matches prove a `oneOf` violation. A known matching `anyOf`
branch does not hide unsupported rules in another branch.

Numeric comparisons use exact decimal values and arbitrary-length exponents,
without floating-point conversion or expanding powers of ten. `const` and `enum`
ignore object key order, preserve array order, and distinguish booleans from
numbers. Length limits count Unicode scalar values, including combining code
points separately. Count bounds must be nonnegative mathematical integers.

`pattern`, `$ref`, `prefixItems` and other unlisted constraints remain unsupported.
In subset mode, `patternProperties` also prevents proving an additional-property
failure, and `prefixItems` prevents applying the supported `items` rule at a
guessed starting index. Ordinary annotation data such as `default` and `examples`
is not treated as schema.

`LlmWireSchemaValidationLimits` defaults to depth 256 and 67,108,864 work units;
callers may lower either positive limit. Input bytes, node and keyword visits,
comparison bytes and all branches share one work budget across the validation
call. Limits produce `LimitExceeded / llm.schema_validation_limit`, never a
schema violation. JSON values retain the existing 8 MiB and depth-256 bounds.
Diagnostic JSON is capped at 2 KiB; paths and values use bounded evidence.

The independently authored oracle is `fixtures/schema-validation.json`, based on
the JSON Schema 2020-12 core and validation specifications checked 2026-10-18.
Run its public consumer after building `support/provider_probe`:

```sh
support/provider_probe/target/release/bin/main check-schema fixtures/schema-validation.json
```

These are offline semantics checks, not live-provider acceptance evidence.
