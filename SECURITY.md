# Security policy

Report suspected vulnerabilities through GitHub's private security advisory
feature. Do not include exploit details, credentials, or private provider
payloads in a public issue.

## Untrusted input boundary

Treat every provider response, SSE chunk, tool argument, schema, and retry
header as untrusted input. Changes must preserve:

- configured byte limits for HTTP bodies, SSE buffers, and SSE events;
- JSON byte, string, and nesting-depth limits;
- duplicate JSON object-key rejection;
- structured errors for malformed provider payloads; and
- rejection of incomplete streams when the protocol has not supplied terminal
  evidence.

Callers must choose limits that fit their deployment. Callers also own TLS,
credential storage, endpoint selection, request timeouts, cancellation, and the
decision to retry.

## Security-sensitive changes

Add a negative test for any change to parsing, size checks, stream completion,
or provider error handling. Run `scripts/check.sh` before submitting the change.
See [Contributing](CONTRIBUTING.md) for the complete local gate.
