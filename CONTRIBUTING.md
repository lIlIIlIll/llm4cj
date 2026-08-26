# Contributing to llm4cj

Contributions must preserve the package boundary: `llm4cj` owns provider wire
formats and bounded transport primitives. Applications own credentials, HTTP
clients, retry decisions, model routing, agent policy, tool execution, and
recovery.

## Prepare the environment

Use the latest complete Cangjie nightly SDK. The package manifest requires
Cangjie `1.1.0`. Do not build an SDK as part of this repository's development
flow.

Clone the repository with its `cjpm.lock` file present. The lock file records the
`yjson` revision used by local and release checks.

## Make a change

Keep each change inside one public behavior boundary. Add or update tests when a
change affects:

- provider request encoding;
- reply or stream decoding;
- error codes or retry metadata;
- SSE framing; or
- byte and depth limits.

Tests must assert decoded values, encoded fields, errors, or limits. A test that
only checks that a function returns is not enough for codec behavior.

## Run the local gate

Run the repository gate from the project root:

```terminal
scripts/check.sh
```

The script runs `cjpm clean`, `cjpm check`, `cjpm build`, and `cjpm test`. A
successful run ends with:

```text
llm4cj check passed
```

The GitHub Actions workflow is manual. A local pass does not mean hosted CI has
run.

## Prepare a pull request

Describe the provider or transport behavior that changed and why. Include the
commands you ran and any gate you did not run. Keep tests with the behavior they
verify.

Do not include credentials or real provider payloads that contain private data.
Use reduced fixtures that preserve the wire behavior under test.

## Prepare a release

Maintainers run the release gate from a clean checkout:

```terminal
scripts/release_gate.sh 0.1.1
```

Replace `0.1.1` with the version in `cjpm.toml`. The gate requires a tracked
`cjpm.lock`, runs the local gate, builds a clean external Git consumer, and runs
that consumer's executable. It then writes:

- `dist/release-manifest.json`;
- `dist/SHA256SUMS`.

The gate does not create a `.cjp` bundle. After it passes, review the generated
evidence before publishing the matching `v<version>` tag.
