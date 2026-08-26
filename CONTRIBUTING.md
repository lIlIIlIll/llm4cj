# 贡献指南

感谢你改进 `llm4cj`。请让变更保持 provider-neutral，并维持“应用拥有网络与策略、库拥有 wire codec 与有界 framing”的边界。

## 开发流程

1. 从 `main` 创建短生命周期分支。
2. 修改源码时同时加入可重复的测试；修改 public API、默认值、协议 mapping 或错误码时更新 API 文档和 CHANGELOG。
3. 运行贡献者门禁：

```bash
scripts/check.sh
```

4. 若改动影响 executable line，运行 coverage：

```bash
scripts/coverage.sh
```

5. 提交聚焦的 commit，并在 pull request 中说明行为、原因和实际运行的验证。

不要在测试或文档中放入真实 API key，不要依赖真实 provider 网络获得确定性结果。完整示例必须能编译；核心 Quick Start 必须离线运行。

## 文档约定

文档使用中文说明，API、protocol、field 和 command 保持源码拼写。任务页提供完整程序，短 snippet 只能作为补充。不要写未经执行的测试数量、平台承诺或性能结论。

## 维护者发布

release candidate 需要 clean checkout，并运行：

```bash
scripts/release_gate.sh <major.minor.patch>
```

该门禁比日常 `scripts/check.sh` 多验证 version、lockfile、external consumer 与 release manifest。发布安全问题前先阅读 [SECURITY.md](SECURITY.md)。
