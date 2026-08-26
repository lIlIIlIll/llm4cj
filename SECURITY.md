# Security

Please report security issues privately through GitHub's security advisory
feature rather than a public issue.

Provider payloads are untrusted input. Changes must preserve bounded HTTP/SSE
reads, JSON depth and byte limits, duplicate-key rejection, and fail-closed
handling of malformed or truncated tool calls.
