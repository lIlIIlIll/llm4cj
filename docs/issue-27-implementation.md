# Issue #27：实施与证据

跟踪：[issue #27](https://github.com/lIlIIlIll/llm4cj/issues/27)。本页所有检查证据绑定已发布源码 [b8bd5b6fd41349900a3806212c63f62694379385](https://github.com/lIlIIlIll/llm4cj/commit/b8bd5b6fd41349900a3806212c63f62694379385)，source tree 为 `7d90a026175cebb7aedb109fe4d2ff49ca8f5a04`，分支为 `feat/ordered-transcript-issue-27`。本地检查、真实 provider 结果和正式发布分别验收。

Consumer/probe 编译 workaround 与最终 gate helper 发布于 [02d9b60f29a41fb14e641dfc9fba3f5cf7972a64](https://github.com/lIlIIlIll/llm4cj/commit/02d9b60f29a41fb14e641dfc9fba3f5cf7972a64)；核心源码、依赖版本与协议 fixtures 仍与 b8bd5b6 一致。`-O1` 结果只代表显式资格范围，不替代默认优化下的失败记录。

| 工作项 | 实现/消费契约 | 当前候选门禁与仍需的证据 |
| --- | --- | --- |
| W0 ADR | [ADR 0002](adr/0002-ordered-transcript.md) 固定类型、身份、时序、不变量、能力、错误、snapshot version 1 和 breaking 范围 | 文档/API 基线门禁通过；endpoint 能力仍为 CallerDeclared |
| W1 transcript/builder | src/transcript.cj、src/transcript_snapshot.cj、src/request_builder.cj；单一输入、嵌套冻结、append、snapshot/restore | 最低工具链测试通过，覆盖 ingress/getter mutation、完整 metadata、旧/未知版本、depth、builder 原子性 |
| W2 时序/错误 | src/transcript_validation.cj、src/context_contract.cj；逐时点 active state、末端 reply admission、schema 原屏障、失败 usage/source | 最低工具链测试通过，覆盖 unknown/inactive、重复/冲突、placement、pending tool 结果、全部 choice、bounded diagnostic |
| W3 Responses | additional_tools 在历史之后生效；原位置再次回放；无 fallback | 最低工具链 full-body/header golden、已有片段相等、长历史与恢复性质通过 |
| W4 Anthropic | 初始 deferred 池 + tool_reference 激活/撤销；指令更新/插入点、beta、automatic cache_control | 最低工具链 golden/负例通过；新 schema/替换/池扩展拒绝；显式内容级缓存断点未建模，不宣称交付 |
| W5 Kimi | 具体 model/endpoint 绑定；完整定义 system.tools 与独立 system.content；native reasoning 保持来源 | 最低工具链 golden、content/tools 互斥、unsupported 操作、fixed/stream reasoning 与回放通过 |
| W6 离线/live | golden/property/集成测试进入普通门禁；public transcript probe 和重复对照 harness | 最低工具链完整 check、最新 stable coverage 与显式 -O1 consumer/probe 完整 profile 通过；最新 stable 默认优化消费资格因编译器崩溃未通过；[三条 live 路径均 Not run](cache-experiments.md) |
| W7 breaking/消费者 | package 0.3.0；API/error/fixture snapshots、README/examples/迁移说明；外部消费者与 [Axyndra typed port 补丁](../support/axyndra/README.md) | 三个本地 consumer 与 Axyndra published dependency pin gate 通过；Axyndra SDK 1.1 默认与 SDK 1.2 显式 -O1 资格分开记录；远端 CI/provider smoke/release tag 分别验收 |

## 当前检查结果

记录日期：2026-10-02。以下只记录本轮已实际运行的检查；运行中的命令尚不算通过。

| 命令/门禁 | 结果 |
| --- | --- |
| python3 scripts/check_docs.py | Passed：23 Markdown 文件，132 public declarations |
| python3 scripts/check_contract.py | Passed：132 declarations、528 API shapes、233 codes、21 fixtures |
| python3 scripts/check_api_compat.py | Passed：v0.2.0 → 0.3.0 breaking bump |
| python3 scripts/cache_experiment.py --self-test | Passed：unknown/真实零与计数类型检查；零网络调用 |
| Python 编译检查与 git diff --check | Passed |
| Cangjie 1.1.0 cjpm check / build / test | Passed：138/138（133 core、5 experimental） |
| scripts/check_local_consumers.sh | Passed：stable、experimental、transcript 三个 consumer |
| Axyndra SDK 1.1 --git-pin gate（默认优化） | Passed：固定 b8bd5b6，check/build、41/41、6 pin regression、36 lock 闭包；SDK dependency Git HEAD 独立核对一致 |
| Axyndra SDK 1.2 --git-pin gate（显式 -O1） | Passed：合法 workspace 根 override，完整 gate exit 0；固定 b8bd5b6，check/build、41/41、6 pin regression；审计实际 yjson 编译参数为 -O2 -O1（末尾 override 生效），model_adapters 入口为 -O1 |
| Cangjie 1.1.0 scripts/check.sh | Passed：完整脚本 exit 0；138/138、三个 consumer、docs/examples/contracts、离线 cache public consumer 与安全检查 |
| Cangjie 1.2.0 coverage.sh | Passed：138/138；project line 3725/3795（98.2%）、branch 4465/5310（84.1%）；相对 main baseline 4a4be27 的 patch line 954/962（99.2%）、branch 695/782（88.9%） |
| Cangjie 1.2.0 默认优化 scripts/check.sh | Failed：138/138、docs/contracts、cache public probe、fixtures 与库 build 曾通过；external consumer 和重验中的文档入口编译 yjson 时 bundled LLVM llc -O2 SIGSEGV，exit 139；两次完整脚本均 exit 1。保存失败 IR 在默认/无限 stack 下仍复现 |
| Cangjie 1.2.0 -O1 consumer/probe profile | Passed：完整 scripts/check.sh exit 0，138/138，docs/cache/fixtures/三个 consumer 通过；显式 LLM4CJ_CONSUMER_COMPILE_OPTION=-O1，verbose 审计 macro/yjson/llm4cj/experimental/入口均应用 -O1；核心自己的 check/build/test 保持默认优化 |
| 最终 helper：Python regressions / provider trust | Passed：18/18；provider smoke 信任边界检查通过 |
| 最终 helper：Cangjie 1.1 scripts/check.sh | Passed：最终 02d9b60 gate/helper，默认编译选项，完整脚本 exit 0；138/138、三个 consumer 与全部 gate 通过 |
| 默认优化 remote CI | [CI run 37001048141](https://github.com/lIlIIlIll/llm4cj/actions/runs/37001048141) 的 coverage/contract/PR metadata 通过；stable job 编译 yjson 时 LLVM llc -O2 exit 139，重验仍失败 |
| Draft PR / workaround remote CI | [PR #28](https://github.com/lIlIIlIll/llm4cj/pull/28)；harness commit 02d9b60f29a41fb14e641dfc9fba3f5cf7972a64 的 [CI run 37004440394](https://github.com/lIlIIlIll/llm4cj/actions/runs/37004440394) All Passed：minimum、stable、coverage、contract 四个 job 全部成功 |
| 三条 live cache experiment / provider smoke / release | Not run |

本页记录已完成的 source/harness 检查。后续仅更新文档的提交也会触发新 CI；PR 当前 head 的验收以 [实时 Checks](https://github.com/lIlIIlIll/llm4cj/pull/28/checks) 为准。

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
scripts/check_axyndra_consumer.sh /absolute/path/to/Axyndra --git-pin
```

API、error inventory 和 fixture digest 按已绑定的实际源码生成。native fixture 额外校验 primary source、固定核对日期、endpoint/model/contract 及 live_verified=false。`check_docs` 校验 public reference 与编译样本同步；`check_api_compat` 要求 0.2.0 → 0.3.0 breaking bump。数量与通过状态以当前实跑 gate 输出为准。

SDK 1.2 consumer/probe 的编译资格范围及上游 workaround 依据见[测试与发布](testing-and-releasing.md)。默认优化失败记录继续保留；显式 workaround profile 的完整脚本已单独通过，不能将其成功推广为默认优化消费资格。

`cache_experiment.py --offline-check` 使用真实 public codec 构建 probe，验证三条路径各 3 个 warm/native/control 样本，检查缺失计数、明确零和失败 usage。网络调用数为 0。该检查通过只证明实验程序和离线编码/解码可用，不证明 live 缓存。

## 未运行项及完成条件

真实缓存证据需要独立固定 endpoint、model、options、长前缀、对照组、重复样本、read/write/source 和耗时；操作方法见 [缓存实验](cache-experiments.md)。没有提供三个 provider 的凭据和 live 响应，不把此项标成通过。

正式版本与 consumer 必须固定实际已审核 commit 或 tag。发布 tag、release/provider-smoke workflow 与远端 consumer 的状态不得由本地离线门禁推断。Axyndra 补丁的 ProviderTranscriptExchange/ProviderTranscriptPort 直接接收有序请求，离线 mock 验证动态声明、调用/结果、snapshot 回放和发送前拒绝；现有静态 ModelRequest adapter 保持初始上下文路径，明确拒绝无法恢复声明位置的历史。补丁使用本页绑定的真实 source SHA，published pin gate 已通过；远端合入与真实 provider 结果仍分别验收。

只完成一条 provider 或类型定义不能关闭 issue。离线实现、所有目标 native 路径、下游编译与实际证据按上述边界分别验收；live 项和发布项在未运行时继续保留。
