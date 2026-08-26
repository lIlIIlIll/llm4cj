# Build a minimal llm4cj consumer

This tutorial adds `llm4cj` to a Cangjie executable and verifies that the
package can encode a provider-neutral request as an OpenAI Responses payload.
It does not make a network request or require provider credentials.

## Prerequisites

- A Cangjie SDK compatible with manifest version `1.1.0`.
- An existing cjpm executable project.
- Git access to the `llm4cj` and `yjson` repositories.

## 1. Add llm4cj

Add the Git dependency to your project's `cjpm.toml`:

```toml
[dependencies]
llm4cj = { git = "https://github.com/lIlIIlIll/llm4cj.git", branch = "main" }
```

Keep the generated `cjpm.lock` file in version control. The lock file records
the exact revisions selected from both `main` branches.

## 2. Encode a request

Replace your executable entry point with this program:

`src/main.cj`

```cangjie
package llm4cj_consumer

import llm4cj.*

main(): Int64 {
    let payload = encodeResponsesWireRequest(LlmWireRequest(
        "consumer-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock(LlmWireBlockKind.Text, text: "hello")]
        )]
    ))
    if (payload.contains("consumer-model")) { 0 } else { 1 }
}
```

Match the `package` declaration to the package name in your `cjpm.toml` if your
project is not named `llm4cj_consumer`.

## 3. Build and run the consumer

Build the project, then run its release executable:

```terminal
cjpm build
target/release/bin/main
echo $?
```

The final command must print:

```text
0
```

An exit code of `0` confirms that cjpm resolved the Git dependencies and that
`encodeResponsesWireRequest` produced a payload containing the selected model.
It does not verify network access to an LLM provider.

If cjpm cannot resolve `yjson`, remove any local path override and let
`llm4cj` resolve the Git dependency recorded in its manifest.

## Next steps

- Use [Provider codecs](provider-codecs.md) to select a protocol and thinking
  control.
- Use [Streaming and transport](streaming-and-transport.md) when your HTTP client
  receives an SSE response.
