# Contributing

Use the latest complete Cangjie nightly SDK. Do not build the SDK as part of
this repository's development flow.

Before submitting a change, run `scripts/check.sh`. Tests must exercise public
behavior and include semantic assertions for codec, error, stream, or resource
limit changes. Keep model routing, credentials, agent policy, tool execution,
and product recovery logic outside this package.

Public releases are prepared with `scripts/release_gate.sh <version>` from a
clean checkout. The manifest version must match the requested version and the
repository must contain a tracked `cjpm.lock`.
