package codex_subscription

import llm4cj.*
import std.collection.*
import std.env.getVariable
import std.fs.*
import std.net.*
import std.process.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import stdx.crypto.keys.*
import stdx.net.http.WebSocketFrameType

// Test keys are generated in memory; no private keys or live credentials are fixtures.
class TestDerReader {
    private let bytes: Array<Byte>
    private var index: Int64 = 0
    init(bytes: Array<Byte>) { this.bytes = bytes }
    func next(): Array<Byte> {
        index++; var size = Int64(bytes[index]); index++
        if (size >= 128) { let count = size - 128; size = 0; for (_ in 0..count) { size = size * 256 + Int64(bytes[index]); index++ } }
        let result = bytes[index..index+size]; index += size; result
    }
}
class TestIdentity {
    let privateKey = RSAPrivateKey(2048)
    let publicKey: RSAPublicKey
    let jwks: String
    init() {
        publicKey = RSAPublicKey(privateKey)
        let spki = TestDerReader(TestDerReader(publicKey.encodeToDer().body).next())
        let _ = spki.next(); let bits = spki.next()
        let rsa = TestDerReader(TestDerReader(bits[1..bits.size]).next())
        let rawModulus = rsa.next(); let modulus = if (rawModulus[0] == 0u8) { rawModulus[1..rawModulus.size] } else { rawModulus }
        let exponent = rsa.next()
        jwks = object([("keys", jsonArray([object([
            ("kid", jsonString("test-key")), ("kty", jsonString("RSA")), ("alg", jsonString("RS256")), ("use", jsonString("sig")),
            ("n", jsonString(base64Url(modulus))), ("e", jsonString(base64Url(exponent)))
        ])]))]).stringify()
    }
    func jwt(claims: LlmWireJson, algorithm!: String = "RS256", kid!: String = "test-key"): String {
        let header = object([("alg", jsonString(algorithm)), ("kid", jsonString(kid))])
        let signing = base64Url(header.stringify().toArray()) + "." + base64Url(claims.stringify().toArray())
        signing + "." + base64Url(privateKey.sign(SHA256(), sha256(signing.toArray()), padType: PadOption.PKCS1))
    }
    func claims(nonce!: String = "nonce", audience!: String = "issued-client", subject!: String = "subject", expiry!: Int64 = 4102444800): LlmWireJson {
        object([("iss", jsonString(ISSUER)), ("aud", jsonString(audience)), ("sub", jsonString(subject)), ("nonce", jsonString(nonce)), ("exp", number(expiry))])
    }
    func tokens(nonce!: String = "nonce", scope!: String = REQUESTED_SCOPES, kid!: String = "test-key"): String {
        object([("token_type", jsonString("Bearer")), ("access_token", jsonString("synthetic-access")), ("refresh_token", jsonString("synthetic-rotated-refresh")), ("id_token", jsonString(jwt(claims(nonce: nonce), kid: kid))), ("scope", jsonString(scope)), ("expires_in", number(3600)), ("earliest_refresh_at", number(0))]).stringify()
    }
}
class TestAuthHttp <: AuthHttp {
    let identity: TestIdentity
    var tokenCalls: Int64 = 0
    var jwksCalls: Int64 = 0
    var error = ""
    var errorStatus: Int64 = 400
    var transient: Int64 = 0
    var transportFailures: Int64 = 0
    var revokeStatus: Int64 = 200
    var grantedScope = REQUESTED_SCOPES
    var seenRefreshForm = ""
    init(identity: TestIdentity) { this.identity = identity }
    public func send(url: String, method: String, body: String): AuthReply {
        if (url.endsWith("openid-configuration")) {
            return AuthReply(200, object([("issuer", jsonString(ISSUER)), ("authorization_endpoint", jsonString(ISSUER + "/api/accounts/authorize")), ("token_endpoint", jsonString(ISSUER + "/api/accounts/oauth/token")), ("jwks_uri", jsonString(ISSUER + "/.well-known/jwks.json")), ("revocation_endpoint", jsonString(ISSUER + "/api/accounts/oauth/revoke"))]).stringify())
        }
        if (url.endsWith("jwks.json")) { jwksCalls++; return AuthReply(200, identity.jwks) }
        if (url.endsWith("oauth/revoke")) { require(method == "POST" && body.contains("client_id=issued-client"), "Bad revocation request"); return AuthReply(revokeStatus, "") }
        require(url.endsWith("oauth/token") && method == "POST", "Unexpected OAuth request")
        tokenCalls++; seenRefreshForm = body
        if (transportFailures > 0) { transportFailures--; throw ExampleError("Synthetic OAuth transport failure") }
        if (transient > 0) { transient--; return AuthReply(503, "{\"error\":\"temporarily_unavailable\"}") }
        if (error != "") { return AuthReply(errorStatus, object([("error", jsonString(error))]).stringify()) }
        AuthReply(200, identity.tokens(scope: grantedScope))
    }
}
func testStore(): AccountStore { AccountStore(Directory.createTemp(getVariable("TMPDIR").getOrThrow()).toString() + "/credentials") }
func expectExampleFailure(body: () -> Unit): Unit { try { body(); @Fail("expected rejection") } catch (_: ExampleError) { () } }
func expiredAccount(account: LlmWireJson): LlmWireJson {
    let fields = ArrayList<(String, LlmWireJson)>()
    for (entry in account.fields()) { fields.add((entry.name, if (entry.name == "expires_at") { number(1) } else { entry.value })) }
    object(fields.toArray())
}
func seed(store: AccountStore, auth: AuthManager, identity: TestIdentity): Unit {
    let account = expiredAccount(auth.tokenAccount(json(identity.tokens()), "account", "issued-client", "nonce", ""))
    store.locked({ => store.save(replaceAccount(store.load(), "account", account)) })
}

@Test
class CodexExampleTest {
    @TestCase
    func pkceCallbackAndIssuedClient() {
        let attempt = LoginAttempt("dynamic_agent_client", "http://127.0.0.1:1455/auth/callback", "urn:uuid:00000000-0000-4000-8000-000000000000")
        let url = attempt.authorizationUrl()
        @Expect(url.contains("code_challenge_method=S256"), true)
        @Expect(url.contains("agent_name_hint=llm4cj%20Codex%20Example"), true)
        @Expect(url.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"), true)
        let result = attempt.callback("/auth/callback?code=code&state=" + attempt.state + "&client_id=issued-client")
        @Expect(result[0], "code"); @Expect(result[1], "issued-client")
        expectExampleFailure({ => let _ = attempt.callback("/auth/callback?code=code&state=wrong&client_id=issued-client") })
        expectExampleFailure({ => let _ = attempt.callback("/auth/callback?code=code&state=" + attempt.state) })
        expectExampleFailure({ => let _ = attempt.callback("/auth/callback?code=code&state=" + attempt.state + "&state=" + attempt.state + "&client_id=issued-client") })
        let returning = LoginAttempt("issued-client", attempt.redirect, attempt.host)
        expectExampleFailure({ => let _ = returning.callback("/auth/callback?code=code&state=" + returning.state + "&client_id=other-client") })
        @Expect(returning.authorizationUrl().contains("agent_name_hint"), false)
        @Expect(base64Url(decodeBase64Url("YWJj")), "YWJj")
        expectExampleFailure({ => let _ = decodeBase64Url("YWJj=") })
    }

    @TestCase
    func realRsaSignaturesAndIdentityChecks() {
        let identity = TestIdentity(); let resolver = { _: String => identity.publicKey }
        let token = identity.jwt(identity.claims())
        let claims = validateIdToken(token, "issued-client", "nonce", "subject", resolver, 100)
        @Expect(text(claims, "sub"), "subject")
        expectExampleFailure({ => let _ = validateIdToken(token, "wrong-client", "nonce", "subject", resolver, 100) })
        expectExampleFailure({ => let _ = validateIdToken(token, "issued-client", "wrong-nonce", "subject", resolver, 100) })
        expectExampleFailure({ => let _ = validateIdToken(token, "issued-client", "nonce", "wrong-subject", resolver, 100) })
        expectExampleFailure({ => let _ = validateIdToken(identity.jwt(identity.claims(expiry: 99)), "issued-client", "nonce", "subject", resolver, 100) })
        expectExampleFailure({ => let _ = validateIdToken(identity.jwt(identity.claims(), algorithm: "HS256"), "issued-client", "nonce", "subject", resolver, 100) })
        let different = TestIdentity()
        expectExampleFailure({ => let _ = validateIdToken(token, "issued-client", "nonce", "subject", { _: String => different.publicKey }, 100) })
        let jwk = field(json(identity.jwks), "keys").values()[0]
        let _ = validateIdToken(token, "issued-client", "nonce", "subject", { _: String => jwkPublicKey(jwk) }, 100)
    }

    @TestCase
    func refreshRotationAndConcurrentReaders() {
        let identity = TestIdentity(); let http = TestAuthHttp(identity); let store = testStore(); let auth = AuthManager(store, http: http)
        seed(store, auth, identity)
        let first = spawn { auth.access("account") }; let second = spawn { auth.access("account") }
        @Expect(first.get(), "synthetic-access"); @Expect(second.get(), "synthetic-access"); @Expect(http.tokenCalls, 1)
        @Expect(http.seenRefreshForm.contains("client_id=issued-client"), true)
        @Expect(http.seenRefreshForm.contains("scope="), false)
        @Expect(http.seenRefreshForm.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"), true)
        let saved = store.locked({ => findAccount(store.load(), "account") })
        @Expect(text(saved, "refresh_token"), "synthetic-rotated-refresh")
        @Expect(integer(saved, "expires_at") > nowSeconds(), true)
        let (_, permissions, _) = Process.runOutput("stat", ["-c", "%a", store.directory + "/accounts.json"])
        @Expect(String.fromUtf8(permissions).trimAscii(), "600")
        let (_, directoryPermissions, _) = Process.runOutput("stat", ["-c", "%a", store.directory])
        @Expect(String.fromUtf8(directoryPermissions).trimAscii(), "700")
    }

    @TestCase
    func unusableRefreshErrorsClearTokensAndStopRefreshRetries() {
        let identity = TestIdentity()
        for (code in ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]) {
            let store = testStore(); let http = TestAuthHttp(identity); let auth = AuthManager(store, http: http)
            seed(store, auth, identity); http.error = code
            let host = store.locked({ => text(store.load(), "host_id") })
            try { let _ = auth.access("account"); @Fail("unusable refresh token must require sign-in") }
            catch (error: TokenEndpointError) { @Expect(error.code, code) }
            let state = store.locked({ => store.load() }); let signedOut = findAccount(state, "account")
            for (name in ["access_token", "refresh_token", "id_token", "scope", "expires_at", "earliest_refresh_at"]) {
                @Expect(signedOut.field(name).isNone(), true)
            }
            @Expect(text(signedOut, "label"), "account"); @Expect(text(signedOut, "client_id"), "issued-client")
            @Expect(text(signedOut, "sub"), "subject"); @Expect(text(state, "host_id") == host, true)
            @Expect(http.tokenCalls, 1)
            expectExampleFailure({ => let _ = auth.access("account") })
            @Expect(http.tokenCalls, 1)
        }
    }

    @TestCase
    func nonterminalRefreshFailuresRetainCredentials() {
        let identity = TestIdentity()
        for ((status, code) in [(400, "invalid_client"), (400, "temporarily_unavailable"), (400, "server_error"),
            (400, "unknown_error"), (302, "invalid_grant"), (503, "invalid_grant")]) {
            let store = testStore(); let http = TestAuthHttp(identity); let auth = AuthManager(store, http: http)
            seed(store, auth, identity); http.error = code; http.errorStatus = status
            let before = store.locked({ => store.load().stringify() })
            expectExampleFailure({ => let _ = auth.access("account") })
            @Expect(http.tokenCalls, if (status >= 500) { 3 } else { 1 })
            @Expect(store.locked({ => store.load().stringify() }) == before, true)
        }
        for (network in [false, true]) {
            let store = testStore(); let http = TestAuthHttp(identity); let auth = AuthManager(store, http: http)
            seed(store, auth, identity)
            if (network) { http.transportFailures = 3 } else { http.transient = 3 }
            let before = store.locked({ => store.load().stringify() })
            expectExampleFailure({ => let _ = auth.access("account") })
            @Expect(http.tokenCalls, 3)
            @Expect(store.locked({ => store.load().stringify() }) == before, true)
            let access = auth.access("account")
            @Expect(access != "", true); @Expect(http.tokenCalls, 4)
        }
    }

    @TestCase
    func scopesUnknownKidAndLogout() {
        let identity = TestIdentity(); let store = testStore(); let http = TestAuthHttp(identity); let auth = AuthManager(store, http: http)
        seed(store, auth, identity); http.grantedScope = "openid profile email offline_access resource.invoke"
        expectExampleFailure({ => let _ = auth.access("account") })
        @Expect(store.locked({ => canInvoke(findAccount(store.load(), "account")) }), false)
        let freshHttp = TestAuthHttp(identity); let fresh = AuthManager(store, http: freshHttp)
        expectExampleFailure({ => let _ = fresh.tokenAccount(json(identity.tokens(kid: "missing")), "account", "issued-client", "nonce", "") })
        @Expect(freshHttp.jwksCalls, 2)
        http.revokeStatus = 503; @Expect(auth.logout("account"), false)
        @Expect(store.locked({ => optionalText(findAccount(store.load(), "account"), "refresh_token") }), "")
        @Expect(auth.logout("account"), true)
    }

    @TestCase
    func loopbackCallbackAndMessageFragmentBounds() {
        let listener = CallbackListener(); let attempt = LoginAttempt("dynamic_agent_client", listener.redirect, hostId())
        let address = (listener.server.localAddress as IPSocketAddress).getOrThrow()
        let peer = spawn {
            let socket = TcpSocket("127.0.0.1", address.port); socket.connect(timeout: Some(Duration.second * 5))
            try {
                socket.write(("GET /auth/callback?code=code&state=" + attempt.state + "&client_id=issued-client HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").toArray())
                let buffer = Array<Byte>(512, repeat: 0); let count = socket.read(buffer)
                String.fromUtf8(buffer[0..count])
            } finally { socket.close() }
        }
        try { @Expect(listener.awaitCallback(attempt)[1], "issued-client"); @Expect(peer.get().contains("200 OK"), true) } finally { listener.closeListener() }
        let fragments = MessageFragments()
        @Expect(fragments.push(WebSocketFrameType.TextWebFrame, [123u8], false).isNone(), true)
        @Expect(fragments.push(WebSocketFrameType.ContinuationWebFrame, [125u8], true).getOrThrow(), "{}".toArray())
        expectExampleFailure({ => let _ = fragments.push(WebSocketFrameType.ContinuationWebFrame, [], true) })
        expectExampleFailure({ => let _ = fragments.push(WebSocketFrameType.BinaryWebFrame, [], true) })
        expectExampleFailure({ => let _ = fragments.push(WebSocketFrameType.TextWebFrame, Array<Byte>(8388609, repeat: 0u8), true) })
    }
}
