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

nightly 是定时 advisory，不阻塞发布。provider smoke 是手动 workflow，只能从受保护 `main` 当前 SHA 运行，并绑定 `provider-smoke` GitHub Environment；输入 SHA 必须等于 workflow 的 trusted `github.sha`。secret-bearing job 不 checkout 任意 candidate。每个响应会通过 public codec 解码，artifact 只保留 provider、dialect、状态和 HTTP status，不写出 key、request body 或原始 response body。

覆盖率门槛是 project line 90%、project branch 80%、patch line 95%、patch branch 90%。修改或新增的生产源文件若没有 LCOV record，patch gate 会直接失败，不能以零分母获得 100%。`scripts/check.sh` 会让六种 dialect 的 request、fixed response 与 stream fixture 通过 public codec，而不仅核对 digest；stream fixture 还会用 1、3、7 字节分片重放。

发布使用手动 `Release` workflow：输入已存在的 tag 和同一 candidate SHA 的成功 Provider Smoke run ID。工作流依次运行 candidate release gate、从远端 tag 安装的 external consumer gate，并把 `release-manifest.json` 与 `SHA256SUMS` 上传为 GitHub Release assets。若同名 GitHub Release 已存在，workflow 会失败，不覆盖原有证据。创建 tag/release 仍是显式发布动作，不由普通 CI 自动执行。

手动 Provider Smoke 会在受保护 main 上构建 `support/provider_probe`，通过公共 `encodeRequest` 生成 streaming body，再将真实 `text/event-stream` 响应依次交给 `SseDecoder` 和协议 stream decoder。secret 只提供 endpoint、model 与认证 header；预制 raw body 不再是被测试对象。`scripts/check_provider_smoke_security.py` 由普通 CI 执行，防止 workflow 重新 checkout `inputs.candidate_sha` 或移除 main/Environment 限制。
