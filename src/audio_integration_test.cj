package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class AudioIntegrationTests {
    @TestCase
    func reconstructedRepliesCannotRelocateClosedAudioDuringProjection() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        for (reply in [audioTestFixed(codec, context, audioTestObject()), audioTestStream(codec, context, audioTestSource(), 1)]) {
            @Expect(reply.toContinuationInput().size, 1)
            @Expect(reply.toContinuationInput(0).isOk(), true)
            let text = reply.blocks[0]; let audio = reply.blocks[1]
            for (moved in [[audio], [audio, text], [text, text, audio], [text, audio, audio]]) {
                let reconstructed = LlmWireReply(blocks: moved)
                expectLlmError("llm.audio_replay_position_invalid", { => let _ = reconstructed.toContinuationInput() })
                for (result in [reconstructed.toContinuationInput(0), reconstructed.choices[0].toContinuationInput()]) {
                    match (result) {
                        case LlmWireResult.Err(error) => @Expect(error.kind, LlmWireErrorKind.InvalidState); @Expect(error.code, "llm.audio_replay_position_invalid")
                        case _ => @Fail("reordered audio projection must fail")
                    }
                }
            }
        }
    }

    @TestCase
    func structuredExtractionRejectsAudioFromAnotherRequest() {
        let codec = audioTestCodec(); let context = audioTestContext(codec, LlmWireAudioFormat.Wav)
        let fixed = match (streamRegressionValue(codec.decodeResponse(LlmWireHttpResponse(200, [],
            audioTestBody(audioTestObject()).replace("\"content\":\"text\"", "\"content\":\"{}\"").toArray()), responseContext: Some(context)))) {
            case LlmWireResponseState.Terminal(value) => streamRegressionReply(value)
            case _ => throw IllegalStateException("expected terminal")
        }
        let streamed = audioTestStream(codec, context, audioTestSource().replace("\"content\":\"text\"", "\"content\":\"{}\""), 1)
        let schema = streamRegressionValue(LlmWireJson.parse("{\"type\":\"object\"}"))
        for (format in [LlmWireStructuredOutput.JsonObject, LlmWireStructuredOutput.JsonSchemaDocument(schema)]) {
            let request = LlmWireRequest("audio-model", audioTestRequest(LlmWireAudioFormat.Wav).transcript, structuredOutput: format)
            let indices: Array<?Int64> = [None, Some(0)]
            for (reply in [fixed, streamed]) {
                for (index in indices) {
                    let error = match (extractStructuredOutput(reply, request, choiceIndex: index)) {
                        case LlmWireResult.Err(value) => value
                        case _ => throw IllegalStateException("mixed audio must reject structured extraction")
                    }
                    @Expect(error.kind, LlmWireErrorKind.InvalidState); @Expect(error.code, "llm.structured_output_audio_present")
                    @Expect(error.usage.getOrThrow().audioInputTokens, Some(0)); @Expect(error.usage.getOrThrow().audioOutputTokens, Some(2))
                }
            }
        }
    }

    @TestCase
    func audioSharesV3WithToolAndCacheMetadataWithoutRelocation() {
        let schema = streamRegressionValue(LlmWireJson.parse("{\"type\":\"object\"}"))
        let tools = [LlmWireToolDeclaration(LlmWireTool("lookup", "lookup", schema))]
        let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Mp3, [0u8, 1u8, 2u8]))
        let items = [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User,
            [LlmWireBlock.Text(LlmWireTextBlock("before")), LlmWireBlock.AudioInput(input), LlmWireBlock.Text(LlmWireTextBlock("after"))]))]
        let breakpoint = LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: tools), items: items, cacheBreakpoints: [breakpoint])
        let snapshot = streamRegressionValue(transcript.snapshot())
        @Expect(snapshot.contains("\"version\":3"), true); @Expect(snapshot.contains("\"tool_kind\":\"function\""), true)
        @Expect(snapshot.contains("\"cache_breakpoints\""), true); @Expect(snapshot.contains("\"audio_input\""), true)
        let restored = streamRegressionValue(LlmWireTranscript.restore(snapshot)); @Expect(streamRegressionValue(restored.snapshot()), snapshot)
        let original = audioTestCodec().capabilities
        let codec = openAiChatCodec(openAiChatModelProfile("audio-model", capabilities: LlmWireCapabilities(input: original.input,
            tools: original.tools, audio: original.audio, cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault], explicitBreakpoints: true))))
        expectLlmError("llm.cache_explicit_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest("audio-model", restored)) })
        let automatic = LlmWireRequest("audio-model", LlmWireTranscript(LlmWireInitialContext(tools: tools), items: items),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault), promptCacheRoutingKey: Some("audio-prefix"),
            audioOutput: Some(LlmWireAudioOutputOptions(LlmWireAudioFormat.Wav, LlmWireAudioVoice.Alloy)))
        let wire = streamRegressionValue(LlmWireJson.parse(String.fromUtf8(streamRegressionValue(codec.encodeRequest(automatic).materialize()).body)))
        @Expect(wire.field("prompt_cache_key").getOrThrow().stringValue(), Some("audio-prefix"))
        let parts = wire.field("messages").getOrThrow().values()[0].field("content").getOrThrow().values()
        @Expect(parts[0].field("text").getOrThrow().stringValue(), Some("before"))
        @Expect(parts[1].field("input_audio").getOrThrow().field("format").getOrThrow().stringValue(), Some("mp3"))
        @Expect(parts[2].field("text").getOrThrow().stringValue(), Some("after"))
    }
}
