# llm4cj documentation

Start with the task you need to complete.

## Adopt the package

- [Get started](getting-started.md) builds and runs a minimal external consumer.
- [Provider codecs](provider-codecs.md) maps each provider dialect to its encoder,
  decoder, and supported thinking controls.
- [Streaming and transport](streaming-and-transport.md) shows how to frame SSE
  chunks and enforce a response-body limit.

## Look up behavior

- [API reference](api-reference.md) lists the public model, codec, and transport
  surface.
- [Design boundaries](design-boundaries.md) explains which responsibilities
  belong in `llm4cj` and which remain in the calling application.

## Maintain the package

- [Contributing](../CONTRIBUTING.md) covers local checks and release validation.
- [Security policy](../SECURITY.md) defines the untrusted-input boundary.
- [Changelog](../CHANGELOG.md) records released behavior.
