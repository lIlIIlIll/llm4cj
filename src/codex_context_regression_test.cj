package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func codexContextRegressionCodec(capabilities: LlmWireContextUpdateCapabilities, regular!: Bool = false): LlmWireCodec {
    let dialect = if (regular) { openAiResponsesDialect() } else { openAiCodexResponsesDialect() }
    let endpoint = LlmWireEndpointProfile("codex.context.fixture", "model", dialect.compatibilityId, "https://example.test/responses", 1,
        capabilities, "offline-protocol-fixture", "2026-10-18")
    let model = LlmWireModelProfile("model", dialect.compatibilityId, LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true)),
        endpoint: endpoint.endpoint, endpointProfile: Some(endpoint))
    if (regular) { openAiResponsesCodec(model) } else { openAiCodexResponsesCodec(model) }
}

func codexContextRegressionRequest(role: LlmWireInstructionRole): LlmWireRequest {
    LlmWireRequest("model", LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "preamble")]),
        items: [LlmWireInputItem.Message(codexText("history")), LlmWireInputItem.InstructionUpdate(LlmWireInstruction(role, "update"))]))
}

@Test
class CodexContextRegressionTest {
    @TestCase
    func codexContractExcludesSystemUpdates() {
        let contract = openAiCodexResponsesDialect().contract.contextUpdates
        @Expect(contract.style, LlmWireContextUpdateStyle.ResponsesAdditionalTools)
        @Expect(contract.capabilities.appendSystemInstruction, false)
        @Expect(contract.capabilities.appendDeveloperInstruction, true)
        @Expect(contract.capabilities.toolDeclaration, true)
        @Expect(contract.capabilities.toolActivation, false)
        @Expect(contract.capabilities.toolDeactivation, false)
        @Expect(contract.capabilities.toolReplacement, false)
        @Expect(contract.capabilities.deferredToolPool, false)
        @Expect(contract.capabilities.deferredPoolExtension, false)
    }

    @TestCase
    func codexSystemClaimsFailBeforeHttpAndWebSocketFrames() {
        for (claim in [LlmWireContextUpdateCapabilities(appendSystemInstruction: true),
            LlmWireContextUpdateCapabilities(appendSystemInstruction: true, appendDeveloperInstruction: true, toolDeclaration: true)]) {
            let codec = codexContextRegressionCodec(claim)
            let request = codexContextRegressionRequest(LlmWireInstructionRole.System)
            try {
                let _ = codec.encodeRequest(request, streaming: true).materialize()
                @Fail("Codex system update claims must fail before request bytes")
            } catch (error: LlmWireError) {
                @Expect(error.code, "llm.endpoint_profile_capability_unsupported")
                @Expect(error.profileId, "codex.context.fixture"); @Expect(error.contractVersion, 1)
                @Expect(error.dialectId, "openai.codex.responses.v1")
            }
            let ws = codec.newResponsesWebSocketSession()
            try {
                let _ = ws.prepare(request)
                @Fail("Codex system update claims must fail before a WebSocket frame")
            } catch (error: LlmWireError) {
                @Expect(error.code, "llm.endpoint_profile_capability_unsupported")
                @Expect(error.profileId, "codex.context.fixture"); @Expect(error.contractVersion, 1)
            }
        }
    }

    @TestCase
    func codexInstructionUpdatesStillRequireTheirOwnGrant() {
        let allowed = LlmWireContextUpdateCapabilities(appendDeveloperInstruction: true, toolDeclaration: true)
        for (codec in [codexContextRegressionCodec(allowed), codexTestCodec()]) {
            try {
                let _ = codec.encodeRequest(codexContextRegressionRequest(LlmWireInstructionRole.System), streaming: true)
                @Fail("Codex system updates are not supported")
            } catch (error: LlmWireError) {
                @Expect(error.code, "llm.context_update_unsupported")
                @Expect(error.missingCapability, "append_system_instruction"); @Expect(error.inputItemIndex, 1)
            }
        }
        try {
            let _ = codexTestCodec().encodeRequest(codexContextRegressionRequest(LlmWireInstructionRole.Developer), streaming: true)
            @Fail("Codex developer updates still require an endpoint grant")
        } catch (error: LlmWireError) {
            @Expect(error.code, "llm.context_update_unsupported")
            @Expect(error.missingCapability, "append_developer_instruction"); @Expect(error.inputItemIndex, 1)
        }
    }

    @TestCase
    func codexInitialSystemAndDeveloperUpdatesKeepWirePositions() {
        let codec = codexContextRegressionCodec(LlmWireContextUpdateCapabilities(appendDeveloperInstruction: true, toolDeclaration: true))
        let tool = LlmWireTool("echo", "Echo", codexJson("{\"type\":\"object\"}"))
        let transcript = LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "preamble"),
            LlmWireInstruction(LlmWireInstructionRole.Developer, "initial developer")]), items: [LlmWireInputItem.Message(codexText("first")),
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, "updated developer")),
            LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(tool)), LlmWireInputItem.Message(codexText("last"))])
        let request = LlmWireRequest("model", transcript)
        let http = codexJson(codexHttpBody(codec, request))
        let ws = codec.newResponsesWebSocketSession()
        let frame = codexJson(String.fromUtf8(ws.prepare(request).body))
        for (root in [http, frame]) {
            @Expect(root.field("instructions").getOrThrow().stringValue(), Some("preamble"))
            let input = root.field("input").getOrThrow().values()
            @Expect(input.size, 5)
            for (item in input) { @Expect(item.field("role").getOrThrow().stringValue() != Some("system"), true) }
            @Expect(input[0].field("role").getOrThrow().stringValue(), Some("developer"))
            @Expect(input[1].field("content").getOrThrow().values()[0].field("text").getOrThrow().stringValue(), Some("first"))
            @Expect(input[2].field("role").getOrThrow().stringValue(), Some("developer"))
            @Expect(input[2].field("content").getOrThrow().values()[0].field("text").getOrThrow().stringValue(), Some("updated developer"))
            @Expect(input[3].field("type").getOrThrow().stringValue(), Some("additional_tools"))
            @Expect(input[4].field("content").getOrThrow().values()[0].field("text").getOrThrow().stringValue(), Some("last"))
        }
        @Expect(http.field("input").getOrThrow().stringify(), frame.field("input").getOrThrow().stringify())
    }

    @TestCase
    func regularResponsesSystemUpdateRemainsAvailable() {
        let contract = openAiResponsesDialect().contract.contextUpdates
        @Expect(contract.capabilities.appendSystemInstruction, true)
        let codec = codexContextRegressionCodec(contract.capabilities, regular: true)
        let input = codexJson(codexHttpBody(codec, codexContextRegressionRequest(LlmWireInstructionRole.System))).field("input").getOrThrow().values()
        @Expect(input.size, 3)
        @Expect(input[0].field("role").getOrThrow().stringValue(), Some("system"))
        @Expect(input[2].field("role").getOrThrow().stringValue(), Some("system"))
        @Expect(input[2].field("content").getOrThrow().values()[0].field("text").getOrThrow().stringValue(), Some("update"))
    }
}
