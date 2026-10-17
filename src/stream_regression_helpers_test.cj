package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func streamRegressionValue<T>(result: LlmWireResult<T>): T {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}

func streamRegressionReply(terminal: LlmWireTerminal): LlmWireReply {
    match (terminal) { case LlmWireTerminal.Completed(value) => value; case _ => throw IllegalStateException("expected completed reply") }
}

func streamRegressionFixed(codec: LlmWireCodec, body: String): LlmWireReply {
    match (streamRegressionValue(codec.decodeResponse(LlmWireHttpResponse(200, [], body.toArray())))) {
        case LlmWireResponseState.Terminal(value) => streamRegressionReply(value)
        case _ => throw IllegalStateException("expected terminal response")
    }
}

func streamRegressionPush(decoder: LlmWireStreamDecoder, data: String): LlmWireStreamUpdate {
    streamRegressionValue(decoder.push(("data: " + data + "\n\n").toArray()))
}

func streamRegressionBytes(codec: LlmWireCodec, source: String, width: Int64): LlmWireReply {
    let decoder = codec.newStreamDecoder()
    let bytes = source.toArray()
    var offset: Int64 = 0
    var terminal: ?LlmWireTerminal = None
    while (offset < bytes.size) {
        let end = min(offset + width, bytes.size)
        let update = streamRegressionValue(decoder.push(bytes[offset..end]))
        match (update.terminal) { case Some(value) => terminal = Some(value); case None => () }
        offset = end
    }
    let finished = streamRegressionValue(decoder.finish())
    match (finished.terminal) { case Some(value) => terminal = Some(value); case None => () }
    streamRegressionReply(terminal.getOrThrow())
}

func streamRegressionLogprobsEqual(actual: Array<LlmWireTokenLogprob>, expected: Array<LlmWireTokenLogprob>): Unit {
    @Expect(actual.size, expected.size)
    for (index in 0..min(actual.size, expected.size)) {
        let left = actual[index]; let right = expected[index]
        @Expect(left.token, right.token); @Expect(left.logprob.stringify(), right.logprob.stringify())
        @Expect(left.bytes.size, right.bytes.size)
        for (byteIndex in 0..min(left.bytes.size, right.bytes.size)) { @Expect(left.bytes[byteIndex], right.bytes[byteIndex]) }
        @Expect(left.topLogprobs.size, right.topLogprobs.size)
        for (candidateIndex in 0..min(left.topLogprobs.size, right.topLogprobs.size)) {
            let a = left.topLogprobs[candidateIndex]; let b = right.topLogprobs[candidateIndex]
            @Expect(a.token, b.token); @Expect(a.logprob.stringify(), b.logprob.stringify())
            @Expect(a.bytes.size, b.bytes.size)
            for (byteIndex in 0..min(a.bytes.size, b.bytes.size)) { @Expect(a.bytes[byteIndex], b.bytes[byteIndex]) }
        }
    }
}

func streamRegressionUsageEqual(actual: LlmWireUsage, expected: LlmWireUsage): Unit {
    @Expect(actual.inputTokens, expected.inputTokens); @Expect(actual.outputTokens, expected.outputTokens)
    @Expect(actual.reasoningTokens, expected.reasoningTokens); @Expect(actual.totalTokens, expected.totalTokens)
    @Expect(actual.cacheReadTokens, expected.cacheReadTokens); @Expect(actual.cacheWriteTokens, expected.cacheWriteTokens)
    @Expect(actual.webSearchRequests, expected.webSearchRequests); @Expect(actual.webFetchRequests, expected.webFetchRequests)
    @Expect(actual.serviceTier, expected.serviceTier); @Expect(actual.source, expected.source)
    @Expect(actual.cacheReadAvailability, expected.cacheReadAvailability); @Expect(actual.cacheWriteAvailability, expected.cacheWriteAvailability)
}

func streamRegressionError(result: LlmWireResult<LlmWireStreamUpdate>): LlmWireError {
    match (result) { case LlmWireResult.Err(error) => error; case _ => throw IllegalStateException("expected stream error") }
}

func streamRegressionFixedError(codec: LlmWireCodec, source: String): LlmWireError {
    match (codec.decodeResponse(LlmWireHttpResponse(200, [], source.toArray()))) {
        case LlmWireResult.Err(error) => error
        case _ => throw IllegalStateException("expected fixed decode error")
    }
}
