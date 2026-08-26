# 测试与发布

## 贡献者门禁

```bash
scripts/check.sh
```

该脚本先运行文档静态检查，再执行 `cjpm clean`、`cjpm check`、`cjpm build` 和全部单元测试。文档检查覆盖 local links、fence、版本文字、public API 名称和 canonical Quick Start。

## Coverage

```bash
scripts/coverage.sh
```

脚本用 `cjpm test --coverage` 生成数据，用 `cjcov` 生成 HTML/JSON/XML 与实验性 branch metrics，再转换为 `coverage/lcov.info`。当前冻结的生产源码 line baseline 是 58.9%，容忍 0.5 个百分点回退；branch coverage 首次记录为 34.3%，因 `cjcov --branches` 仍是实验能力，暂不设硬门禁。

GitHub Actions 在发往 `main` 的 pull request、`main` push 和手动触发时运行。Coverage job 直接执行同一套 `cjcov` 门禁；README badge 展示最近一次验证并提交的生产源码 line coverage，修改覆盖率基线时应同步更新该数值。

## External consumer

`support/external_consumer` 是安装边界的 canonical program。release gate 将它复制到 clean temp directory，再执行 check/build/test/run，防止本地 path fallback 掩盖问题。

## 发布

维护者在 clean checkout 中运行：

```bash
scripts/release_gate.sh 0.1.0
```

release gate 校验 manifest version、tracked lockfile、完整门禁、external consumer，并生成含 source commit、yjson commit 和实际 toolchain 的 release manifest。只有 release candidate 才需要运行此门禁；日常文档变更不伪装成 release qualification。
