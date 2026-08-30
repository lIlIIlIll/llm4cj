# 贡献指南

感谢你改进 `llm4cj`。请让变更保持 provider-neutral，并维持“应用拥有网络与策略、库拥有 wire codec 与有界 framing”的边界。

## 开发流程

仓库采用 trunk-based development，`main` 是唯一长期分支。不要创建长期 `dev`；完整决策见 [ADR 0001](docs/adr/0001-trunk-based-development.md)。

1. 更新本地 `main`，创建 `<type>/<kebab-case>` 格式的短生命周期分支。允许的 type 是 `feat`、`fix`、`docs`、`test`、`refactor`、`ci`、`build` 和 `chore`。
2. 修改源码时同时加入可重复的测试；修改 public API、默认值、协议 mapping 或错误码时更新 API 文档和 CHANGELOG。
3. 运行贡献者门禁：

```bash
scripts/check.sh
```

4. 若改动影响 executable line，运行 coverage：

```bash
scripts/coverage.sh
```

覆盖率最低要求为 project line 90%、project branch 80%、patch line 95%、patch branch 85%。patch branch 门槛为 cjcov/gcov 的编译器生成安全分支保留余量。修改 public declaration、错误码或 fixture 时还要运行：

```bash
python3 scripts/check_contract.py
```

5. 使用 Conventional Commit 格式提交聚焦的 commit，并以同样格式填写 PR 标题。PR 直接以 `main` 为目标。
6. 在 PR 正文声明 `Risk: routine` 或 `Risk: high`：

   - routine 变更可以使用 `Fixes #123` 关联开放 Issue，也可以填写 `Issue: N/A: <具体原因>`；
   - 修改源码、工作流、发布/契约门禁、provider probe，或修改/删除已有测试时，必须声明 high，并以 closing keyword 关联同仓库开放 Issue；
   - high-risk PR 需要仓库 writer 对当前 HEAD 评论 `/land <完整 40 位 SHA>`，新 push 后必须重新确认；
   - Dependabot 免除 Issue 要求，但仍需 high-risk landing confirmation。

7. 解决所有 review conversation，并等待 required checks。仓库只使用 squash merge；squash 标题采用 PR 标题，正文为空。合并后源分支自动删除。

仓库期望设置保存在 [`.github/settings.yml`](.github/settings.yml)。维护者初始化新 fork 或审计设置漂移时先预览变更：

```bash
python3 scripts/bootstrap_repository.py --repository OWNER/REPOSITORY
```

确认预览后，才可使用具备 Administration 写权限的 token 显式应用：

```bash
GITHUB_TOKEN=... python3 scripts/bootstrap_repository.py \
  --repository OWNER/REPOSITORY --apply
```

该工具不会在默认模式修改远端。设置清单要求 `main` 保护、五项 required checks、review conversation、线性历史、squash-only、auto-merge 和合并后自动删除源分支。

不要在测试或文档中放入真实 API key，不要依赖真实 provider 网络获得确定性结果。完整示例必须能编译；核心 Quick Start 必须离线运行。

AI coding agent 还必须遵守根目录 [AGENTS.md](AGENTS.md)：保留无关工作、区分证据层级，并且不得提交 `.agents/`、`.claude/` 或 `.codex/`。

## 文档约定

文档使用中文说明，API、protocol、field 和 command 保持源码拼写。任务页提供完整程序，短 snippet 只能作为补充。不要写未经执行的测试数量、平台承诺或性能结论。

## 维护者发布

release candidate 需要 clean checkout，并运行：

```bash
scripts/release_gate.sh <major.minor.patch>
```

该门禁比日常 `scripts/check.sh` 多验证 coverage、lockfile、固定到候选 commit 的 external consumer、六个 dialect 的手动 provider-smoke artifact 与 release manifest。运行前将 `PROVIDER_SMOKE_EVIDENCE_DIR` 指向对应候选 commit 的脱敏 artifact 目录。发布安全问题前先阅读 [SECURITY.md](SECURITY.md)。
