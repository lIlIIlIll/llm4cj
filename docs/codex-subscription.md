# 接入 Codex 订阅

使用 Linux 原生仓颉示例登录获准的 Codex 订阅账号，列出模型，并通过 SSE 或 WebSocket 连续对话。示例使用官方 [SIWC Sign in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) 和 [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference) 流程。账号是否获得 direct subscription grant 由 OpenAI 决定，见 [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)。

## 准备

- Linux、Python 3、Cangjie SDK `>= 1.1.0`，以及与 SDK 匹配的 stdx 动态库。
- `cjc`、`cjpm` 在 PATH 中，stdx 动态库目录在平台运行库搜索路径中。
- 系统 CA 和可打开浏览器的 `xdg-open`；无桌面时复制示例打印的授权 URL 到本机浏览器。
- 一个允许 SIWC direct subscription inference 的账号。不要把 API key 或 OMP 旧 backend token 当作本示例的登录凭据。

从仓库根目录设置 stdx 目录，再运行离线检查：

```sh
export CANGJIE_STDX_PATH="<matching-stdx-directory>"
python3 scripts/codex_example.py --check
```

成功时仓颉测试报告显示 `CodexExampleTest` 全部通过。runner 在临时磁盘目录中生成 stdx 链接配置，运行结束删除构建目录；tracked manifest 不包含本机 SDK 路径。`TMPDIR` 指向 tmpfs 时回退到 `$HOME/.cache/agent-tmp`。

## 登录并选择模型

用标签区分账户。首次登录通过 `dynamic_agent_client` 发起注册，回调必须返回 issued `client_id`。返回用户继续使用已保存的 client ID。

```sh
python3 scripts/codex_example.py login personal
python3 scripts/codex_example.py accounts
python3 scripts/codex_example.py models personal
```

浏览器完成同意后，本机 `127.0.0.1` 的 `/auth/callback` 接收授权码。示例校验 state、PKCE、ID token 的 RS256/JWKS 签名、issuer、audience、nonce、有效期和 subject。登录成功会打印 `Signed in: personal`；若缺少调用所需 scope，会报告身份验证成功但推理未获授权。`accounts` 显示 `personal (signed in)`，`models` 输出账号可见的模型 slug 和显示名。复制一个 slug 用于下一步。

凭据保存在 `$XDG_CONFIG_HOME/llm4cj-codex/accounts.json`，未设置 XDG 时使用 `$HOME/.config/llm4cj-codex/accounts.json`。目录权限为 0700，凭据和锁文件为 0600。刷新在文件锁下重新读取、执行一次旋转并原子保存；不同进程使用同一存储目录时共享此锁。host registration、client ID 和 subject 是账户绑定；标签相同而身份不一致时拒绝替换。

## 连续对话和工具

将命令中的 `<model-slug>` 替换成 `models` 输出的值。SSE 每轮发送完整 canonical history：

```sh
python3 scripts/codex_example.py chat personal <model-slug> sse
```

出现 `> ` 后输入提示词，再输入第二个提示词验证续轮；`/quit` 或 EOF 退出。WS 使用同一连接，符合历史与配置条件时发送 `previous_response_id` 和新增输入：

```sh
python3 scripts/codex_example.py chat personal <model-slug> ws
python3 scripts/codex_example.py chat personal <model-slug> ws --demo-tool
```

工具演示仅允许 `echo`，把 `text` 参数返回为 JSON 字符串，不执行 shell。它把工具声明放进 `LlmWireInitialContext`，将消息作为 `LlmWireInputItem.Message` 写入有序 transcript，并用该 transcript 调用 `validateReplyToolInputs(..., mode: Strict)`。回放 function call 和 tool result，每轮最多八次工具迭代。回复的 `messageSpans`、phase 和 encrypted reasoning 按原顺序续轮。只有经过终态验证的 canonical reply 才进入下一轮；屏幕上流式显示的 delta 在终态前属于临时观察。

access token 刷新或连接替换后创建新的 WS session，并从完整 history 开始。收到 `previous_response_not_found` 且尚未显示语义数据时，示例只重连重试一次；其他错误终止本轮。刷新受 `earliest_refresh_at` 限制。无刷新授权或 renewable session 被拒绝时需要重新登录；暂时性刷新失败保留现有凭据。

## 退出登录

退出登录尝试撤销 refresh token，并清除本机 token，保留重新登录需要的账户绑定：

```sh
python3 scripts/codex_example.py logout personal
python3 scripts/codex_example.py accounts
```

成功时显示 `Signed out locally; renewable session revoked.` 和 `personal (signed out)`。撤销请求未确认时仍清除本机 token，命令退出码为 3 并说明 remote revocation 未确认。

## 在自己的应用中使用 codec

核心包提供 `openAiCodexResponsesModelProfile`、`openAiCodexResponsesCodec` 和 `codec.newResponsesWebSocketSession()`。应用拥有 HTTP/WS client、OAuth、重试、model catalog 与 agent loop；[原生示例源码](../examples/codex_subscription/src/main.cj)可作为这些应用职责的参考。

| 传输 | 应用发送与接收 | 核心职责 |
| --- | --- | --- |
| HTTP/SSE | Bearer POST `https://api.openai.com/v1/responses`，body 来自 `encodeRequest(request, streaming: true).materialize()`；网络分片进入 HTTP stream decoder | 完整请求校验、SSE framing、Responses 终态协调 |
| WebSocket | Bearer upgrade `wss://api.openai.com/v1/responses`；发送 `session.prepare(request).body`，完整 text message 进入 `session.push` | `response.create`、一条活动响应、同连接续轮检查点与 Responses JSON 状态机 |

不发送 `chatgpt-account-id`。HTTP 请求固定 `store: false`，禁止 `maxOutputTokens` 和 prompt cache 控制。System instruction 只能有一条且在所有 Developer instructions 之前；function tools 使用 developer `additional_tools`。OpenAI wire phase 只接受缺失或 null、`commentary`、`final_answer`；通过 continuation 保留 spans，避免把两个相邻 assistant message 合并。模型能力需由应用声明，未知字段不能通过 native JSON 绕过校验。

首版支持文本、受约束 encrypted reasoning 和 function tools。custom tools、非空 tool namespace、文本 annotations/logprobs 等不在可回放范围内，明确返回错误。单条请求/WS JSON message 限 8 MiB；decoder 的事件、语义和 retained state 限额由 `LlmWireStreamLimits` 配置。`{detail: ...}` HTTP 错误与 WS `error` 保留有界 diagnostic 和实际状态，见 [API reference](api-reference.md)。

独立示例的离线检查不代表真实账户获准或 provider 调用成功。真实登录、模型、SSE/WS、配额和远端撤销的结果应按实际运行记录，参见 [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)。
