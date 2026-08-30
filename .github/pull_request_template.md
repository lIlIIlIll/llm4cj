## 变更

<!-- 说明改了什么，以及为什么需要改。 -->

## 风险与追踪

<!-- routine 或 high，只保留一个值。敏感路径会自动升级为 high。 -->
Risk: routine

<!-- 使用 Fixes #123，或给出具体的不关联原因。不要保留占位符。 -->
Issue: N/A: <reason>

## 验证

<!-- 列出实际运行的命令和结果；未运行的门禁要明确说明。 -->

- [ ] `scripts/check.sh`
- [ ] executable Cangjie 变更已运行 `scripts/coverage.sh`
- [ ] public API、错误码或 fixture 变更已运行 contract 检查
- [ ] 文档和示例与当前行为一致

## 高风险确认

high-risk PR 通过其他检查后，由仓库 writer 评论：

```text
/land <full-40-character-head-sha>
```
