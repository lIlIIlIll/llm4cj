package codex_subscription

import llm4cj.*
import std.collection.*
import std.convert.*
import std.io.*
import std.net.*
import std.process.*
import std.time.*
import stdx.crypto.crypto.SecureRandom
import stdx.crypto.digest.SHA256
import stdx.crypto.keys.*
import stdx.crypto.common.DerBlob
import stdx.encoding.base64.*
import stdx.net.http.*
import stdx.net.tls.TlsClientConfig
import stdx.log.NoopLogger

let ISSUER = "https://auth.openai.com"
let RESOURCE = "https://api.openai.com/v1"
let DIRECT_SCOPE = "chatgpt.tokens.use.direct"
let REQUESTED_SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

func base64Url(bytes: Array<Byte>): String { toBase64String(bytes).replace("+", "-").replace("/", "_").replace("=", "") }
func decodeBase64Url(value: String): Array<Byte> {
    require(value.size <= 65536 && value.size % 4 != 1, "Invalid base64url value")
    for (byte in value.toArray()) { require(byte >= 65u8 && byte <= 90u8 || byte >= 97u8 && byte <= 122u8 || byte >= 48u8 && byte <= 57u8 || byte == 45u8 || byte == 95u8, "Invalid base64url alphabet") }
    var padded = value.replace("-", "+").replace("_", "/")
    while (padded.size % 4 != 0) { padded += "=" }
    let bytes = fromBase64String(padded).getOrThrow({ => ExampleError("Invalid base64url encoding") })
    require(base64Url(bytes) == value, "Noncanonical base64url value"); bytes
}
func randomUrl(length: Int32): String { base64Url(SecureRandom().nextBytes(length)) }
func sha256(bytes: Array<Byte>): Array<Byte> { let digest = SHA256(); digest.write(bytes); digest.finish() }
func hostId(): String {
    let bytes = SecureRandom().nextBytes(16); bytes[6] = (bytes[6] & 15u8) | 64u8; bytes[8] = (bytes[8] & 63u8) | 128u8
    let hex = StringBuilder(); let digits = "0123456789abcdef"
    for (byte in bytes) { let high = Int64(byte >> 4u8); let low = Int64(byte & 15u8); hex.append(digits[high..high+1]); hex.append(digits[low..low+1]) }
    let value = hex.toString(); "urn:uuid:" + value[0..8] + "-" + value[8..12] + "-" + value[12..16] + "-" + value[16..20] + "-" + value[20..32]
}
func escapeForm(value: String): String {
    let result = StringBuilder(); let digits = "0123456789ABCDEF"
    for (byte in value.toArray()) {
        if (byte >= 65u8 && byte <= 90u8 || byte >= 97u8 && byte <= 122u8 || byte >= 48u8 && byte <= 57u8 || byte == 45u8 || byte == 46u8 || byte == 95u8 || byte == 126u8) {
            result.append(String.fromUtf8([byte]))
        } else { let high = Int64(byte >> 4u8); let low = Int64(byte & 15u8); result.append("%"); result.append(digits[high..high+1]); result.append(digits[low..low+1]) }
    }
    result.toString()
}
func form(fields: Array<(String, String)>): String {
    let result = StringBuilder(); for (index in 0..fields.size) { if (index > 0) { result.append("&") }; result.append(escapeForm(fields[index][0])); result.append("="); result.append(escapeForm(fields[index][1])) }; result.toString()
}
func unescapeForm(value: String): String {
    let result = ArrayList<Byte>(); let bytes = value.toArray(); var index: Int64 = 0
    while (index < bytes.size) {
        if (bytes[index] == 37u8) {
            require(index + 2 < bytes.size, "Invalid callback escaping")
            let literal = String.fromUtf8(bytes[index+1..index+3])
            let decoded = UInt8.parse(literal, radix: 16); require(decoded >= 32u8 && decoded != 127u8, "Invalid callback control byte")
            result.add(decoded); index += 3
        } else { result.add(if (bytes[index] == 43u8) { 32u8 } else { bytes[index] }); index++ }
    }
    String.fromUtf8(result.toArray())
}

func secureClient(host: String): Client {
    var tls = TlsClientConfig(); tls.serverName = Some(host)
    ClientBuilder().tlsConfig(tls).autoRedirect(false).logger(NoopLogger())
        .readTimeout(Duration.second * 300).writeTimeout(Duration.second * 30)
        .connector({ address: SocketAddress =>
            let socket = TcpSocket(address); socket.connect(timeout: Some(Duration.second * 10))
            socket.readTimeout = Some(Duration.second * 300); socket.writeTimeout = Some(Duration.second * 30); socket
        }).build()
}
func boundedBody(stream: InputStream, limit: Int64): Array<Byte> {
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer); if (count == 0) { break }
        require(count <= limit - bytes.size, "HTTP body exceeds configured limit")
        for (index in 0..count) { bytes.add(buffer[index]) }
    }
    bytes.toArray()
}
class AuthReply { let status: Int64; let body: String; init(status: Int64, body: String) { this.status = status; this.body = body } }
interface AuthHttp { func send(url: String, method: String, body: String): AuthReply }
class NativeAuthHttp <: AuthHttp {
    public func send(url: String, method: String, body: String): AuthReply {
        require(url.startsWith(ISSUER + "/"), "OAuth endpoint must belong to the OpenAI issuer")
        let client = secureClient("auth.openai.com")
        try {
            let builder = HttpRequestBuilder().url(url).method(method).readTimeout(Duration.second * 30)
            if (method == "POST") { let _ = builder.header("content-type", "application/x-www-form-urlencoded").body(body) }
            let response = client.send(builder.build())
            try { AuthReply(Int64(response.status), String.fromUtf8(boundedBody(response.body, 1048576))) } finally { response.close() }
        } finally { client.close() }
    }
}
class TokenEndpointError <: ExampleError {
    let status: Int64
    let code: String
    init(status: Int64, code: String) { super("OAuth endpoint returned HTTP " + status.toString() + ": " + code); this.status = status; this.code = code }
}

// Encode a JWK RSA key as SubjectPublicKeyInfo for stdx's native verifier.
func der(tag: Byte, body: Array<Byte>): Array<Byte> {
    let bytes = ArrayList<Byte>(); bytes.add(tag)
    if (body.size < 128) { bytes.add(UInt8(body.size)) } else {
        let length = ArrayList<Byte>(); var value = body.size
        while (value > 0) { length.add(UInt8(value & 255)); value = value >> 8 }
        bytes.add(128u8 | UInt8(length.size)); for (index in 0..length.size) { bytes.add(length[length.size - index - 1]) }
    }
    for (byte in body) { bytes.add(byte) }; bytes.toArray()
}
func concat(left: Array<Byte>, right: Array<Byte>): Array<Byte> { let result = ArrayList<Byte>(); for (byte in left) { result.add(byte) }; for (byte in right) { result.add(byte) }; result.toArray() }
func rsaInteger(bytes: Array<Byte>): Array<Byte> {
    require(!bytes.isEmpty(), "Empty RSA integer")
    der(2u8, if ((bytes[0] & 128u8) != 0u8) { concat([0u8], bytes) } else { bytes })
}
func jwkPublicKey(jwk: LlmWireJson): RSAPublicKey {
    require(text(jwk, "kty") == "RSA" && optionalText(jwk, "alg") == "RS256" && optionalText(jwk, "use") == "sig", "Unsupported signing key")
    let modulus = decodeBase64Url(text(jwk, "n")); let exponent = decodeBase64Url(text(jwk, "e"))
    require(modulus.size >= 256 && modulus.size <= 1024 && exponent.size >= 1 && exponent.size <= 8, "Invalid RSA key size")
    let rsa = der(48u8, concat(rsaInteger(modulus), rsaInteger(exponent)))
    let algorithm: Array<Byte> = [48u8,13u8,6u8,9u8,42u8,134u8,72u8,134u8,247u8,13u8,1u8,1u8,1u8,5u8,0u8]
    RSAPublicKey.decodeDer(DerBlob(der(48u8, concat(algorithm, der(3u8, concat([0u8], rsa))))))
}
func validateIdToken(token: String, clientId: String, nonce: String, expectedSub: String, resolveKey: (String) -> RSAPublicKey, now: Int64): LlmWireJson {
    require(token.size <= 65536, "ID token exceeds 64 KiB")
    let parts = token.split("."); require(parts.size == 3, "Malformed ID token")
    let header = json(String.fromUtf8(decodeBase64Url(parts[0])))
    require(text(header, "alg") == "RS256" && header.field("crit").isNone(), "Unsupported ID token algorithm or critical extension")
    let kid = text(header, "kid"); require(kid != "" && kid.size <= 256, "Invalid signing key identifier")
    let key = resolveKey(kid)
    require(key.verify(SHA256(), sha256((parts[0] + "." + parts[1]).toArray()), decodeBase64Url(parts[2]), padType: PadOption.PKCS1), "ID token signature did not verify")
    let claims = json(String.fromUtf8(decodeBase64Url(parts[1])))
    require(text(claims, "iss") == ISSUER, "ID token issuer mismatch")
    let audience = field(claims, "aud"); var matched = audience.stringValue() == Some(clientId)
    if (audience.kind == LlmWireJsonKind.Array) {
        for (item in audience.values() where item.stringValue() == Some(clientId)) { matched = true }
        if (audience.values().size > 1) { require(optionalText(claims, "azp") == clientId, "ID token authorized party mismatch") }
    }
    require(matched, "ID token audience mismatch")
    require(integer(claims, "exp") > now, "ID token expired")
    for (name in ["iat", "nbf"]) { if (claims.field(name).isSome()) { require(integer(claims, name) <= now + 60, "ID token is not yet valid") } }
    if (nonce != "") { require(text(claims, "nonce") == nonce, "ID token nonce mismatch") }
    let subject = text(claims, "sub"); require(subject != "" && (expectedSub == "" || expectedSub == subject), "ID token identity mismatch")
    claims
}

class LoginAttempt {
    let state = randomUrl(32); let nonce = randomUrl(32); let verifier = randomUrl(32)
    let clientId: String; let redirect: String; let host: String
    init(clientId: String, redirect: String, host: String) { this.clientId = clientId; this.redirect = redirect; this.host = host }
    func authorizationUrl(): String {
        let fields = ArrayList<(String, String)>()
        for (pair in [("client_id", clientId), ("redirect_uri", redirect), ("response_type", "code"), ("scope", REQUESTED_SCOPES), ("resource", RESOURCE), ("state", state), ("nonce", nonce), ("code_challenge", base64Url(sha256(verifier.toArray()))), ("code_challenge_method", "S256"), ("ext_agent_host_id", host)]) { fields.add(pair) }
        if (clientId == "dynamic_agent_client") { fields.add(("agent_name_hint", "llm4cj Codex Example")) }
        ISSUER + "/api/accounts/authorize?" + form(fields.toArray())
    }
    func callback(target: String): (String, String) {
        require(target.startsWith("/auth/callback?"), "Unexpected OAuth callback path")
        let parameters = HashMap<String, String>()
        for (pair in target[15..target.size].split("&")) {
            let separator = pair.indexOf("=").getOrThrow({ => ExampleError("Malformed callback query") })
            let pieces = [pair[0..separator], pair[separator + 1..pair.size]]
            let name = unescapeForm(pieces[0]); require(!parameters.contains(name), "Duplicate callback query field")
            parameters[name] = unescapeForm(pieces[1])
        }
        require(parameters.get("state") == Some(state), "OAuth callback state mismatch")
        require(!parameters.contains("error"), "OAuth authorization was declined")
        let code = parameters.get("code").getOrThrow({ => ExampleError("Callback has no code") })
        let issued = match (parameters.get("client_id")) { case Some(value) => value; case None => clientId }
        require(issued != "" && issued != "dynamic_agent_client" && (clientId == "dynamic_agent_client" || issued == clientId), "Invalid issued client ID")
        require(code != "", "Empty authorization code"); (code, issued)
    }
}

class CallbackListener {
    let server: TcpServerSocket
    let redirect: String
    init() {
        server = TcpServerSocket(bindAt: IPSocketAddress("127.0.0.1", 0u16)); server.bind()
        let address = (server.localAddress as IPSocketAddress).getOrThrow()
        redirect = "http://127.0.0.1:" + address.port.toString() + "/auth/callback"
    }
    func awaitCallback(attempt: LoginAttempt): (String, String) {
        let socket = server.accept(timeout: Some(Duration.second * 300)); socket.readTimeout = Some(Duration.second * 10)
        try {
            let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(1024, repeat: 0)
            while (true) {
                let count = socket.read(buffer); require(count > 0 && count <= 8192 - bytes.size, "Invalid or oversized callback headers")
                for (index in 0..count) { bytes.add(buffer[index]) }
                if (String.fromUtf8(bytes.toArray()).contains("\r\n\r\n")) { break }
            }
            let line = String.fromUtf8(bytes.toArray()).split("\r\n")[0].split(" ")
            require(line.size == 3 && line[0] == "GET", "Invalid callback request")
            let result = attempt.callback(line[1])
            let body = "Sign-in completed. Return to the terminal."
            socket.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " + body.size.toString() + "\r\nConnection: close\r\n\r\n" + body).toArray())
            result
        } finally { socket.close() }
    }
    func closeListener(): Unit { server.close() }
}

class AuthManager {
    let store: AccountStore
    private let http: AuthHttp
    private var jwks: ?LlmWireJson = None
    init(store: AccountStore, http!: AuthHttp = NativeAuthHttp()) { this.store = store; this.http = http }
    func discovery(): LlmWireJson {
        let reply = http.send(ISSUER + "/.well-known/openid-configuration", "GET", "")
        require(reply.status == 200, "Cannot obtain OpenAI OIDC discovery")
        let value = json(reply.body)
        require(text(value, "issuer") == ISSUER && text(value, "authorization_endpoint") == ISSUER + "/api/accounts/authorize" && text(value, "token_endpoint") == ISSUER + "/api/accounts/oauth/token", "Unexpected OpenAI OIDC endpoints")
        for (name in ["jwks_uri", "revocation_endpoint"]) { require(text(value, name).startsWith(ISSUER + "/"), "Unexpected OpenAI OIDC endpoint origin") }
        value
    }
    private func signingKey(kid: String): RSAPublicKey {
        for (attempt in 0..2) {
            if (jwks.isNone() || attempt == 1) {
                let reply = http.send(text(discovery(), "jwks_uri"), "GET", ""); require(reply.status == 200, "Cannot obtain signing keys")
                jwks = Some(json(reply.body))
            }
            let keys = field(jwks.getOrThrow(), "keys"); require(keys.kind == LlmWireJsonKind.Array && keys.values().size <= 32, "Invalid signing-key set")
            let matching = ArrayList<LlmWireJson>(); for (key in keys.values() where optionalText(key, "kid") == kid) { matching.add(key) }
            require(matching.size <= 1, "Duplicate signing key identifier")
            if (matching.size == 1) { return jwkPublicKey(matching[0]) }
        }
        throw ExampleError("Unknown signing key after JWKS refresh")
    }
    func tokenRequest(fields: Array<(String, String)>): LlmWireJson {
        for (attempt in 0..3) {
            let reply = try { http.send(ISSUER + "/api/accounts/oauth/token", "POST", form(fields)) } catch (_: Exception) {
                if (attempt < 2) { sleep(Duration.second * (attempt + 1)); continue }
                throw ExampleError("OAuth transport failed; existing credentials retained")
            }
            if (reply.status == 200) { return json(reply.body) }
            if (reply.status >= 500 && attempt < 2) { sleep(Duration.second * (attempt + 1)); continue }
            let error = try { optionalText(json(reply.body), "error") } catch (_: Exception) { "invalid_error_response" }
            throw TokenEndpointError(reply.status, if (error.size <= 128) { error } else { "oversized_error_code" })
        }
        throw ExampleError("OAuth retry limit reached")
    }
    func tokenAccount(response: LlmWireJson, label: String, clientId: String, nonce: String, expectedSub: String): LlmWireJson {
        require(optionalText(response, "token_type").toAsciiLower() == "bearer", "Unsupported access-token type")
        let now = nowSeconds(); let ttl = integer(response, "expires_in"); require(ttl > 0 && ttl <= 86400, "Invalid access-token lifetime")
        let idToken = text(response, "id_token")
        let claims = validateIdToken(idToken, clientId, nonce, expectedSub, { kid => signingKey(kid) }, now)
        let access = text(response, "access_token"); require(access != "" && access.size <= 65536, "Invalid access token")
        let scopes = text(response, "scope"); let refresh = optionalText(response, "refresh_token")
        require(!hasScope(scopes, "offline_access") || refresh != "", "Renewable grant omitted its refresh token")
        var earliest: Int64 = 0
        match (response.field("earliest_refresh_at")) {
            case Some(value) => if (value.kind == LlmWireJsonKind.Number) { earliest = Int64.parse(value.numberLiteral().getOrThrow()) } else if (value.kind == LlmWireJsonKind.String) { earliest = DateTime.parse(value.stringValue().getOrThrow()).toUnixTimeStamp().toSeconds() } else { require(value.kind == LlmWireJsonKind.Null, "Invalid earliest refresh time") }
            case None => ()
        }
        object([("label", jsonString(label)), ("client_id", jsonString(clientId)), ("sub", field(claims, "sub")), ("access_token", jsonString(access)), ("refresh_token", jsonString(refresh)), ("id_token", jsonString(idToken)), ("scope", jsonString(scopes)), ("expires_at", number(now + ttl)), ("earliest_refresh_at", number(earliest))])
    }
    func login(label: String): Unit {
        require(label != "" && label.size <= 64, "Account label must contain 1-64 bytes")
        let initial = store.locked({ => let state = store.load(); store.save(state); state })
        var previous: ?LlmWireJson = None
        for (account in field(initial, "accounts").values() where text(account, "label") == label) { previous = Some(account) }
        let savedClient = match (previous) { case Some(value) => text(value, "client_id"); case None => "dynamic_agent_client" }
        let selectedSub = match (previous) { case Some(value) => text(value, "sub"); case None => "" }
        let listener = CallbackListener()
        try {
            let attempt = LoginAttempt(savedClient, listener.redirect, text(initial, "host_id"))
            let url = attempt.authorizationUrl()
            let launched = try { Process.run("xdg-open", [url], stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard, timeout: Some(Duration.second * 10)) == 0 } catch (_: Exception) { false }
            if (!launched) { println("Open this authorization URL in your browser:\n" + url) }
            println("Waiting for the browser callback (five minutes).")
            let (code, issued) = listener.awaitCallback(attempt)
            let tokens = tokenRequest([("grant_type", "authorization_code"), ("client_id", issued), ("code", code), ("code_verifier", attempt.verifier), ("redirect_uri", listener.redirect), ("resource", RESOURCE)])
            let account = tokenAccount(tokens, label, issued, attempt.nonce, selectedSub)
            store.locked({ =>
                let current = store.load()
                for (other in field(current, "accounts").values()) {
                    require(text(other, "label") == label || text(other, "client_id") != issued || text(other, "sub") != text(account, "sub"), "This registration already has another account label")
                    if (text(other, "label") == label) { require(text(other, "client_id") == issued && text(other, "sub") == text(account, "sub"), "Account registration changed during sign-in") }
                }
                store.save(replaceAccount(current, label, account))
            })
            println(if (canInvoke(account)) { "Signed in: " + label } else { "Identity verified; ChatGPT subscription sharing was not granted for this account." })
        } finally { listener.closeListener() }
    }
    func access(label: String): String {
        store.locked({ =>
            let state = store.load(); var account = findAccount(state, label)
            require(optionalText(account, "access_token") != "", "Account is signed out; run login again")
            let now = nowSeconds()
            if (integer(account, "expires_at") <= now + 60 && integer(account, "earliest_refresh_at") <= now) {
                require(optionalText(account, "refresh_token") != "", "Account has no refresh grant; run login again")
                let response = try { tokenRequest([("grant_type", "refresh_token"), ("client_id", text(account, "client_id")), ("refresh_token", text(account, "refresh_token")), ("resource", RESOURCE)]) }
                catch (error: TokenEndpointError) {
                    if (error.status >= 400 && error.status < 500 &&
                        (error.code == "invalid_grant" || error.code == "invalid_refresh_token" || error.code == "token_expired" ||
                        error.code == "refresh_token_expired" || error.code == "refresh_token_invalidated" || error.code == "refresh_token_reused" ||
                        error.code == "invalid_token" || error.code == "login_required" || error.code == "interaction_required" || error.code == "consent_required")) {
                        store.save(replaceAccount(state, label, clearTokens(account)))
                    }
                    throw error
                }
                let replacement = try { tokenAccount(response, label, text(account, "client_id"), "", text(account, "sub")) } catch (error: Exception) { store.save(replaceAccount(state, label, clearTokens(account))); throw error }
                store.save(replaceAccount(state, label, replacement)); account = replacement
            }
            require(integer(account, "expires_at") > nowSeconds(), "Access token expired before refresh was permitted")
            require(canInvoke(account), "This account did not grant subscription inference scopes")
            text(account, "access_token")
        })
    }
    func logout(label: String): Bool {
        store.locked({ =>
            let state = store.load(); let account = findAccount(state, label)
            let refresh = optionalText(account, "refresh_token")
            let revoked = if (refresh == "") { true } else { try {
                http.send(text(discovery(), "revocation_endpoint"), "POST", form([("token", refresh), ("token_type_hint", "refresh_token"), ("client_id", text(account, "client_id"))])).status == 200
            } catch (_: Exception) { false } }
            store.save(replaceAccount(state, label, clearTokens(account))); revoked
        })
    }
}
func canInvoke(account: LlmWireJson): Bool { let scopes = optionalText(account, "scope"); hasScope(scopes, DIRECT_SCOPE) && hasScope(scopes, "resource.invoke") }
