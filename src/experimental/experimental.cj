package llm4cj.experimental

import llm4cj.*

// Experimental APIs may change without the stable llm4cj compatibility guarantees.
public class LlmWireStandardDialect <: LlmWireDialect {
    private let value: LlmWireDialectContract

    public init(contract: LlmWireDialectContract) {
        if (reservedCompatibilityId(contract.compatibilityId)) {
            throw LlmWireError(
                LlmWireErrorKind.InvalidRequest,
                "llm.dialect_identity_reserved",
                "built-in compatibility IDs may only be used by built-in dialects"
            )
        }
        if (!contract.reasoningEfforts.isEmpty()) {
            throw LlmWireError(
                LlmWireErrorKind.Unsupported,
                "llm.dialect_thinking_replay_unsupported",
                "experimental custom dialects do not expose provider-native reasoning replay schemas"
            )
        }
        for (mode in contract.thinkingModes) {
            if (mode != LlmWireThinkingMode.ProviderDefault) {
                throw LlmWireError(
                    LlmWireErrorKind.Unsupported,
                    "llm.dialect_thinking_replay_unsupported",
                    "experimental custom dialects only support provider-default thinking"
                )
            }
        }
        this.value = contract
    }

    public prop contract: LlmWireDialectContract { get() { value } }
    public prop compatibilityId: String { get() { value.compatibilityId } }
    public prop protocol: LlmWireProtocol { get() { value.protocol } }
}

public func customDialectCodec(
    protocol: LlmWireProtocol,
    dialect: LlmWireDialect,
    capabilities!: LlmWireCapabilities = LlmWireCapabilities(),
    provider!: String = ""
): LlmWireCodec {
    experimentalCodec(protocol, dialect, capabilities: capabilities, provider: provider)
}

public class LlmWireCachePrewarmExchange {
    public let request: LlmWirePreparedRequest
    private let codec: LlmWireCodec

    init(codec: LlmWireCodec, request: LlmWirePreparedRequest) {
        this.codec = codec
        this.request = request
    }

    public func decodeResponse(
        response: LlmWireHttpResponse,
        nowEpochMillis!: Int64 = 0
    ): LlmWireResult<LlmWireUsage> {
        match (codec.decodeResponse(response, nowEpochMillis: nowEpochMillis)) {
            case LlmWireResult.Err(error) => LlmWireResult.Err(error)
            case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))) =>
                if (validPrewarmReply(reply)) {
                    LlmWireResult.Ok(reply.usage)
                } else {
                    LlmWireResult.Err(LlmWireError(
                        LlmWireErrorKind.InvalidWire,
                        "llm.cache_prewarm_response_invalid",
                        "cache pre-warm must complete with empty content and stop_reason=max_tokens"
                    ))
                }
            case _ => LlmWireResult.Err(LlmWireError(
                LlmWireErrorKind.InvalidWire,
                "llm.cache_prewarm_response_invalid",
                "cache pre-warm did not produce a completed Messages response"
            ))
        }
    }
}

public func prepareAnthropicCachePrewarm(
    codec: LlmWireCodec,
    request: LlmWireRequest
): LlmWireResult<LlmWireCachePrewarmExchange> {
    try {
        LlmWireResult.Ok(LlmWireCachePrewarmExchange(codec, encodeAnthropicCachePrewarm(codec, request)))
    } catch (error: LlmWireError) {
        LlmWireResult.Err(error)
    }
}

private func validPrewarmReply(reply: LlmWireReply): Bool {
    if (!reply.blocks.isEmpty() || reply.choices.size != 1) { return false }
    let choice = reply.choices[0]
    if (!choice.blocks.isEmpty() || choice.rawStopReason != "max_tokens") { return false }
    match (choice.outcome) {
        case LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.MaxTokens) => true
        case _ => false
    }
}

private func reservedCompatibilityId(value: String): Bool {
    value == "openai.responses.v1" || value == "openai.codex.responses.v1" || value == "openai.chat.v1" || value == "anthropic.messages.v1" ||
    value == "deepseek.responses.v1" || value == "deepseek.chat.v1" || value == "deepseek.messages.v1"
}
