# Repository instructions for AI coding agents

## Scope and evidence

- Treat the current checkout, target commit, tests, and remote checks as the source of truth. Do not infer current behavior from an older review or conversation.
- Keep `llm4cj` provider-neutral. Applications own HTTP clients, credentials, retries, endpoint selection, model catalogs, and agent loops. This repository owns canonical wire semantics, strict encoding and decoding, bounded framing, and deterministic errors.
- Preserve unrelated work. Inspect the workspace before editing, and do not discard, rewrite, move, commit, or publish changes that belong to another task or agent.
- Distinguish static inspection, local checks, coverage, remote CI, provider smoke, and release evidence. Report only the evidence that actually ran for the exact commit.

## Development workflow

- Work from `main` on a short-lived branch named `<type>/<kebab-case>`, where `type` is `feat`, `fix`, `docs`, `test`, `refactor`, `ci`, `build`, or `chore`.
- Open pull requests directly against `main`. Do not create or revive a long-lived `dev` integration branch.
- Use Conventional Commit syntax for commits and pull-request titles.
- Keep each pull request focused. Keep behavior and its regression tests together; separate unrelated documentation, generated output, or mechanical cleanup when practical.
- Prefer GitButler for version-control operations when it is available. Do not push, open a pull request, merge, or alter repository settings unless the user explicitly requests that external change.
- Never commit agent-local state or instructions from `.agents/`, `.claude/`, or `.codex/`.

## Implementation rules

- Fail closed when provider data is malformed or when valid provider semantics cannot be represented without loss. Do not silently drop fields, reorder blocks, invent defaults, or turn truncation into success.
- Keep fixed and streamed decoding canonically equivalent for every supported semantic path.
- Validate complete requests before producing sendable bytes. Explicit options must be encoded exactly, resolved as a requirement, or rejected.
- Bound provider-controlled memory, event counts, nesting, and diagnostic retention before allocation or externally visible semantic emission.
- Do not expose provider-native replay payloads as an unrestricted JSON escape hatch.
- Use `apply_patch` for hand edits. Prefer `rp-rg`, `rp-sed`, `rp-awk`, `rp-grep`, and `rp-find` when their raw command semantics are needed.

## Validation

- Run `scripts/check.sh` for source, API, fixture, documentation, build, and test changes.
- Run `scripts/coverage.sh` when executable Cangjie lines or branches change.
- Run `python3 scripts/check_contract.py` when public declarations, errors, fixtures, or contract snapshots change.
- Add deterministic regression coverage for every corrected protocol path. Provider network calls are advisory evidence and must not replace offline fixtures.
- If a command cannot run, identify the exact missing evidence. Do not describe an unrun gate as passing.

## Pull-request metadata

- Declare exactly `Risk: routine` or `Risk: high` in the pull-request body.
- Routine changes must close an open repository issue or include `Issue: N/A: <specific reason>`.
- High-risk changes must close an open same-repository issue. Sensitive workflow, source, contract, release, and modified-test paths are automatically high risk.
- High-risk changes require a repository writer to comment `/land <full-40-character-head-sha>`. Any new push invalidates the old confirmation.
- Dependabot is exempt from the issue requirement, but not from high-risk landing confirmation.

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [trunk-based development ADR](docs/adr/0001-trunk-based-development.md) for the human-facing workflow.

## Code Review 专项不变量

- 本仓库仅处理 wire codec、strict framing、canonical transcript 与有界流语义；不得将 HTTP、重试、认证或 Agent Loop 责任错误地引入修复建议。
- 评审编码/解码时，对照输入 transcript → dialect/capability 解析 → wire bytes → 固定/流式 decoder → canonical terminal 状态；检查选项显式映射/拒绝、工具声明及撤销的时间顺序、choice 与 global terminal 的区分。
- 对同一根因一次性检查不同 provider dialect、合法/非法 block、UTF-8/SSE chunking、截断、拒绝、取消、错误、未知 native replay、token/bytes 工作量上限；只覆盖受影响协议，不要求所有 provider 的无关组合。
- review 阻塞意见需指出实际 wire 输入、状态轨迹及被违反的契约。升级协议验证不能借助丢弃字段或把 unsupported 当作 success 的简化。

## Code Review Rules

- 官方 Codex 检视应优先报告可复现的协议正确性、安全和回归缺陷，给出具体触发条件/断言及受影响代码。区分推测、风格建议、历史债务与本 PR 造成的问题。
- 同一不变量的对称/逆向/空值/边界情形应尽量一次检查并归并报告；后续提交以验证修复、相关调用链及回归为主，仍需提出新发现的真实缺陷。
- 检查已有 Review Thread 避免重复；不要通过固定轮数或省略真实阻塞缺陷来人为制造收敛。

## Review 反馈处理与收敛

- 执行 Agent 逐组核实并归纳 Review 根因，用参数化测试或离线 provider fixtures 覆盖相关语义，再批量修复、运行 `scripts/check.sh` 及按变更范围运行 `scripts/coverage.sh` / `scripts/check_contract.py`。
- 记录哪些意见已修复、附反证不采纳、仍阻塞、可另开 Issue；尽量批量 Push，不对每条评论都独立推送。
- 最新 HEAD 上的 Codex Review 是否已完成，须以实际审查记录为证；`AGENTS.md` 不能保证自动触发。PR 合并仍须满足已有 `Risk`、Issue、`/land <sha>` 与 CI 规则；不以 Thread 清零取代原有门禁。
