package codex_subscription

import llm4cj.*
import std.collection.*
import std.console.Console
import stdx.net.http.*
import stdx.encoding.url.URL

func modelCatalog(token: String): Array<LlmWireJson> {
    let client = secureClient("api.openai.com")
    try {
        let response = client.send(HttpRequestBuilder().url(RESOURCE + "/models").header("authorization", "Bearer " + token).build())
        try {
            let body = boundedBody(response.body, 1048576)
            require(response.status == 200u16, "Models endpoint returned HTTP " + response.status.toString())
            let models = field(json(String.fromUtf8(body)), "models"); require(models.kind == LlmWireJsonKind.Array, "Invalid model catalog")
            let listed = ArrayList<LlmWireJson>()
            for (model in models.values() where optionalText(model, "visibility") == "list") { let _ = text(model, "slug"); let _ = text(model, "display_name"); listed.add(model) }
            listed.toArray()
        } finally { response.close() }
    } finally { client.close() }
}

class MessageFragments {
    private let bytes = ArrayList<Byte>()
    private var active = false
    func push(kind: WebSocketFrameType, payload: Array<Byte>, fin: Bool): ?Array<Byte> {
        match (kind) {
            case WebSocketFrameType.TextWebFrame => require(!active, "WebSocket text frame interrupted an unfinished message")
            case WebSocketFrameType.ContinuationWebFrame => require(active, "Unexpected WebSocket continuation frame")
            case _ => throw ExampleError("Unsupported WebSocket data frame")
        }
        require(payload.size <= 8388608 - bytes.size, "WebSocket message exceeds 8 MiB")
        for (byte in payload) { bytes.add(byte) }
        active = !fin
        if (!fin) { return None }
        let message = bytes.toArray(); bytes.clear(); Some(message)
    }
}

class InferenceFailure <: ExampleError {
    let failure: LlmWireFailure
    init(failure: LlmWireFailure) {
        super("Provider failure" + match (failure.httpStatus) { case Some(status) => " HTTP " + status.toString(); case None => "" } + ": " + failure.providerErrorCode)
        this.failure = failure
    }
}
func terminalReply(value: LlmWireTerminal): LlmWireReply {
    match (value) {
        case LlmWireTerminal.Completed(reply) =>
            for (choice in reply.choices) { match (choice.outcome) { case LlmWireChoiceOutcome.Completed => (); case _ => throw ExampleError("Provider response was incomplete or refused") } }
            reply
        case LlmWireTerminal.ProviderFailed(failure) => throw InferenceFailure(failure)
        case LlmWireTerminal.Cancelled(_) => throw ExampleError("Provider cancelled the response")
    }
}
func streamUpdate(result: LlmWireResult<LlmWireStreamUpdate>): LlmWireStreamUpdate {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw ExampleError(error.code) }
}
class StreamDisplay {
    var emitted = false
    private var textEmitted = false
    func accept(update: LlmWireStreamUpdate): Unit {
        for (event in update.events) { match (event) {
            case LlmWireEvent.TextDelta(value, _) => print(value); emitted = true; textEmitted = true
            case LlmWireEvent.ToolCallStarted(_) | LlmWireEvent.ToolArgumentsDelta(_, _) | LlmWireEvent.ReasoningDelta(_, _) => emitted = true
            case _ => ()
        } }
    }
    func complete(reply: LlmWireReply): Unit {
        if (!textEmitted) { for (block in reply.blocks) { match (block) { case LlmWireOutputBlock.Text(value) => print(value.text); case _ => () } } }
        println("")
    }
}

class NativeConversation {
    private let codec: LlmWireCodec
    private let transport: String
    private var connection: ?WebSocket = None
    private var client: ?Client = None
    private var session: ?LlmWireResponsesWebSocketSession = None
    private var bearer = ""
    init(codec: LlmWireCodec, transport: String) { this.codec = codec; this.transport = transport }
    func respond(request: LlmWireRequest, token: String): LlmWireReply {
        if (transport == "sse") { return sse(request, token) }
        for (attempt in 0..2) {
            let display = StreamDisplay()
            try { let reply = webSocket(request, token, display); display.complete(reply); return reply }
            catch (error: InferenceFailure) {
                closeConnection()
                if (attempt == 0 && !display.emitted && error.failure.providerErrorCode == "previous_response_not_found") { continue }
                throw error
            } catch (error: Exception) { closeConnection(); throw error }
        }
        throw ExampleError("WebSocket recovery limit reached")
    }
    private func sse(request: LlmWireRequest, token: String): LlmWireReply {
        let prepared = match (codec.encodeRequest(request, streaming: true).materialize(userHeaders: [LlmWireHeader("authorization", "Bearer " + token)])) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw ExampleError(error.code) }
        let client = secureClient("api.openai.com")
        try {
            let builder = HttpRequestBuilder().url(RESOURCE + "/responses").post().body(prepared.body)
            for (header in prepared.headers) { let _ = builder.header(header.name, header.value) }
            let response = client.send(builder.build())
            try {
                let headers = ArrayList<LlmWireHeader>()
                for ((name, values) in response.headers) { for (value in values) { headers.add(LlmWireHeader(name, value)) } }
                let decoder = match (codec.newHttpStreamDecoder(Int64(response.status), headers: headers.toArray())) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw ExampleError(error.code) }
                let display = StreamDisplay(); let buffer = Array<Byte>(4096, repeat: 0)
                while (true) { let count = response.body.read(buffer); if (count == 0) { break }; display.accept(streamUpdate(decoder.push(buffer[0..count]))) }
                let update = streamUpdate(decoder.finish()); display.accept(update)
                let reply = terminalReply(update.terminal.getOrThrow({ => ExampleError("Missing SSE terminal") })); display.complete(reply); reply
            } finally { response.close() }
        } finally { client.close() }
    }
    private func webSocket(request: LlmWireRequest, token: String, display: StreamDisplay): LlmWireReply {
        if (connection.isNone() || bearer != token) {
            closeConnection()
            let opened = secureClient("api.openai.com"); client = Some(opened)
            let headers = HttpHeaders(); headers.add("authorization", "Bearer " + token)
            let (socket, _) = WebSocket.upgradeFromClient(opened, URL.parse("wss://api.openai.com/v1/responses"), headers: headers)
            connection = Some(socket); session = Some(codec.newResponsesWebSocketSession()); bearer = token
        }
        let active = session.getOrThrow(); let socket = connection.getOrThrow()
        socket.write(WebSocketFrameType.TextWebFrame, active.prepare(request).body)
        let fragments = MessageFragments()
        while (true) {
            let frame = socket.read()
            match (frame.frameType) {
                case WebSocketFrameType.PingWebFrame => socket.writePongFrame(frame.payload)
                case WebSocketFrameType.PongWebFrame => ()
                case WebSocketFrameType.CloseWebFrame => let _ = streamUpdate(active.finish()); throw ExampleError("WebSocket closed before a terminal response")
                case _ => match (fragments.push(frame.frameType, frame.payload, frame.fin)) {
                    case Some(message) =>
                        let update = streamUpdate(active.push(message)); display.accept(update)
                        match (update.terminal) { case Some(terminal) => return terminalReply(terminal); case None => () }
                    case None => ()
                }
            }
        }
        throw ExampleError("WebSocket response loop ended without a terminal")
    }
    func closeConnection(): Unit {
        match (connection) { case Some(socket) => try { socket.closeConn() } catch (_: Exception) { () }; case None => () }
        match (client) { case Some(value) => try { value.close() } catch (_: Exception) { () }; case None => () }
        connection = None; client = None; session = None; bearer = ""
    }
}

func chat(auth: AuthManager, label: String, model: String, transport: String, demoTool: Bool): Unit {
    require(transport == "sse" || transport == "ws", "Transport must be sse or ws")
    var listed = false; for (item in modelCatalog(auth.access(label)) where text(item, "slug") == model) { listed = true }
    require(listed, "Model must be a listed slug from this account's models command")
    let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: demoTool, parallelCalls: demoTool))
    let codec = openAiCodexResponsesCodec(openAiCodexResponsesModelProfile(model, capabilities: capabilities))
    let tools: Array<LlmWireTool> = if (demoTool) { [LlmWireTool("echo", "Return the supplied text as a JSON string.", json("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"],\"additionalProperties\":false}"))] } else { [] }
    let history = ArrayList<LlmWireInputItem>(); let conversation = NativeConversation(codec, transport)
    let declarations = ArrayList<LlmWireToolDeclaration>()
    for (tool in tools) { declarations.add(LlmWireToolDeclaration(tool)) }
    let initial = LlmWireInitialContext(tools: declarations.toArray())
    println("Enter a prompt; /quit or EOF ends the conversation.")
    try {
        while (true) {
            print("> ")
            let prompt = match (Console.stdIn.readln()) { case Some(value) => value; case None => break }
            if (prompt == "/quit") { break }; if (prompt.trimAscii() == "") { continue }
            history.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(prompt))])))
            var finished = false
            for (_ in 0..8) {
                let transcript = LlmWireTranscript(initial, items: history.toArray())
                let reply = conversation.respond(LlmWireRequest(model, transcript), auth.access(label))
                match (validateReplyToolInputs(reply, transcript, mode: LlmWireToolInputValidationMode.Strict)) { case LlmWireResult.Err(error) => throw ExampleError(error.code); case _ => () }
                for (message in reply.toContinuationInput()) { history.add(LlmWireInputItem.Message(message)) }
                let results = ArrayList<LlmWireBlock>()
                for (block in reply.blocks) { match (block) {
                    case LlmWireOutputBlock.ToolCall(call) =>
                        require(demoTool && call.name == "echo", "Unexpected function tool")
                        let arguments = match (call.arguments) { case LlmWireToolArguments.Complete(value) => value; case _ => throw ExampleError("Tool arguments are not executable") }
                        require(arguments.fields().size == 1, "Invalid echo arguments")
                        results.add(LlmWireBlock.ToolResult(LlmWireToolResultBlock(call.callId, [LlmWireToolResultContent.Text(LlmWireTextBlock(jsonString(text(arguments, "text")).stringify()))])))
                    case _ => ()
                } }
                if (results.isEmpty()) { finished = true; break }
                history.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, results.toArray())))
            }
            require(finished, "Tool demonstration exceeded eight rounds")
        }
    } finally { conversation.closeConnection() }
}
