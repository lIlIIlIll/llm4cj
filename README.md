# llm4cj

`llm4cj` converts provider-neutral Cangjie values to and from LLM provider wire
formats. Use it when an application must support more than one provider without
putting provider JSON throughout the agent runtime.

The package supports:

- OpenAI Responses;
- OpenAI-compatible Chat Completions;
- Anthropic Messages;
- DeepSeek Chat Completions and Messages request dialects;
- incremental Server-Sent Events (SSE) framing;
- bounded HTTP response-body reads; and
- structured transport and provider errors.

`llm4cj` does not send HTTP requests. Your application still owns credentials,
HTTP client configuration, retry decisions, model routing, agent state, and tool
execution. See [Design boundaries](docs/design-boundaries.md) before integrating
the package into an agent runtime.

## Add the dependency

`llm4cj` is distributed as a Git dependency. Add it to your application's
`cjpm.toml`:

```toml
[dependencies]
llm4cj = { git = "https://github.com/lIlIIlIll/llm4cj.git", branch = "main" }
```

The package currently follows `yjson` from its `main` branch. Commit your
application's `cjpm.lock` to record the exact `llm4cj` and `yjson` revisions.

The manifest requires Cangjie `1.1.0`. Development and release checks use the
latest complete Cangjie nightly SDK.

## Encode a request

Create one provider-neutral request, then select the provider protocol at the
encoding boundary:

```cangjie
import llm4cj.*

let request = LlmWireRequest(
    "model-name",
    [LlmWireMessage(
        LlmWireRole.User,
        [LlmWireBlock(LlmWireBlockKind.Text, text: "Hello")]
    )]
)

let payload = encodeLlmWireRequest(LlmWireProtocol.Responses, request)
```

`payload` is a JSON request body for the Responses API and contains
`"model":"model-name"`. The package does not add an endpoint or authorization
header.

Follow [Get started](docs/getting-started.md) for a complete consumer that you
can build and run.

## Choose the next guide

- [Documentation index](docs/README.md): find a guide by task.
- [Provider codecs](docs/provider-codecs.md): choose a protocol and valid
  thinking control.
- [Streaming and transport](docs/streaming-and-transport.md): process bounded
  bodies and SSE data.
- [API reference](docs/api-reference.md): look up public types and functions.
- [Contributing](CONTRIBUTING.md): prepare and validate a change.

## Release model

Releases use semantic versions and `v`-prefixed Git tags. During the `0.x`
series, fixes increment the patch version. New or breaking public API work
increments the minor version.

This is a Git-only package. A release publishes a tag and verification evidence,
not a `.cjp` bundle, because cjpm does not bundle packages that have Git
dependencies. See [CHANGELOG.md](CHANGELOG.md) for released changes.

## License

`llm4cj` is licensed under the [Apache License 2.0](LICENSE).
