# llm4cj

`llm4cj` is a provider-neutral Cangjie package for translating typed LLM
requests, replies, and streaming events to and from provider wire formats. It
also provides incremental SSE framing, bounded response-body reads, and
structured transport errors.

The package supports OpenAI Responses, OpenAI-compatible Chat Completions,
Anthropic Messages, and the corresponding DeepSeek request dialects. It does
not own credentials, HTTP client configuration, retry policy, model routing,
agent state, or tool execution.

## Dependency

The package intentionally follows `yjson`'s `main` branch:

```toml
[dependencies]
llm4cj = { git = "https://github.com/lIlIIlIll/llm4cj.git", branch = "main" }
yjson = { git = "https://github.com/lIlIIlIll/yjson.git", branch = "main" }
```

Commit `cjpm.lock` in applications that need a record of the exact dependency
revisions selected by cjpm.

## Example

```cangjie
import llm4cj.*

let request = LlmWireRequest(
    "model-name",
    [LlmWireMessage(
        LlmWireRole.User,
        [LlmWireBlock(LlmWireBlockKind.Text, text: "Hello")]
    )]
)
let payload = encodeResponsesWireRequest(request)
```

Arbitrary JSON fields such as tool arguments and schemas use
`yjson.JsonNode`. Provider input rejects duplicate object keys, preserves JSON
number literals, and enforces explicit depth and size limits.

## Development

Prepare a Cangjie nightly environment, then run:

```sh
scripts/check.sh
```

The repository contains a manual-only GitHub Actions workflow. It is not
triggered by pushes, pull requests, tags, schedules, or releases.

## Releases

Releases use semantic versions and `v`-prefixed Git tags. During the 0.x
series, fixes increment the patch version and new or breaking public API work
increments the minor version. See [CHANGELOG.md](CHANGELOG.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
