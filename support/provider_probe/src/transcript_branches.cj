package llm4cj_provider_probe

import llm4cj.*
import std.collection.*
import std.convert.*

func branchProbeTool(name: String, deferred!: Bool = false): LlmWireToolDeclaration {
    LlmWireToolDeclaration(LlmWireTool(name, "Tool " + name, jp("{\"type\":\"object\",\"properties\":{}}")), deferred: deferred)
}

func branchProbeTranscript(name: String): LlmWireTranscript {
    let anthropic = name == "anthropic-messages"; let tool = if (anthropic) { "B" } else { "C" }
    let items = ArrayList<LlmWireInputItem>()
    items.add(LlmWireInputItem.Message(userMessage("History")))
    items.add(if (anthropic) { LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity(tool)) }
        else { LlmWireInputItem.ToolDeclaration(branchProbeTool(tool)) })
    items.add(LlmWireInputItem.InstructionUpdate(LlmWireInstruction(
        if (name == "openai-responses") { LlmWireInstructionRole.Developer } else { LlmWireInstructionRole.System }, "Updated instruction")))
    items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(
        LlmWireToolCallBlock("call-" + tool, tool, LlmWireToolArguments.Complete(jp("{}"))))])))
    items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(
        LlmWireToolResultBlock("call-" + tool, [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))]))])))
    if (anthropic) { items.add(LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity(tool))) }
    LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "Initial instruction")],
        tools: [branchProbeTool("A"), branchProbeTool("B", deferred: anthropic)]), items: items.toArray())
}

func branchProbeCodec(name: String, fixture: LlmWireJson): LlmWireCodec {
    let profile = fixture.field("profile").getOrThrow()
    let model = profile.field("model").getOrThrow().stringValue().getOrThrow()
    let endpoint = profile.field("endpoint").getOrThrow().stringValue().getOrThrow()
    let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
    let updates = match (name) {
        case "openai-responses" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, appendDeveloperInstruction: true, toolDeclaration: true)
        case "anthropic-messages" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolActivation: true, toolDeactivation: true, deferredToolPool: true)
        case "kimi-chat" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolDeclaration: true)
        case _ => throw IllegalArgumentException("unknown transcript fixture")
    }
    let proof = LlmWireEndpointProfile(profile.field("id").getOrThrow().stringValue().getOrThrow(), model,
        profile.field("dialect").getOrThrow().stringValue().getOrThrow(), endpoint, 1, updates,
        fixture.field("source").getOrThrow().stringValue().getOrThrow(), "2026-10-01")
    match (name) {
        case "openai-responses" => openAiResponsesCodec(openAiResponsesModelProfile(model, capabilities: capabilities, endpoint: endpoint, endpointProfile: Some(proof)))
        case "anthropic-messages" => anthropicMessagesCodec(anthropicMessagesModelProfile(model, capabilities: capabilities, endpoint: endpoint, endpointProfile: Some(proof)))
        case _ => kimiChatCodec(kimiChatModelProfile(model, capabilities: capabilities, endpoint: endpoint, endpointProfile: Some(proof)))
    }
}

func inspectTranscriptBranches(path: String): Int64 {
    let specification = jp(String.fromUtf8(readBytes(path)))
    let boundary = Int64.parse(specification.field("fork_index").getOrThrow().numberLiteral().getOrThrow())
    let cases = ArrayList<LlmWireJson>()
    for (entry in specification.field("cases").getOrThrow().values()) {
        let name = entry.field("name").getOrThrow().stringValue().getOrThrow()
        let provenance = jp(String.fromUtf8(readBytes("fixtures/transcripts/" + name + ".json")))
        let source = branchProbeTranscript(name); let codec = branchProbeCodec(name, provenance)
        let model = codec.modelProfile.getOrThrow().model; let original = probeValue(source.snapshot())
        let prefix = probeValue(source.forkAt(boundary))
        let continued = probeValue(prefix.appendContinuation(LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock("branch continuation"))])))
        let plans = ArrayList<LlmWireJson>(); let restored = ArrayList<LlmWireJson>()
        for (transcript in [source, prefix, continued]) {
            plans.add(materializedJson(probeValue(codec.encodeRequest(LlmWireRequest(model, transcript, maxOutputTokens: Some(32))).materialize())))
            let snapshot = probeValue(transcript.snapshot()); let value = probeValue(LlmWireTranscript.restore(snapshot))
            restored.add(LlmWireJson.boolean(probeValue(probeValue(value.forkAt(value.items.size)).snapshot()) == snapshot))
        }
        cases.add(jo([jf("name", js(name)), jf("prefix_snapshot", jp(probeValue(prefix.snapshot()))),
            jf("plans", ja(plans.toArray())), jf("restored", ja(restored.toArray())),
            jf("source_unchanged", LlmWireJson.boolean(probeValue(source.snapshot()) == original))]))
    }
    println(jo([jf("cases", ja(cases.toArray()))]).stringify())
    0
}
