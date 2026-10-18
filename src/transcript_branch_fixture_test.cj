package llm4cj

import std.collection.*
import std.convert.*
import std.fs.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

func branchFixture(path: String): LlmWireJson {
    let file = File(path, OpenMode.Read)
    let text = String.fromUtf8(readToEnd(file))
    file.close()
    branchJson(text)
}

func sameBranchJson(left: LlmWireJson, right: LlmWireJson): Bool {
    if (left.kind != right.kind) { return false }
    match (left.kind) {
        case LlmWireJsonKind.Object =>
            if (left.fields().size != right.fields().size) { return false }
            for (field in left.fields()) {
                match (right.field(field.name)) {
                    case Some(value) => if (!sameBranchJson(field.value, value)) { return false }
                    case None => return false
                }
            }
            true
        case LlmWireJsonKind.Array =>
            let a = left.values(); let b = right.values()
            if (a.size != b.size) { return false }
            for (index in 0..a.size) { if (!sameBranchJson(a[index], b[index])) { return false } }
            true
        case _ => left.stringify() == right.stringify()
    }
}

func branchFixtureTool(name: String, deferred!: Bool = false): LlmWireToolDeclaration {
    LlmWireToolDeclaration(LlmWireTool(name, "Tool " + name, branchJson("{\"type\":\"object\",\"properties\":{}}")), deferred: deferred)
}

func branchFixtureTranscript(name: String): LlmWireTranscript {
    let anthropic = name == "anthropic-messages"
    let tool = if (anthropic) { "B" } else { "C" }
    let items = ArrayList<LlmWireInputItem>()
    items.add(branchText("History"))
    items.add(if (anthropic) { LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity(tool)) }
        else { LlmWireInputItem.ToolDeclaration(branchFixtureTool(tool)) })
    items.add(LlmWireInputItem.InstructionUpdate(LlmWireInstruction(
        if (name == "openai-responses") { LlmWireInstructionRole.Developer } else { LlmWireInstructionRole.System }, "Updated instruction")))
    items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(branchCall("call-" + tool, name: tool))])))
    items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(
        LlmWireToolResultBlock("call-" + tool, [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))]))])))
    if (anthropic) { items.add(LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity(tool))) }
    LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "Initial instruction")],
        tools: [branchFixtureTool("A"), branchFixtureTool("B", deferred: anthropic)]), items: items.toArray())
}

func branchFixtureCodec(name: String, fixture: LlmWireJson): LlmWireCodec {
    let profile = fixture.field("profile").getOrThrow()
    let model = profile.field("model").getOrThrow().stringValue().getOrThrow()
    let endpoint = profile.field("endpoint").getOrThrow().stringValue().getOrThrow()
    let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
    let updates = match (name) {
        case "openai-responses" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, appendDeveloperInstruction: true, toolDeclaration: true)
        case "anthropic-messages" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolActivation: true, toolDeactivation: true, deferredToolPool: true)
        case _ => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolDeclaration: true)
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

@Test
class TranscriptBranchFixtureTests {
    @TestCase
    func nativePrefixAndContinuationMatchIndependentWireOracles() {
        let specification = branchFixture("fixtures/transcript-branches.json")
        let boundary = Int64.parse(specification.field("fork_index").getOrThrow().numberLiteral().getOrThrow())
        for (expected in specification.field("cases").getOrThrow().values()) {
            let name = expected.field("name").getOrThrow().stringValue().getOrThrow()
            let provenance = branchFixture("fixtures/transcripts/" + name + ".json")
            let source = branchFixtureTranscript(name)
            let codec = branchFixtureCodec(name, provenance)
            let model = codec.modelProfile.getOrThrow().model
            let original = branchSnapshot(source)
            let originalBody = branchValue(codec.encodeRequest(LlmWireRequest(model, source, maxOutputTokens: Some(32))).materialize()).body
            @Expect(sameBranchJson(branchJson(String.fromUtf8(originalBody)), provenance.field("body").getOrThrow()), true)
            let prefix = branchValue(source.forkAt(boundary))
            let prefixSnapshot = branchJson(branchSnapshot(prefix))
            @Expect(sameBranchJson(prefixSnapshot.field("items").getOrThrow(), expected.field("prefix_items").getOrThrow()), true)
            @Expect(sameBranchJson(prefixSnapshot.field("initial_context").getOrThrow(), branchJson(original).field("initial_context").getOrThrow()), true)
            let continuation = branchValue(prefix.appendContinuation(LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock("branch continuation"))])))
            for ((transcript, key) in [(prefix, "prefix_body"), (continuation, "continuation_body")]) {
                let prepared = branchValue(codec.encodeRequest(LlmWireRequest(model, transcript, maxOutputTokens: Some(32))).materialize())
                @Expect(sameBranchJson(branchJson(String.fromUtf8(prepared.body)), expected.field(key).getOrThrow()), true)
                let headers = expected.field("headers").getOrThrow().values()
                @Expect(prepared.headers.size, headers.size)
                for (index in 0..headers.size) {
                    @Expect(prepared.headers[index].name, headers[index].field("name").getOrThrow().stringValue().getOrThrow())
                    @Expect(prepared.headers[index].value, headers[index].field("value").getOrThrow().stringValue().getOrThrow())
                }
                let restored = branchValue(LlmWireTranscript.restore(branchSnapshot(transcript)))
                @Expect(branchSnapshot(branchValue(restored.forkAt(transcript.items.size))), branchSnapshot(transcript))
            }
            @Expect(branchSnapshot(source), original)
        }
    }
}
