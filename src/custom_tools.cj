package llm4cj

import yjson.*

func requireFunctionTool(tool: LlmWireToolDefinition): LlmWireTool {
    match (tool) {
        case LlmWireToolDefinition.Function(value) => value
        case LlmWireToolDefinition.Custom(_) => unsupportedRequest("llm.custom_tool_unsupported", "this dialect cannot represent custom tools")
    }
}

func validateToolDefinitionShape(tool: LlmWireToolDefinition): Unit {
    match (tool) {
        case LlmWireToolDefinition.Function(value) =>
            if (value.inputSchema.kind != LlmWireJsonKind.Object) {
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_schema_invalid", "tool input schema must be a JSON object", toolName: value.name)
            }
        case LlmWireToolDefinition.Custom(_) => ()
    }
}

func sameToolDefinition(left: LlmWireToolDefinition, right: LlmWireToolDefinition): Bool {
    if (left.name != right.name || left.description != right.description || left.kind != right.kind) { return false }
    match ((left, right)) {
        case (LlmWireToolDefinition.Function(a), LlmWireToolDefinition.Function(b)) => canonicalToolSchema(a.inputSchema.jsonNode()) == canonicalToolSchema(b.inputSchema.jsonNode())
        case (LlmWireToolDefinition.Custom(a), LlmWireToolDefinition.Custom(b)) => match ((a.format, b.format)) {
            case (LlmWireCustomToolFormat.Text, LlmWireCustomToolFormat.Text) => true
            case (LlmWireCustomToolFormat.Grammar(x), LlmWireCustomToolFormat.Grammar(y)) => x.syntax == y.syntax && x.definition == y.definition
            case _ => false
        }
        case _ => false
    }
}

func encodeResponsesTool(tool: LlmWireToolDefinition): JsonNode {
    let value = wireJsonObject([WireJsonField("type", wireJsonString(toolKindName(tool.kind))), WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description))])
    match (tool) {
        case LlmWireToolDefinition.Function(function) =>
            value.put("parameters", function.inputSchema.jsonNode())
        case LlmWireToolDefinition.Custom(custom) =>
            value.put("format", match (custom.format) {
                case LlmWireCustomToolFormat.Text => wireJsonObject([WireJsonField("type", wireJsonString("text"))])
                case LlmWireCustomToolFormat.Grammar(grammar) => wireJsonObject([
                    WireJsonField("type", wireJsonString("grammar")),
                    WireJsonField("syntax", wireJsonString(match (grammar.syntax) { case LlmWireGrammarSyntax.Regex => "regex"; case LlmWireGrammarSyntax.Lark => "lark" })),
                    WireJsonField("definition", wireJsonString(grammar.definition))
                ])
            })
    }
    value
}

func validateCustomToolCapability(codec: LlmWireCodec, tool: LlmWireToolDefinition): Unit {
    match (tool) {
        case LlmWireToolDefinition.Function(_) => ()
        case LlmWireToolDefinition.Custom(value) =>
            if (!codec.dialect.contract.customToolFormats.contains(value.format.kind) || !codec.capabilities.tools.customFormats.contains(value.format.kind)) {
                throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.custom_tool_format_unsupported", "custom tool format requires explicit dialect and model support", toolName: value.name)
            }
    }
}

func validateCustomToolRequestChecks(codec: LlmWireCodec, request: LlmWireRequest, checks: RequestCheckSink): Unit {
    for (declaration in request.transcript.initialContext.tools) { checks.charge()
        checks.check("tools.custom_format", { => validateCustomToolCapability(codec, declaration.tool) })
    }
    let items = request.transcript.items
    for (index in 0..items.size) { checks.charge(); match (items[index]) {
        case LlmWireInputItem.ToolDeclaration(value) =>
            checks.check("tools.custom_format", { => validateCustomToolCapability(codec, value.tool) }, itemIndex: index)
        case _ => ()
    } }
}

func writeBoundedRequestJson(value: JsonNode, code: String, message: String): String {
    let output = WireJsonOutput()
    try {
        value.writeJson(output, options: JsonWriteOptions(maxOutputBytes: LLM_JSON_MAX_BYTES, maxDepth: LLM_JSON_MAX_DEPTH))
    } catch (error: JsonException) {
        if (error.code != "output_too_large" && error.code != "max_depth") { throw error }
        throw LlmWireError(LlmWireErrorKind.BodyLimit, code, message)
    }
    output.text()
}
