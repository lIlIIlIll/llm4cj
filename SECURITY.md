# 安全策略

## 支持范围

当前维护 `main` 与最新 release tag。`0.x` 不承诺跨 minor 兼容；已确认的安全修复会优先发布到最新维护线。

## 私下报告漏洞

请使用 GitHub 仓库的 **Security → Report a vulnerability** 发起 private vulnerability report：

<https://github.com/lIlIIlIll/llm4cj/security/advisories/new>

报告应包含受影响版本或 commit、最小复现、影响、建议修复方向，以及是否已公开披露。不要在 public issue、discussion 或 pull request 中发布未修复漏洞，也不要提交真实 credential。

仓库未声明安全联系邮箱；如果 GitHub private reporting 暂不可用，则当前没有替代 private channel，请等待该渠道恢复后再提交敏感细节。

## Scope

欢迎报告 codec confusion、未受限解析、duplicate-key bypass、SSE/HTTP body limit bypass、错误分类导致的危险 retry，以及 opaque provider data 的意外泄露。上游 Cangjie、`yjson` 或应用自有 HTTP/credential policy 的问题应报告给对应项目。
