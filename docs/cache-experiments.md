# 缓存实验与证据边界

证据绑定源码 [b8bd5b6fd41349900a3806212c63f62694379385](https://github.com/lIlIIlIll/llm4cj/commit/b8bd5b6fd41349900a3806212c63f62694379385)。库只声明确定性模型输入布局，未宣称任何原生路径的真实缓存收益。2026-10-02 的 live 状态如下：

| 路径 | 本地需要验证的内容 | Live cache 状态 | 缺少证据 |
| --- | --- | --- | --- |
| OpenAI Responses additional_tools | 初始 tools/input 保持；更新在历史之后 | Not run | 指定支持模型、有效凭据、可达端点、重复对照响应 |
| Anthropic Messages reference updates | 初始声明池/defer_loading 保持；引用激活/撤销及 beta | Not run | 指定支持模型、有效凭据、beta 接受结果、重复对照响应 |
| Kimi system.tools | 完整定义保留位置；content/tools 互斥 | Not run | kimi-k3 凭据、端点响应与重复对照记录 |

离线 golden/property/integration 用例证明编码和边界；文档 shape 核对、HTTP 200、本地 hash 或 stable input 布局均不证明 GPU KV 命中。新的模型、端点、协议布局或 initial context 基线需要独立实验。SDK 不做 cache warming、保活或成本调度。

## 可重现流程

`support/transcript_probe` 使用 public transcript/codec API 生成请求，并通过 public fixed decoder 提取 outcome 和 usage。`scripts/cache_experiment.py` 每条路径运行独立 warm/native/control 样本；不构造 raw provider body，不更改 codec 生成的字段，不添加兼容 fallback。warm 包含初始 A/B 与长 user 输入；native 在其后追加 C（Anthropic 从固定 deferred 池激活 C）；control 使用同样历史和 native 更新，但故意改动 initial instruction 和 A 描述以破坏早期输入基线。control 只用于实验，绝不作为生产失败后的回退。

先选择目标 endpoint/model，核对当前原生能力与最低可缓存长度，再复制并填写配置。配置样本的 OpenAI/Anthropic model 是必须替换的占位符；Kimi 契约固定为 kimi-k3 和文档 endpoint。能力记录是 caller declaration。凭据只从命名的环境变量读取，不能写入配置文件；beta header 由 codec 产生。

```sh
cp support/transcript_probe/cache-config.example.json /tmp/llm4cj-cache-config.json
# 编辑 /tmp/llm4cj-cache-config.json 的显式模型和选项；不写入凭据。
python3 scripts/cache_experiment.py --self-test
python3 scripts/cache_experiment.py --offline-check
python3 scripts/cache_experiment.py \
  --config /tmp/llm4cj-cache-config.json \
  --prepare-only --samples 5 --history-bytes 65536 \
  --output /tmp/llm4cj-cache-prepared.json
```

prepare-only 不发送请求，检查原生追加前后已有模型输入项和初始 tools/system 相等，control 确实改动基线。它记录每次请求的 input/body hash 和长度，仅作为可重现输入标记。

每次 prepare/live 命令都会先构建 public probe，再在同一 compiler wrapper 作用域运行，不能用环境变量猜测预编译 binary 的选项。输出 `probe_compilation` 记录实际 `override_compile_option`、作用范围及 fresh build；默认选项记录为 null。SDK 1.2.0 默认优化编译 yjson 的 LLVM 崩溃已复现，该工具链可显式设置 `LLM4CJ_CONSUMER_COMPILE_OPTION=-O1`。这一覆盖影响 probe 入口及全部依赖，并在失败后恢复 manifest；资格范围见[测试与发布](testing-and-releasing.md)。checkout 的 clean/SHA 状态在 wrapper 修改临时 manifest 前记录。

offline-check 会构建 probe，在无网络调用的情况下验证三条路径各 3 个样本的 warm/native/control 布局，并经 public decoder 核对缺失计数、明确零和 provider failure 前已观测 usage/source。它不接受 live 模型或凭据，不把 fixture-model 当作真实支持模型。

在干净且已固定的候选 commit 上配置 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY` 和 `MOONSHOT_API_KEY` 后运行：

```sh
python3 scripts/cache_experiment.py \
  --config /tmp/llm4cj-cache-config.json \
  --samples 5 --history-bytes 65536 --random-seed 27003 \
  --output /tmp/llm4cj-cache-observations.json
```

每条路径每个样本先 warm，再随机顺序发送 native/control，共 45 次网络调用（默认 5 个样本 × 3 个 arm × 3 条路径）。输出固定 candidate SHA、UTC 时间、endpoint/model/options、probe 编译选项、契约版本、prefix seed、arm 顺序、输入哈希与字节数、HTTP status、公共 codec outcome、端到端耗时和原生 read/write 计数。输出不保存凭据、prompt 或原始响应。请求不跟随 redirect，不自动重试；transport/provider/codec 失败保留在记录中，不删除失败样本。

`elapsed_ms` 是整次固定响应的网络耗时，含排队和生成，不是单独的 prefill 或 TTFT。预设 64 输出 token 并要求 OK 可减少生成差异，但不能消除 provider 负载噪声。65536 字节只表示生成前缀大小；provider tokenizer 的 token 数以返回 usage 或独立计数证据为准。如果不足最低缓存长度，扩大前缀并重新固定配置，不能把无命中样本当作布局失败。

## 解释观测

`LlmWireUsageSource.ProviderReported(provider, dialectId)` 记录来源，`Unknown` 不表示 provider 已报告。`cacheReadAvailability`/`cacheWriteAvailability` 在对应 Option 为 None 时为 Unknown，Some(0) 为 Reported。实验 JSON 把缺失计数保存为 null、availability 保存为 unknown；明确零保存为 0、reported。所有失败路径保持已经观测到的 usage，缺失信息不补零。

对每条路径分别比较 native/control 的 cache_read_tokens、cache_write_tokens 与耗时分布，报告原样本数、失败数、unknown 数和显式零数。不设固定命中率阈值；读缓存不为零证明该响应报告了命中，但不能推断永不淘汰、所有后续请求命中或工具更新单独导致全部收益。耗时差异没有 read/write 证据时只能称为耗时观测。HTTP 200 只证明该请求被接受；支持声明仍限定该 endpoint/model/options/契约版本/日期。

`docs/cache-evidence.json` 明确记录当前未运行项。应把实际 candidate 的独立实验结果附入 PR/release 证据后再声明缓存收益。live 实验不替代离线回归和普通 release/provider smoke 门禁。
