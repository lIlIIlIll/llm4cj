package codex_subscription

import llm4cj.*
import std.collection.*
import std.env.*
import std.fs.Directory

// Linux-only storage. O_NOFOLLOW prevents following a substituted credential
// or lock symlink; atomic rename keeps readers away from partial token rotations.
foreign {
    func open(path: CString, flags: Int32, mode: UInt32): Int32
    func close(fd: Int32): Int32
    func fchmod(fd: Int32, mode: UInt32): Int32
    func flock(fd: Int32, operation: Int32): Int32
    func fsync(fd: Int32): Int32
    func read(fd: Int32, buffer: CPointer<Byte>, count: UIntNative): IntNative
    func write(fd: Int32, buffer: CPointer<Byte>, count: UIntNative): IntNative
    func rename(source: CString, destination: CString): Int32
    func unlink(path: CString): Int32
    func __errno_location(): CPointer<Int32>
}

func openPath(path: String, flags: Int32, mode!: UInt32 = 384u32): Int32 {
    openOutcome(path, flags, mode)[0]
}
func openOutcome(path: String, flags: Int32, mode: UInt32): (Int32, Int32) {
    unsafe { let c = LibC.mallocCString(path); try { let fd = open(c, flags, mode); (fd, if (fd < 0) { __errno_location().read() } else { 0 }) } finally { LibC.free(c) } }
}

class AccountStore {
    let directory: String
    init(directory: String) {
        this.directory = directory
        Directory.create(directory, recursive: true)
        let fd = openPath(directory, 65536 | 131072 | 524288)
        require(fd >= 0, "Credential directory must be a real directory owned by this user")
        try { unsafe { require(fchmod(fd, 448u32) == 0, "Cannot protect credential directory") } }
        finally { unsafe { let _ = close(fd) } }
    }
    static func userStore(): AccountStore {
        let base = match (getVariable("XDG_CONFIG_HOME")) { case Some(value) => value; case None => getVariable("HOME").getOrThrow() + "/.config" }
        require(base.startsWith("/"), "Configuration directory must be absolute")
        AccountStore(base + "/llm4cj-codex")
    }
    func locked<T>(operation: () -> T): T {
        let fd = openPath(directory + "/accounts.lock", 2 | 64 | 131072 | 524288)
        require(fd >= 0, "Cannot open credential lock")
        try {
            unsafe { require(fchmod(fd, 384u32) == 0 && flock(fd, 2) == 0, "Cannot lock credentials") }
            operation()
        } finally { unsafe { let _ = flock(fd, 8); let _ = close(fd) } }
    }
    func load(): LlmWireJson {
        let path = directory + "/accounts.json"
        let (fd, error) = openOutcome(path, 131072 | 524288, 384u32)
        if (fd < 0) {
            // A missing file is the only permitted empty-state condition.
            require(error == 2, "Cannot read credential file; links and inaccessible files are rejected")
            return object([("host_id", jsonString(hostId())), ("accounts", jsonArray([]))])
        }
        let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
        try {
            unsafe { require(fchmod(fd, 384u32) == 0, "Cannot protect credential file") }
            while (true) {
                let count = unsafe { let handle = acquireArrayRawData(buffer); try { Int64(read(fd, handle.pointer, UIntNative(buffer.size))) } finally { releaseArrayRawData(handle) } }
                require(count >= 0, "Cannot read credentials")
                if (count == 0) { break }
                require(count <= 1048576 - bytes.size, "Credential file exceeds 1 MiB")
                for (index in 0..count) { bytes.add(buffer[index]) }
            }
        } finally { unsafe { let _ = close(fd) } }
        let result = json(String.fromUtf8(bytes.toArray()))
        require(field(result, "accounts").kind == LlmWireJsonKind.Array, "Invalid account storage")
        require(text(result, "host_id").startsWith("urn:uuid:"), "Invalid host registration")
        result
    }
    func save(value: LlmWireJson): Unit {
        let data = value.stringify().toArray(); require(data.size <= 1048576, "Credential file exceeds 1 MiB")
        let temporary = directory + "/.tokens-" + randomUrl(18)
        let fd = openPath(temporary, 1 | 64 | 128 | 131072 | 524288)
        require(fd >= 0, "Cannot create protected credential file")
        try {
            var offset: Int64 = 0
            while (offset < data.size) {
                let slice = data[offset..data.size]
                let count = unsafe { let handle = acquireArrayRawData(slice); try { Int64(write(fd, handle.pointer, UIntNative(slice.size))) } finally { releaseArrayRawData(handle) } }
                require(count > 0, "Cannot write credentials"); offset += count
            }
            unsafe { require(fsync(fd) == 0, "Cannot sync credentials") }
        } catch (error: Exception) {
            unsafe { let c = LibC.mallocCString(temporary); try { let _ = unlink(c) } finally { LibC.free(c) } }
            throw error
        } finally { unsafe { let _ = close(fd) } }
        unsafe {
            let source = LibC.mallocCString(temporary); let destination = LibC.mallocCString(directory + "/accounts.json")
            try { require(rename(source, destination) == 0, "Cannot atomically replace credentials") }
            finally { let _ = unlink(source); LibC.free(source); LibC.free(destination) }
        }
        let parent = openPath(directory, 65536 | 131072 | 524288)
        require(parent >= 0, "Cannot sync credential directory")
        try { unsafe { require(fsync(parent) == 0, "Cannot sync credential directory") } } finally { unsafe { let _ = close(parent) } }
    }
}

func findAccount(state: LlmWireJson, label: String): LlmWireJson {
    for (account in field(state, "accounts").values() where text(account, "label") == label) { return account }
    throw ExampleError("Unknown account; run login with this label first")
}
func replaceAccount(state: LlmWireJson, label: String, account: LlmWireJson): LlmWireJson {
    let accounts = ArrayList<LlmWireJson>(); var replaced = false
    for (current in field(state, "accounts").values()) {
        if (text(current, "label") == label) { accounts.add(account); replaced = true } else { accounts.add(current) }
    }
    if (!replaced) { accounts.add(account) }
    require(accounts.size <= 64, "At most 64 registered accounts are supported")
    object([("host_id", field(state, "host_id")), ("accounts", jsonArray(accounts.toArray()))])
}
func clearTokens(account: LlmWireJson): LlmWireJson {
    let retained = ArrayList<(String, LlmWireJson)>()
    for (item in account.fields() where item.name == "label" || item.name == "client_id" || item.name == "sub") { retained.add((item.name, item.value)) }
    object(retained.toArray())
}
