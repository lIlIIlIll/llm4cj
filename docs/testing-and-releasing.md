# 测试与发布

本地完整门禁：

```sh
scripts/check.sh
scripts/coverage.sh
scripts/check_contract.py
scripts/check_api_compat.py
scripts/benchmark_streaming.sh
```

CI required contexts 固定为：

- `verify (minimum-1.1.0)`；
- `verify (stable-latest)`；
- `coverage`；
- `contract`。

nightly 是定时 advisory，不阻塞发布。provider smoke 是手动 workflow，只能从受保护 `main` 当前 SHA 运行，并绑定 `provider-smoke` GitHub Environment；输入 SHA 必须等于 workflow 的 trusted `github.sha`。secret-bearing job 不 checkout 任意 candidate。每个响应会通过 public codec 解码，artifact 只保留 provider、dialect、状态和 HTTP status，不写出 key、request body 或原始 response body。

覆盖率门槛是 project line 90%、project branch 80%、patch line 95%、patch branch 90%。patch gate 从 cjcov 保留的 `.gcov` 文件取得可插桩行集合；任一新增可执行行缺少 LCOV `DA:` record 都会直接失败，不能通过缩小分母获得假绿。`scripts/check_api_compat.py` 还会将公共 API shape 与最新发布 tag 比较，shape 变化必须伴随 SemVer breaking bump；同一提交内更新当前快照不能绕过该检查。`scripts/check.sh` 会让六种 dialect 的 request、fixed response 与 stream fixture 通过 public codec，而不仅核对 digest；stream fixture 会用 1、3、7 字节分片重放，并额外覆盖只能在尾 CR/EOF 时释放最后事件的 framing。

发布使用手动 `Release` workflow：输入已存在的 tag 和同一 candidate SHA 的成功 Provider Smoke run ID。下载 artifact 前，workflow 会通过 GitHub API 验证 run 来自固定 `provider-smoke.yml`、事件为 `workflow_dispatch`、分支为 `main`、head SHA 等于 tag candidate、状态为成功，并验证六个 artifact 的 run identity 与 SHA-256 digest。run ID、workflow ID、workflow path 和 artifact digest 会写入 release manifest。工作流随后运行 candidate release gate、从远端 tag 安装的 external consumer gate，并把 `release-manifest.json` 与 `SHA256SUMS` 上传为 GitHub Release assets。若同名 GitHub Release 已存在，workflow 会失败，不覆盖原有证据。创建 tag/release 仍是显式发布动作，不由普通 CI 自动执行。

手动 Provider Smoke 会在受保护 main 上构建 `support/provider_probe`，通过公共 `encodeRequest` 生成 streaming body，再将真实 `text/event-stream` 响应依次交给 `SseDecoder` 和协议 stream decoder。secret 只提供 endpoint、model 与认证 header；预制 raw body 不再是被测试对象。`scripts/check_provider_smoke_security.py` 由普通 CI 执行，防止 workflow 重新 checkout `inputs.candidate_sha` 或移除 main/Environment 限制。
