# ADR 0001：采用短生命周期分支直接合入 main

- 状态：已接受
- 日期：2026-08-30

## 背景

仓库曾使用长期 `dev` 分支承载集成工作。PR 采用 squash merge 后，`dev` 保留原始提交，而 `main` 只保留新的 squash commit。两条分支即使内容相同，提交图也会长期显示互相 ahead，增加同步、冲突判断和清理成本。

仓库规模和维护方式不需要独立发布列车。`main` 已有构建、测试、coverage 和 contract 门禁，适合作为唯一长期开发基线。

## 决策

采用 trunk-based development：

1. `main` 是唯一长期分支。
2. 每项工作从最新 `main` 创建短生命周期分支，并直接向 `main` 提 PR。
3. 分支名使用 `<type>/<kebab-case>`。
4. PR 只允许 squash merge；squash commit 标题使用 PR 标题，正文留空。
5. 合并后自动删除源分支。
6. 允许 auto-merge，但所有 required checks、对话解决和高风险确认仍必须满足。
7. 不再创建长期 `dev`。依赖中的工作使用短期 stacked PR，前序合入后立即 restack。

PR 是否关联 Issue 由风险决定：

- routine 变更可关联开放 Issue，也可写 `Issue: N/A: <具体原因>`；
- high-risk 变更必须关闭同仓库的开放 Issue；
- Dependabot 免除 Issue 要求，但不免除高风险 `/land <SHA>` 确认。

## 高风险确认

修改源码、工作流、发布与契约门禁、provider probe，或修改/删除已有测试时，PR 自动视为 high risk。作者必须声明 `Risk: high`。

高风险 PR 在当前 HEAD 通过其他门禁后，由具有仓库写权限的成员评论：

```text
/land <完整 40 位 HEAD SHA>
```

新 push 会改变 HEAD，因此旧确认自动失效。该机制用于协作式防误操作，不作为能够抵御仓库写权限持有者的安全边界。

## 后果

优点：

- `main` 与开发基线一致，不再维护内容相同但历史分叉的 `dev`；
- 每个 PR 的验证证据直接对应最终目标分支；
- squash history 保持简洁，源分支合并后自动清理；
- AI agent 和人工贡献者共享同一条可验证交付路径。

代价：

- 大型重构必须拆成可独立审查的短 PR；
- stacked PR 需要在前序合入后 restack；
- 高风险变更需要额外的精确 SHA 确认。
