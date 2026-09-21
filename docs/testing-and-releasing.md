# 测试与发布

本地完整门禁：

```sh
scripts/check.sh
scripts/coverage.sh
python3 scripts/check_contract.py
python3 scripts/check_api_compat.py
```

CI required contexts 固定为 minimum-1.1.0、stable-latest、coverage 和 contract。`scripts/check.sh` 会通过 public codec 验证七个 response/request/stream fixture inventory、三个 ordered-transcript fixtures、docs/examples、clean build、tests 和 stable/experimental local consumers。

覆盖率门槛是 project line 90%、project branch 80%、patch line 95%、patch branch 85%。覆盖率结果只描述实际执行的 Cangjie paths；未运行的 provider network、cache 或 live entitlement gate 不得写成 passed。

## Provider smoke 与 cache evidence

provider smoke 只能从受保护 `main` 当前 SHA 运行，并绑定 `provider-smoke` GitHub Environment。secret-bearing job 不 checkout 任意 candidate；每个响应通过 public codec 解码，artifact 只保留 provider、dialect、状态和 HTTP status，不写 key、request body 或原始 response body。

cache experiment 是独立的手动 advisory job。它要求 trusted main SHA、`provider-cache` environment 和 secret-backed JSON config，使用固定 transcript scenario 的 cold/warm/update 对照和重复样本，报告只保存脱敏 profile/model label、候选 SHA、HTTP status、耗时、decoded usage/source 与聚合统计。没有真实运行时，capability 保持 Unsupported/Unknown；离线 fixture 不能证明 provider cache 命中。

## Release candidate

Release workflow 默认要求同一 candidate SHA 的成功 Provider Smoke provenance。没有受保护 provider credentials 时，显式勾选 `offline_evidence`：workflow 跳过 smoke 下载与 provenance 硬门禁，`scripts/release_gate.sh 0.2.0 --offline-evidence` 仍执行 check、coverage、contract、API compatibility、候选 commit consumers、yjson main lock consistency 和 release manifest，并把 provider smoke/cache 记录为 `advisory_not_run`。它不会生成伪造的 passed artifact。

candidate release gate 要求干净 checkout 和版本为 v0.2.0；tag consumer gate 只在发布流程已授权并存在本地 tag 时执行。`scripts/release_manifest.py` 记录 exact source commit、contract digests、fixture digest、coverage、API compatibility 与实际 provider evidence status。未运行的 live/cache gate 必须在交付中明确列为未验证。
