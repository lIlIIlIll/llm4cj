# Axyndra integration contract

`contract-migration.patch` applies to Axyndra commit
`4d88fa6072f7176a6d236a1cb39b33529d5b609d`. It moves tool versions onto
`LlmWireToolDeclaration`, removes provider-name-derived transcript capability
claims, and preserves the originating immutable transcript through materialization
and fixed/stream reply admission. Tool identities are checked before a
`ModelReply` is returned; argument-schema outcomes remain owned by Axyndra's tool
runtime. Admission failures retain observed usage and forbid provider fallback.

The new `ProviderTranscriptExchange` and `ProviderTranscriptPort` accept one
`LlmWireRequest` directly. Callers bind an exact model/endpoint codec profile and
pass its ordered transcript without projecting it through a second tool/message
view. The port uses the existing credential/transport seam and returns terminal
fixed or buffered-stream replies after tool admission. It has no retry or
provider fallback loop. Four offline mock tests cover initial A/B tools plus long
history and native declaration C, generated C calls, canonical call/result
replay, snapshot restore, unchanged wire prefixes, and preflight rejection before
any transport call. This integration does not change Thread or SQLite storage.

The existing `ModelRequest` adapter remains an initial-context-only path. It
rejects history whose removed declarations cannot be recovered as
`llm.context_update_unsupported`; historical calls/results are never rewritten
into text.

With a matching Cangjie SDK and stdx installation:

```bash
export CANGJIE_STDX_PATH=/absolute/path/to/dynamic/stdx
scripts/check_axyndra_consumer.sh /absolute/path/to/Axyndra
# Verify the published immutable dependency instead of the local checkout:
scripts/check_axyndra_consumer.sh /absolute/path/to/Axyndra --git-pin
```

The gate exports the fixed upstream commit into a temporary directory, applies
the patch, checks the permanent dependency pin closure, substitutes the current
llm4cj checkout only in that temporary dependency manifest, and builds/tests
`model_adapters`. It does not change the supplied checkout or publish dependencies.

All manifests and lock files pin published llm4cj source commit
`b8bd5b6fd41349900a3806212c63f62694379385`. The `--git-pin` gate resolves and
builds that Git dependency directly; the default mode uses a temporary local
path for development. The v0.3.0 release tag is pending publication. Recovery
uses `feat/ordered-transcript-issue-27`; the wiped local implementation's original
commit is not reused or claimed to be remotely available.

`support/transcript_consumer` is the smaller always-on consumer contract. It
covers native removal after a valid historical call/result, snapshot restore,
and generated fixed/stream calls checked against the request-end tool view.

On SDK 1.2.0, the bundled LLVM backend can crash in X86DAG instruction selection
while compiling the pinned yjson dependency at its original `-O2` setting.
[Upstream's consumer/examples/conformance workaround](https://github.com/lIlIIlIll/yjson/blob/0f2071a0ad59ad43a369abe51abaceaf873f0c63/.github/workflows/ci.yml#L205-L208)
uses a temporary entry `-O1` override; its
[implementation](https://github.com/lIlIIlIll/yjson/blob/0f2071a0ad59ad43a369abe51abaceaf873f0c63/scripts/ci_job.sh)
provides the same precedent. To select that workaround explicitly:

```bash
export LLM4CJ_CONSUMER_COMPILE_OPTION=-O1
scripts/check_axyndra_consumer.sh /absolute/path/to/Axyndra --git-pin
```

This option covers the consumer entry and all dependencies for the complete
check/build/test invocation. Axyndra uses the legal workspace
`override-compile-option` field, applying it to the selected `model_adapters`
member and its dependency closure. The helper restores the temporary entry manifest
in `finally`, including failed commands. With the option unset, compilation uses
the original settings. The override does not change library source, API or Git
pins, and it does not claim that the SDK's `-O2` failure has been fixed.
