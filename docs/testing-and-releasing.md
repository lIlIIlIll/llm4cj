# 测试与发布

本地完整门禁：

```sh
scripts/check.sh
scripts/coverage.sh
scripts/check_contract.py
```

CI required contexts 固定为：

- `CI / verify (minimum-1.1.0)`；
- `CI / verify (stable-latest)`；
- `CI / coverage`；
- `CI / contract`。

nightly 是定时 advisory，不阻塞发布。provider smoke 是手动 workflow，必须显式提供 secrets；日志与 artifact 只能保留 provider、dialect、状态和已脱敏错误，不得写出 key、request body 或原始 response body。

覆盖率门槛是 project line 90%、project branch 80%、patch line 95%、patch branch 90%。release gate 还验证 public API snapshot、错误码 inventory、fixture digest、全部文档程序和 exact candidate commit 的 external consumer。
