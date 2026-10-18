package llm4cj_provider_probe

import llm4cj.*

func isAudioProbe(name: String): Bool { name.startsWith("openai-chat-audio-") }
func audioProbeFormat(name: String): LlmWireAudioFormat {
    match (name) {
        case "wav" => LlmWireAudioFormat.Wav; case "mp3" => LlmWireAudioFormat.Mp3
        case "aac" => LlmWireAudioFormat.Aac; case "flac" => LlmWireAudioFormat.Flac
        case "opus" => LlmWireAudioFormat.Opus; case "pcm16" => LlmWireAudioFormat.Pcm16
        case _ => throw IllegalArgumentException("unknown audio format")
    }
}
func audioProbeFormatName(format: LlmWireAudioFormat): String {
    match (format) {
        case LlmWireAudioFormat.Wav => "wav"; case LlmWireAudioFormat.Mp3 => "mp3"
        case LlmWireAudioFormat.Aac => "aac"; case LlmWireAudioFormat.Flac => "flac"
        case LlmWireAudioFormat.Opus => "opus"; case LlmWireAudioFormat.Pcm16 => "pcm16"
    }
}
func audioProbeCodec(model!: String = "gpt-audio-1.5"): LlmWireCodec {
    let formats = [LlmWireAudioFormat.Wav, LlmWireAudioFormat.Mp3, LlmWireAudioFormat.Aac, LlmWireAudioFormat.Flac, LlmWireAudioFormat.Opus, LlmWireAudioFormat.Pcm16]
    openAiChatCodec(openAiChatModelProfile(model, capabilities: LlmWireCapabilities(
        input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Audio]),
        audio: LlmWireAudioCapabilities(inputFormats: [LlmWireAudioFormat.Wav, LlmWireAudioFormat.Mp3],
            fixedOutputFormats: formats, streamOutputFormats: formats, voices: [LlmWireAudioVoice.Alloy], assistantReplay: true))))
}
func audioProbeRequest(format: String): LlmWireRequest {
    let input = probeValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, [0u8, 1u8, 2u8, 3u8, 254u8, 255u8]))
    let message = LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("Describe this audio.")), LlmWireBlock.AudioInput(input)])
    LlmWireRequest("gpt-audio-1.5", LlmWireTranscript(items: [LlmWireInputItem.Message(message)]), maxOutputTokens: Some(256),
        audioOutput: Some(LlmWireAudioOutputOptions(audioProbeFormat(format), LlmWireAudioVoice.Alloy)))
}
func encodeAudio(format: String, streaming: Bool): Int64 {
    println(materializedJson(probeValue(audioProbeCodec().encodeRequest(audioProbeRequest(format), streaming: streaming).materialize())).stringify()); 0
}
func inspectAudioFixed(format: String, path: String): Int64 {
    let codec = audioProbeCodec(); let context = codec.encodeRequest(audioProbeRequest(format)).responseContext
    let output = match (codec.decodeResponse(LlmWireHttpResponse(200, [], readBytes(path)), responseContext: Some(context))) {
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(terminal)) => inspectionJson("openai-chat-audio-" + format, terminal)
        case LlmWireResult.Err(error) => inspectionError(error)
        case _ => throw IllegalStateException("audio response must be terminal")
    }
    println(output.stringify()); 0
}
func inspectAudioStream(format: String, path: String, width: Int64): Int64 {
    let codec = audioProbeCodec(); let context = codec.encodeRequest(audioProbeRequest(format), streaming: true).responseContext
    let output = match (decodeSse(codec, readBytes(path), width, false, responseContext: Some(context)).result) {
        case LlmWireResult.Ok(terminal) => inspectionJson("openai-chat-audio-" + format, terminal)
        case LlmWireResult.Err(error) => inspectionError(error)
    }
    println(output.stringify()); 0
}
