# 测试与发布

本地完整门禁：

```sh
scripts/check.sh
scripts/coverage.sh
scripts/check_contract.py
scripts/benchmark_streaming.sh
```

CI required contexts 固定为：

- `verify (minimum-1.1.0)`；
- `verify (stable-latest)`；
- `coverage`；
- `contract`。

nightly 是定时 advisory，不阻塞发布。provider smoke 是手动 workflow，必须显式提供 secrets；每个响应会先通过 `support/protocol_probe` 的 public codec 解码，artifact 只保留 provider、dialect、状态和 HTTP status，不写出 key、request body 或原始 response body。

覆盖率门槛是 project line 90%、project branch 80%、patch line 95%、patch branch 90%。`scripts/check.sh` 会让六份 provider fixture 通过真实 codec，而不仅核对 digest；SSE 测试还会穷举每个字节分片边界。

发布使用手动 `Release` workflow：输入已存在的 tag 和同一 candidate SHA 的成功 Provider Smoke run ID。工作流依次运行 candidate release gate、从远端 tag 安装的 external consumer gate，并把 `release-manifest.json` 与 `SHA256SUMS` 上传为 GitHub Release assets。创建 tag/release 仍是显式发布动作，不由普通 CI 自动执行。

手动 Provider Smoke 会先构建 `support/provider_probe`，通过公共 `encodeRequest` 生成 streaming body，再将真实 `text/event-stream` 响应依次交给 `SseDecoder` 和协议 stream decoder。secret 只提供 endpoint、model 与认证 header；预制 raw body 不再是被测试对象。
