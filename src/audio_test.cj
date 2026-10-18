package llm4cj

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func audioTestFormats(): Array<LlmWireAudioFormat> { [LlmWireAudioFormat.Wav, LlmWireAudioFormat.Mp3, LlmWireAudioFormat.Aac, LlmWireAudioFormat.Flac, LlmWireAudioFormat.Opus, LlmWireAudioFormat.Pcm16] }
func audioTestCodec(replay!: Bool = true): LlmWireCodec {
    let formats = audioTestFormats()
    openAiChatCodec(openAiChatModelProfile("audio-model", capabilities: LlmWireCapabilities(
        input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Audio]), tools: LlmWireToolCapabilities(enabled: true),
        audio: LlmWireAudioCapabilities(inputFormats: [LlmWireAudioFormat.Wav, LlmWireAudioFormat.Mp3], fixedOutputFormats: formats,
            streamOutputFormats: formats, voices: [LlmWireAudioVoice.Alloy, LlmWireAudioVoice.Ash, LlmWireAudioVoice.Ballad, LlmWireAudioVoice.Coral, LlmWireAudioVoice.Echo, LlmWireAudioVoice.Fable,
                LlmWireAudioVoice.Nova, LlmWireAudioVoice.Onyx, LlmWireAudioVoice.Sage, LlmWireAudioVoice.Shimmer, LlmWireAudioVoice.Verse, LlmWireAudioVoice.Marin, LlmWireAudioVoice.Cedar], assistantReplay: replay))))
}
func audioTestRequest(format: LlmWireAudioFormat, voice!: LlmWireAudioVoice = LlmWireAudioVoice.Alloy): LlmWireRequest {
    LlmWireRequest("audio-model", LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))]))]), maxOutputTokens: Some(16), audioOutput: Some(LlmWireAudioOutputOptions(format, voice)))
}
func audioTestContext(codec: LlmWireCodec, format: LlmWireAudioFormat): LlmWireResponseContext { codec.encodeRequest(audioTestRequest(format)).responseContext }
func audioTestBody(audio: String, reason!: String = "stop"): String {
    "{\"id\":\"r\",\"model\":\"resolved-audio-model\",\"choices\":[{\"index\":0,\"finish_reason\":\"" + reason + "\",\"message\":{\"content\":\"text\",\"audio\":" + audio + "}}],\"usage\":{\"prompt_tokens_details\":{\"audio_tokens\":0},\"completion_tokens_details\":{\"audio_tokens\":2}}}"
}
func audioTestObject(data!: String = "AAECA/7/", id!: String = "a", transcript!: String = "spoken"): String {
    "{\"id\":\"" + id + "\",\"data\":\"" + data + "\",\"transcript\":\"" + transcript + "\",\"expires_at\":100}"
}
func audioTestFixed(codec: LlmWireCodec, context: LlmWireResponseContext, audio: String, reason!: String = "stop"): LlmWireReply {
    match (streamRegressionValue(codec.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audio, reason: reason).toArray()), responseContext: Some(context)))) {
        case LlmWireResponseState.Terminal(value) => streamRegressionReply(value)
        case _ => throw IllegalStateException("expected terminal audio reply")
    }
}
func audioTestBlock(reply: LlmWireReply): LlmWireAudioOutputBlock {
    for (block in reply.blocks) { match (block) { case LlmWireOutputBlock.Audio(value) => return value; case _ => () } }
    throw IllegalStateException("missing audio block")
}
func audioTestStream(codec: LlmWireCodec, context: LlmWireResponseContext, source: String, width: Int64): LlmWireReply {
    let decoder = streamRegressionValue(codec.newHttpStreamDecoder(200, responseContext: Some(context)))
    let bytes = source.toArray(); var offset: Int64 = 0; var terminal: ?LlmWireTerminal = None
    while (offset < bytes.size) {
        let end = min(bytes.size, offset + width)
        let update = streamRegressionValue(decoder.push(bytes[offset..end]))
        match (update.terminal) { case Some(value) => terminal = Some(value); case None => () }; offset = end
    }
    let _ = streamRegressionValue(decoder.finish())
    streamRegressionReply(terminal.getOrThrow())
}
func audioTestSource(reason!: String = "stop", tail!: Bool = true): String {
    "data: {\"id\":\"r\",\"model\":\"resolved-audio-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"text\",\"audio\":{\"id\":\"a\"}}}]}\n\n" +
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"data\":\"AAEC\",\"transcript\":\"spo\"}}}]}\n\n" +
    "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"" + reason + "\",\"delta\":{\"audio\":{\"data\":\"A/7/\",\"transcript\":\"ken\"}}}]}\n\n" +
    (if (tail) { "data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"expires_at\":100}}}]}\n\n" } else { "" }) +
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens_details\":{\"audio_tokens\":0},\"completion_tokens_details\":{\"audio_tokens\":2}}}\n\ndata: [DONE]\n\n"
}

@Test
class AudioTests {
    @TestCase
    func allFormatsPreserveFixedAndStreamedTypedAudio() {
        let codec = audioTestCodec()
        for (format in audioTestFormats()) {
            let prepared = codec.encodeRequest(audioTestRequest(format))
            let body = streamRegressionValue(LlmWireJson.parse(String.fromUtf8(streamRegressionValue(prepared.materialize()).body)))
            @Expect(body.field("audio").getOrThrow().field("format").getOrThrow().stringValue().isSome(), true)
            @Expect(prepared.responseContext.model, "audio-model")
            let fixed = audioTestFixed(codec, prepared.responseContext, audioTestObject())
            @Expect(fixed.model, "resolved-audio-model")
            for (width in [1, 17, 65536]) {
                let streamed = audioTestStream(codec, prepared.responseContext, audioTestSource(), width)
                let left = audioTestBlock(streamed); let right = audioTestBlock(fixed)
                @Expect(left.format, format); @Expect(left.id, right.id); @Expect(left.transcript, right.transcript)
                @Expect(left.expiresAtEpochSeconds, right.expiresAtEpochSeconds); @Expect(left.completion, LlmWireAudioCompletion.Complete)
                @Expect(left.bytes.size, 6)
                for (index in 0..6) { @Expect(left.bytes[index], right.bytes[index]) }
                @Expect(streamed.usage.audioInputTokens, Some(0)); @Expect(streamed.usage.audioOutputTokens, Some(2))
            }
        }
    }

    @TestCase
    func rfc4648VectorsAndBinaryInputRemainImmutableAndOrdered() {
        let codec = audioTestCodec()
        for ((text, encoded) in [("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy")]) {
            let bytes = text.toArray(); let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, bytes))
            bytes[0] = 0u8; let observed = input.bytes; observed[0] = 0u8
            let request = LlmWireRequest("audio-model", LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User,
                [LlmWireBlock.Text(LlmWireTextBlock("before")), LlmWireBlock.AudioInput(input), LlmWireBlock.Text(LlmWireTextBlock("after"))]))]))
            let raw = String.fromUtf8(streamRegressionValue(codec.encodeRequest(request).materialize()).body)
            let body = streamRegressionValue(LlmWireJson.parse(raw)); let parts = body.field("messages").getOrThrow().values()[0].field("content").getOrThrow().values()
            @Expect(parts.size, 3); @Expect(parts[0].field("text").getOrThrow().stringValue(), Some("before"))
            @Expect(parts[1].field("input_audio").getOrThrow().field("data").getOrThrow().stringValue(), Some(encoded))
            @Expect(parts[2].field("text").getOrThrow().stringValue(), Some("after"))
            let decoded = audioTestBlock(audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Wav), audioTestObject(data: encoded)))
            @Expect(String.fromUtf8(decoded.bytes), text)
        }
        let binary = Array<Byte>(256, { index => UInt8(index) })
        for (format in [LlmWireAudioFormat.Wav, LlmWireAudioFormat.Mp3]) {
            let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(format, binary))
            let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.AudioInput(input)]))])
            let snapshot = streamRegressionValue(transcript.snapshot())
            @Expect(snapshot.contains("\"version\":3"), true)
            @Expect(streamRegressionValue(streamRegressionValue(LlmWireTranscript.restore(snapshot)).snapshot()), snapshot)
        }
    }

    @TestCase
    func everyKnownVoiceIsExplicitlyEncodedAndCapabilitiesGateModes() {
        let codec = audioTestCodec()
        let cases = [(LlmWireAudioVoice.Alloy,"alloy"),(LlmWireAudioVoice.Ash,"ash"),(LlmWireAudioVoice.Ballad,"ballad"),(LlmWireAudioVoice.Coral,"coral"),(LlmWireAudioVoice.Echo,"echo"),(LlmWireAudioVoice.Fable,"fable"),(LlmWireAudioVoice.Nova,"nova"),(LlmWireAudioVoice.Onyx,"onyx"),(LlmWireAudioVoice.Sage,"sage"),(LlmWireAudioVoice.Shimmer,"shimmer"),(LlmWireAudioVoice.Verse,"verse"),(LlmWireAudioVoice.Marin,"marin"),(LlmWireAudioVoice.Cedar,"cedar")]
        for ((voice, name) in cases) {
            let request = codec.encodeRequest(audioTestRequest(LlmWireAudioFormat.Wav, voice: voice))
            let json = streamRegressionValue(LlmWireJson.parse(String.fromUtf8(streamRegressionValue(request.materialize()).body)))
            @Expect(json.field("audio").getOrThrow().field("voice").getOrThrow().stringValue(), Some(name))
        }
        let limited = openAiChatCodec(openAiChatModelProfile("audio-model", capabilities: LlmWireCapabilities(audio: LlmWireAudioCapabilities(
            streamOutputFormats: [LlmWireAudioFormat.Wav], voices: [LlmWireAudioVoice.Alloy]))))
        let builder = limited.newRequestBuilder(); builder.appendMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))]))
        builder.setAudioOutput(Some(LlmWireAudioOutputOptions(LlmWireAudioFormat.Wav, LlmWireAudioVoice.Alloy)))
        let request = streamRegressionValue(builder.build())
        expectLlmError("llm.audio_output_format_unsupported", { => let _ = limited.encodeRequest(request) })
        let _ = limited.encodeRequest(request, streaming: true)
        expectLlmError("llm.audio_voice_unsupported", { => let _ = limited.encodeRequest(audioTestRequest(LlmWireAudioFormat.Wav, voice: LlmWireAudioVoice.Cedar), streaming: true) })
        for (format in [LlmWireAudioFormat.Aac, LlmWireAudioFormat.Flac, LlmWireAudioFormat.Opus, LlmWireAudioFormat.Pcm16]) { @Expect(LlmWireAudioInputBlock.fromBytes(format, [1u8]).isOk(), false) }
        @Expect(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, []).isOk(), false)
    }

    @TestCase
    func malformedBase64AndCrossFieldFragmentsFailClosed() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        for (value in ["Zg=", "Zh==", "Zm9=", "Z===", "=AAA", "AA=A", "AAAA=AAA", "AAAA AAA", "AA_A", "AA-A", "éAA"]) {
            @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audioTestObject(data: value)).toArray()), responseContext: Some(context)).isOk(), false)
            let decoder = codec.newStreamDecoder(responseContext: Some(context))
            let result = decoder.push(("data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"data\":\"" + value + "\"}}}]}\n\n").toArray())
            @Expect(result.isOk(), false)
        }
        let decoder = codec.newStreamDecoder(responseContext: Some(context))
        let error = streamRegressionError(decoder.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"data\":\"Zg\"}}}]}\n\n".toArray()))
        @Expect(error.code, "llm.audio_framing_unsupported")
        let padded = audioTestSource().replace("AAEC", "AA==").replace("A/7/", "AQ==")
        let bytes = audioTestBlock(audioTestStream(codec, context, padded, 1)).bytes
        @Expect(bytes.size, 2); @Expect(bytes[0], 0u8); @Expect(bytes[1], 1u8)
    }

    @TestCase
    func replayRequiresExplicitClockOriginCapabilityAndSnapshotVersion() {
        let codec = audioTestCodec(); let reply = audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Mp3), audioTestObject())
        let messages = reply.toContinuationInput()
        let transcript = LlmWireTranscript(items: messages.map({ value: LlmWireMessage => LlmWireInputItem.Message(value) }))
        let prepared = codec.encodeRequest(LlmWireRequest("audio-model", transcript))
        @Expect(prepared.materialize().isOk(), false)
        @Expect(prepared.materialize(nowEpochSeconds: Some(-1)).isOk(), false)
        @Expect(prepared.materialize(nowEpochSeconds: Some(100)).isOk(), false)
        let raw = String.fromUtf8(streamRegressionValue(prepared.materialize(nowEpochSeconds: Some(99))).body)
        let json = streamRegressionValue(LlmWireJson.parse(raw)); let assistant = json.field("messages").getOrThrow().values()[0]
        @Expect(assistant.field("audio").getOrThrow().field("id").getOrThrow().stringValue(), Some("a"))
        @Expect(assistant.field("audio").getOrThrow().field("data").isNone(), true)
        expectLlmError("llm.audio_replay_capability_missing", { => let _ = audioTestCodec(replay: false).encodeRequest(LlmWireRequest("audio-model", transcript)) })
        let differentModel = openAiChatCodec(openAiChatModelProfile("other-model", capabilities: codec.capabilities))
        expectLlmError("llm.audio_replay_origin_mismatch", { => let _ = differentModel.encodeRequest(LlmWireRequest("other-model", transcript)) })
        let snapshot = streamRegressionValue(transcript.snapshot())
        let restored = streamRegressionValue(LlmWireTranscript.restore(snapshot))
        @Expect(streamRegressionValue(restored.snapshot()), snapshot)
        @Expect(codec.encodeRequest(LlmWireRequest("audio-model", restored)).materialize(nowEpochSeconds: Some(99)).isOk(), true)
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"version\":3", "\"version\":2")).isOk(), false)
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"dialect_id\":\"openai.chat.v1\"", "\"dialect_id\":\"deepseek.chat.v1\"")).isOk(), false)
    }

    @TestCase
    func incompleteAudioPreservesOutcomeButNeverMintsReplay() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Pcm16)
        for (reason in ["length", "content_filter"]) {
            let fixed = audioTestFixed(codec, context, audioTestObject(), reason: reason)
            let streamed = audioTestStream(codec, context, audioTestSource(reason: reason), 1)
            @Expect(audioTestBlock(fixed).completion, LlmWireAudioCompletion.Partial)
            @Expect(audioTestBlock(streamed).completion, LlmWireAudioCompletion.Partial)
            @Expect(fixed.toContinuationInput(0).isOk(), false); @Expect(streamed.choices[0].toContinuationInput().isOk(), false)
        }
        for (field in ["\"id\":\"a\",", "\"data\":\"AAECA/7/\",", "\"transcript\":\"spoken\",", ",\"expires_at\":100"]) {
            let audio = audioTestObject().replace(field, "")
            @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audio).toArray()), responseContext: Some(context)).isOk(), false)
        }
        let decoder = codec.newStreamDecoder(responseContext: Some(context)); let source = audioTestSource(tail: false)
        @Expect(decoder.push(source.toArray()).isOk(), false)
        let empty = audioTestBlock(audioTestFixed(codec, context, audioTestObject(data: "", transcript: "")))
        @Expect(empty.bytes.size, 0); @Expect(empty.transcript, "")
    }

    @TestCase
    func expiryOnlyTailAllowsNullEnvelopeButNeverRepeatedFinishOrPayload() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        let tail = "\"index\":0,\"delta\":{\"audio\":{\"expires_at\":100}}"
        let nullable = "\"index\":0,\"finish_reason\":null,\"logprobs\":null,\"delta\":{\"audio\":{\"expires_at\":100}}"
        let _ = audioTestStream(codec, context, audioTestSource().replace(tail, nullable), 1)
        for (extra in ["\"finish_reason\":\"stop\",", "\"logprobs\":{},"]) {
            let source = audioTestSource().replace(tail, extra + tail)
            @Expect(codec.newStreamDecoder(responseContext: Some(context)).push(source.toArray()).isOk(), false)
        }
        let after = audioTestSource().replace("data: [DONE]", "data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"data\":\"AA==\"}}}]}\n\ndata: [DONE]")
        @Expect(codec.newStreamDecoder(responseContext: Some(context)).push(after.toArray()).isOk(), false)
    }

    @TestCase
    func extractedReplayCannotMoveBeforeTextOrAcrossCanonicalBlocks() {
        let codec = audioTestCodec(); let reply = audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Wav), audioTestObject())
        let blocks = reply.toContinuationInput()[0].blocks
        for (moved in [[blocks[1], blocks[0]], [blocks[1]]]) {
            let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, moved))])
            expectLlmError("llm.audio_replay_position_invalid", { => let _ = codec.encodeRequest(LlmWireRequest("audio-model", transcript)) })
            @Expect(transcript.snapshot().isOk(), false)
        }
        let snapshot = streamRegressionValue(LlmWireTranscript(items: [LlmWireInputItem.Message(reply.toContinuationInput()[0])]).snapshot())
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"block_order\":1", "\"block_order\":0")).isOk(), false)
        let native = LlmWireNativeReplayBlock.restore("{\"protocol\":\"chat_completions\",\"dialect_id\":\"deepseek.chat.v1\",\"native_type\":\"reasoning_content\",\"schema_version\":1,\"scope\":\"assistant_turn\",\"assistant_turn_index\":0,\"block_order\":0,\"complete\":true,\"payload\":{\"type\":\"reasoning_content\",\"reasoning_content\":\"thought\"}}")
        let schema = streamRegressionValue(LlmWireJson.parse("{\"type\":\"object\"}"))
        let args = streamRegressionValue(LlmWireJson.object([]))
        for (prefix in [LlmWireBlock.NativeReplay(native), LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "lookup", LlmWireToolArguments.Complete(args)))]) {
            let items = ArrayList<LlmWireInputItem>([LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [prefix, blocks[1]]))])
            match (prefix) { case LlmWireBlock.ToolCall(_) => items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User,
                [LlmWireBlock.ToolResult(LlmWireToolResultBlock("c", [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))]))]))); case _ => () }
            let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(LlmWireTool("lookup", "lookup", schema))]),
                items: items.toArray())
            expectLlmError("llm.audio_replay_position_invalid", { => let _ = codec.encodeRequest(LlmWireRequest("audio-model", transcript)) })
            @Expect(transcript.snapshot().isOk(), false)
        }
    }

    @TestCase
    func contextAndAudioDialectAreCheckedWithoutGuessingAliases() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audioTestObject()).toArray())).isOk(), false)
        let plain = LlmWireRequest("audio-model", LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))]))]))
        @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audioTestObject()).toArray()), responseContext: Some(codec.encodeRequest(plain).responseContext)).isOk(), false)
        let other = openAiChatCodec(openAiChatModelProfile("other-model"))
        @Expect(other.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audioTestObject()).toArray()), responseContext: Some(context)).isOk(), false)
        for (dialect in [openAiResponsesDialect(), openAiCodexResponsesDialect(), anthropicMessagesDialect(), deepSeekResponsesDialect(), deepSeekChatDialect(), deepSeekMessagesDialect(), kimiChatDialect()]) {
            let otherCodec = LlmWireCodec(dialect.contract.protocol, dialect, capabilities: codec.capabilities)
            expectLlmError("llm.audio_dialect_unsupported", { => let _ = otherCodec.encodeRequest(audioTestRequest(LlmWireAudioFormat.Wav)) })
        }
    }

    @TestCase
    func retainedAndSemanticAudioBudgetsRejectBeforeEmission() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        for ((limit, accepted) in [(1, false), (2, true)]) {
            let decoder = codec.newStreamDecoder(responseContext: Some(context), limits: LlmWireStreamLimits(maxRetainedStateBytes: limit))
            let result = decoder.push("data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"delta\":{\"audio\":{\"id\":\"a\",\"data\":\"AQ==\",\"transcript\":\"\",\"expires_at\":100}}}]}\n\ndata: [DONE]\n\n".toArray())
            @Expect(result.isOk(), accepted)
        }
        let input = LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, Array<Byte>(4194305, repeat: 0))
        @Expect(input.isOk(), false)
        let decoder = codec.newStreamDecoder(responseContext: Some(context), limits: LlmWireStreamLimits(maxTotalSemanticBytes: 1))
        @Expect(decoder.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"data\":\"AAEC\"}}}]}\n\n".toArray()).isOk(), false)
    }

    @TestCase
    func exactDecodedLimitAndAggregateChoicesAreBounded() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        let encoded = Array<Byte>(5592408, repeat: 65u8); encoded[5592406] = 61u8; encoded[5592407] = 61u8
        let data = String.fromUtf8(encoded)
        let accepted = audioTestBlock(audioTestFixed(codec, context, audioTestObject(data: data)))
        @Expect(accepted.bytes.size, 4194304); @Expect(accepted.bytes[4194303], 0u8)
        let exposed = accepted.bytes; exposed[0] = 255u8; @Expect(accepted.bytes[0], 0u8)
        encoded[5592406] = 65u8
        @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audioTestObject(data: String.fromUtf8(encoded))).toArray()), responseContext: Some(context)).isOk(), false)
        let choices = "{\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"message\":{\"audio\":" + audioTestObject(data: data) + "}},{\"index\":1,\"finish_reason\":\"stop\",\"message\":{\"audio\":" + audioTestObject(data: "AA==") + "}}]}"
        @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], choices.toArray()), responseContext: Some(context)).isOk(), false)
        let decoder = codec.newStreamDecoder(responseContext: Some(context), sseLimits: LlmWireSseLimits(maxLineBytes: 8388608))
        let full = "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"delta\":{\"audio\":" + audioTestObject(data: data) + "}}]}\n\n"
        let update = streamRegressionValue(decoder.push(full.toArray()))
        @Expect(update.terminal.isNone(), true)
        @Expect(decoder.push("data: {\"choices\":[{\"index\":1,\"delta\":{\"audio\":{\"data\":\"AA==\"}}}]}\n\n".toArray()).isOk(), false)
        let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, Array<Byte>(4194304, repeat: 0)))
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.AudioInput(input), LlmWireBlock.AudioInput(input)]))])
        expectLlmError("llm.audio_too_large", { => let _ = codec.encodeRequest(LlmWireRequest("audio-model", transcript)) })
        @Expect(transcript.snapshot().isOk(), false)
    }

    @TestCase
    func streamMetadataLifecycleAndAudioUsageSurviveFailures() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        let single = "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"delta\":{\"audio\":" + audioTestObject() + "}}]}\n\n"
        for (missing in ["\"id\":\"a\",", "\"data\":\"AAECA/7/\",", "\"transcript\":\"spoken\",", ",\"expires_at\":100"]) {
            @Expect(codec.newStreamDecoder(responseContext: Some(context)).push((single.replace(missing, "") + "data: [DONE]\n\n").toArray()).isOk(), false)
        }
        for ((old, malformed) in [("\"id\":\"a\"", "\"id\":1"), ("\"expires_at\":100", "\"expires_at\":-1"), ("\"transcript\":\"spoken\"", "\"transcript\":[]")]) {
            @Expect(codec.newStreamDecoder(responseContext: Some(context)).push(single.replace(old, malformed).toArray()).isOk(), false)
        }
        let decoder = codec.newStreamDecoder(responseContext: Some(context))
        let update = streamRegressionValue(decoder.push(single.toArray())); var starts = 0; var ends = 0; var chunks = 0
        for (event in update.events) { match (event) {
            case LlmWireEvent.ContentBlockStarted(LlmWireStreamBlockKind.Audio, _) => starts++
            case LlmWireEvent.ContentBlockCompleted(LlmWireStreamBlockKind.Audio, _) => ends++
            case LlmWireEvent.AudioDataDelta(value, _) => chunks++; let bytes = value.bytes; bytes[0] = 255u8; @Expect(value.bytes[0], 0u8)
            case _ => ()
        } }
        @Expect(starts, 1); @Expect(ends, 1); @Expect(chunks, 1)
        let usage = "data: {\"choices\":[],\"usage\":{\"prompt_tokens_details\":{\"audio_tokens\":0},\"completion_tokens_details\":{\"audio_tokens\":2}}}\n\n"
        for (mode in [0, 1, 2]) {
            let unfinished = codec.newStreamDecoder(responseContext: Some(context)); let _ = streamRegressionValue(unfinished.push(usage.toArray()))
            if (mode == 0) { match (streamRegressionValue(unfinished.cancel())) {
                case LlmWireTerminal.Cancelled(failure) => @Expect(failure.usage.getOrThrow().audioInputTokens, Some(0)); @Expect(failure.usage.getOrThrow().audioOutputTokens, Some(2))
                case _ => @Fail("expected cancelled")
            } } else {
                let result = if (mode == 1) { unfinished.finish() } else { unfinished.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"data\":\"AB==\"}}}]}\n\n".toArray()) }
                match (result) { case LlmWireResult.Err(error) => @Expect(error.usage.getOrThrow().audioInputTokens, Some(0)); @Expect(error.usage.getOrThrow().audioOutputTokens, Some(2)); case _ => @Fail("expected failure") }
            }
        }
    }

    @TestCase
    func staticAudioGatesRejectIndependentUnsupportedCombinations() {
        let duplicates = [LlmWireAudioFormat.Wav, LlmWireAudioFormat.Wav]
        expectIllegalArgument({ => let _ = LlmWireAudioCapabilities(inputFormats: duplicates) })
        expectIllegalArgument({ => let _ = LlmWireAudioCapabilities(fixedOutputFormats: duplicates) })
        expectIllegalArgument({ => let _ = LlmWireAudioCapabilities(streamOutputFormats: duplicates) })
        expectIllegalArgument({ => let _ = LlmWireAudioCapabilities(voices: [LlmWireAudioVoice.Alloy, LlmWireAudioVoice.Alloy]) })
        let formats = [LlmWireAudioFormat.Wav]; let voices = [LlmWireAudioVoice.Alloy]
        let caps = LlmWireAudioCapabilities(inputFormats: formats, fixedOutputFormats: formats, streamOutputFormats: formats, voices: voices)
        formats[0] = LlmWireAudioFormat.Mp3; voices[0] = LlmWireAudioVoice.Cedar
        let exposed = caps.inputFormats; exposed[0] = LlmWireAudioFormat.Aac
        @Expect(caps.inputFormats[0], LlmWireAudioFormat.Wav); @Expect(caps.voices[0], LlmWireAudioVoice.Alloy)
        let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, [1u8]))
        let user = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.AudioInput(input)]))])
        let assistant = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.AudioInput(input)]))])
        expectLlmError("llm.audio_input_role_invalid", { => let _ = audioTestCodec().encodeRequest(LlmWireRequest("audio-model", assistant)) })
        @Expect(assistant.snapshot().isOk(), false)
        let noModality = openAiChatCodec(openAiChatModelProfile("audio-model", capabilities: LlmWireCapabilities(audio: caps)))
        expectLlmError("llm.audio_input_capability_missing", { => let _ = noModality.encodeRequest(LlmWireRequest("audio-model", user)) })
        let noFormat = openAiChatCodec(openAiChatModelProfile("audio-model", capabilities: LlmWireCapabilities(input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Audio]))))
        expectLlmError("llm.audio_input_capability_missing", { => let _ = noFormat.encodeRequest(LlmWireRequest("audio-model", user)) })
        let structured = openAiChatCodec(openAiChatModelProfile("audio-model", capabilities: LlmWireCapabilities(audio: caps,
            output: LlmWireOutputCapabilities(structuredModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject]))))
        let text = audioTestRequest(LlmWireAudioFormat.Wav).transcript
        expectLlmError("llm.audio_structured_output_unsupported", { => let _ = structured.encodeRequest(LlmWireRequest("audio-model", text,
            structuredOutput: LlmWireStructuredOutput.JsonObject, audioOutput: Some(LlmWireAudioOutputOptions(LlmWireAudioFormat.Wav, LlmWireAudioVoice.Alloy)))) })
        let _ = structured.encodeRequest(LlmWireRequest("audio-model", text, structuredOutput: LlmWireStructuredOutput.Text,
            audioOutput: Some(LlmWireAudioOutputOptions(LlmWireAudioFormat.Wav, LlmWireAudioVoice.Alloy))))
    }

    @TestCase
    func responseContextsCannotCrossCodecOrOutputModes() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        let plain = LlmWireRequest("audio-model", audioTestRequest(LlmWireAudioFormat.Wav).transcript)
        let wrong = openAiResponsesCodec(openAiResponsesModelProfile("audio-model")).encodeRequest(plain).responseContext
        expectLlmError("llm.audio_context_mismatch", { => let _ = codec.decodeResponse("{}", responseContext: Some(wrong)) })
        @Expect(codec.newHttpStreamDecoder(200, responseContext: Some(wrong)).isOk(), false)
        expectLlmError("llm.audio_context_mismatch", { => let _ = codec.newStreamDecoder(responseContext: Some(wrong)) })
        let changed = deepSeekChatCodec(deepSeekChatModelProfile("audio-model")).encodeRequest(plain).responseContext
        @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], "{}".toArray()), responseContext: Some(changed)).isOk(), false)
        let noFormat = openAiChatCodec(openAiChatModelProfile("audio-model"))
        @Expect(noFormat.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(audioTestObject()).toArray()), responseContext: Some(context)).isOk(), false)
        @Expect(noFormat.newStreamDecoder(responseContext: Some(context)).push(audioTestSource().toArray()).isOk(), false)
        @Expect(codec.newStreamDecoder().push(audioTestSource().toArray()).isOk(), false)
        let unrequested = codec.encodeRequest(plain).responseContext
        @Expect(codec.newStreamDecoder(responseContext: Some(unrequested)).push(audioTestSource().toArray()).isOk(), false)
        let _ = codec.decodeResponse(audioTestBody(audioTestObject()), responseContext: Some(context))
    }

    @TestCase
    func audioSnapshotRestoreValidatesEveryClosedField() {
        let codec = audioTestCodec(); let reply = audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Wav), audioTestObject())
        let message = reply.toContinuationInput()[0]
        match (message.blocks[1]) { case LlmWireBlock.AudioReplay(value) =>
            let bytes = value.bytes; bytes[0] = 255u8; @Expect(value.bytes[0], 0u8)
            case _ => @Fail("expected replay")
        }
        let snapshot = streamRegressionValue(LlmWireTranscript(items: [LlmWireInputItem.Message(message)]).snapshot())
        for ((old, invalid) in [("\"protocol\":\"chat_completions\"", "\"protocol\":\"messages\""),
            ("\"format\":\"wav\"", "\"format\":\"unknown\""), ("\"id\":\"a\"", "\"id\":\"\""),
            ("\"model\":\"audio-model\"", "\"model\":\"\""), ("\"expires_at\":100", "\"expires_at\":-1"),
            ("\"block_order\":1", "\"block_order\":-1"), ("\"provider\":\"openai\"", "\"provider\":123"),
            ("\"role\":\"assistant\"", "\"role\":\"user\""), ("\"data\":\"AAECA/7/\"", "\"data\":\"AA=A\""),
            ("\"expires_at\":100", "\"expires_at\":100,\"unknown\":true")]) {
            @Expect(LlmWireTranscript.restore(snapshot.replace(old, invalid)).isOk(), false)
        }
        let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, [1u8]))
        let inputSnapshot = streamRegressionValue(LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.AudioInput(input)]))]).snapshot())
        for ((old, invalid) in [("\"data\":\"AQ==\"", "\"data\":\"\""), ("\"format\":\"wav\"", "\"format\":\"aac\""),
            ("\"role\":\"user\"", "\"role\":\"assistant\"")]) { @Expect(LlmWireTranscript.restore(inputSnapshot.replace(old, invalid)).isOk(), false) }
        let blocks = message.blocks
        let wrongRole = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, blocks))])
        expectLlmError("llm.audio_replay_position_invalid", { => let _ = codec.encodeRequest(LlmWireRequest("audio-model", wrongRole)) })
    }

    @TestCase
    func metadataAndBase64FieldDomainsRemainStrict() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        for (raw in [audioTestObject(id: ""), audioTestObject().replace("100", "-1"), audioTestObject().replace("100}", "100,\"unknown\":true}")]) {
            @Expect(codec.decodeResponse(LlmWireHttpResponse(200, [], audioTestBody(raw).toArray()), responseContext: Some(context)).isOk(), false)
            @Expect(codec.newStreamDecoder(responseContext: Some(context)).push(("data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":" + raw + "}}]}\n\n").toArray()).isOk(), false)
        }
        let decoder = codec.newStreamDecoder(responseContext: Some(context))
        let id = "data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"id\":\"a\"}}}]}\n\n"
        let _ = streamRegressionValue(decoder.push(id.toArray())); let _ = streamRegressionValue(decoder.push(id.toArray()))
        @Expect(decoder.push(id.replace("\"a\"", "\"b\"").toArray()).isOk(), false)
        let expected: Array<Byte> = [0,16,131,16,81,135,32,146,139,48,211,143,65,20,147,81,85,151,97,150,155,113,215,159,130,24,163,146,89,167,162,154,171,178,219,175,195,28,179,211,93,183,227,158,187,243,223,191]
        let actual = audioTestBlock(audioTestFixed(codec, context, audioTestObject(data: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"))).bytes
        @Expect(actual.size, expected.size); for (index in 0..expected.size) { @Expect(actual[index], expected[index]) }
    }
}
