# Issue #27：实施与证据

跟踪：[issue #27](https://github.com/lIlIIlIll/llm4cj/issues/27)。恢复工作基于 `4a4be27ce38aad0eb94553b484e83fa8d15b3f6b`，使用新分支 `feat/ordered-transcript-issue-27`；已有的远端 `feat/ordered-transcript` 实现保持原样。先前 scratch 丢失后，源码由保留的工具上下文重建；重建候选不是原提交，先前通过结果不能作为当前候选证据。当前运行门禁、真实 provider 结果和正式发布必须重新分别记录。

| 工作项 | 实现/消费契约 | 当前候选门禁与仍需的证据 |
| --- | --- | --- |
| W0 ADR | [ADR 0002](adr/0002-ordered-transcript.md) 固定类型、身份、时序、不变量、能力、错误、snapshot version 1 和 breaking 范围 | 恢复后需核对源码；endpoint 能力仍为 CallerDeclared |
| W1 transcript/builder | src/transcript.cj、src/transcript_snapshot.cj、src/request_builder.cj；单一输入、嵌套冻结、append、snapshot/restore | 重新运行 src/transcript_test.cj 的 ingress/getter mutation、完整 metadata、旧/未知版本、depth、builder 原子性用例 |
| W2 时序/错误 | src/transcript_validation.cj、src/context_contract.cj；逐时点 active state、末端 reply admission、schema 原屏障、失败 usage/source | 重新运行 unknown/inactive、重复/冲突、placement、pending tool 结果、全部 choice、bounded diagnostic 用例 |
| W3 Responses | additional_tools 在历史之后生效；原位置再次回放；无 fallback | 重跑 fixtures/transcripts/openai-responses.json full-body/header golden、已有片段相等、长历史与恢复性质 |
| W4 Anthropic | 初始 deferred 池 + tool_reference 激活/撤销；指令更新/插入点、beta、automatic cache_control | 重跑 fixtures/transcripts/anthropic-messages.json；新 schema/替换/池扩展拒绝；显式内容级缓存断点未建模，不宣称交付 |
| W5 Kimi | 具体 model/endpoint 绑定；完整定义 system.tools 与独立 system.content；native reasoning 保持来源 | 重跑 fixtures/transcripts/kimi-chat.json、content/tools 互斥、unsupported 操作、fixed/stream reasoning 与回放 |
| W6 离线/live | golden/property/集成测试进入普通门禁；public transcript probe 和重复对照 harness | 重建候选离线 checks 待实跑；[三条 live 路径均 Not run](cache-experiments.md)，不宣称缓存收益 |
| W7 breaking/消费者 | package 0.3.0；API/error/fixture snapshots、README/examples/迁移说明；外部消费者与 [Axyndra typed port 补丁](../support/axyndra/README.md) | local external consumer 与真实 Axyndra adapter gate 分开重跑；远端 CI/provider smoke/release tag 等需当前 commit 实际证据 |

## 本地命令

以下为可复现门禁。成功结果必须绑定实际 candidate/source SHA；库构建需要最低 Cangjie 1.1.0 和 latest stable 两条工具链证据。

```sh
scripts/check.sh
scripts/coverage.sh
python3 scripts/check_contract.py
python3 scripts/check_api_compat.py
python3 scripts/cache_experiment.py --offline-check
scripts/check_local_consumers.sh
scripts/check_axyndra_consumer.sh /absolute/path/to/Axyndra
```

API、error inventory 和 fixture digest 必须按重建后实际源码重新生成，不能复用丢失候选的哈希。native fixture 额外校验 primary source、固定核对日期、endpoint/model/contract 及 live_verified=false。`check_docs` 校验 public reference 与编译样本同步；`check_api_compat` 要求 0.2.0 → 0.3.0 breaking bump。数量与通过状态以当前实跑 gate 输出为准。

`cache_experiment.py --offline-check` 使用真实 public codec 构建 probe，验证三条路径各 3 个 warm/native/control 样本，检查缺失计数、明确零和失败 usage。网络调用数为 0。该检查通过只证明实验程序和离线编码/解码可用，不证明 live 缓存。

## 未运行项及完成条件

真实缓存证据需要独立固定 endpoint、model、options、长前缀、对照组、重复样本、read/write/source 和耗时；操作方法见 [缓存实验](cache-experiments.md)。没有提供三个 provider 的凭据和 live 响应，不把此项标成通过。

正式版本与 consumer 必须固定实际已审核 commit 或 tag。发布 tag、release/provider-smoke workflow 与远端 consumer 的状态不得由本地离线门禁推断。Axyndra 补丁的 ProviderTranscriptExchange/ProviderTranscriptPort 直接接收有序请求，离线 mock 验证动态声明、调用/结果、snapshot 回放和发送前拒绝；现有静态 ModelRequest adapter 保持初始上下文路径，明确拒绝无法恢复声明位置的历史。补丁尚需固定新的真实发布 source SHA，远端合入与真实 provider 结果仍分别验收。

只完成一条 provider 或类型定义不能关闭 issue。离线实现、所有目标 native 路径、下游编译与实际证据按上述边界分别验收；live 项和发布项在未运行时继续保留。
