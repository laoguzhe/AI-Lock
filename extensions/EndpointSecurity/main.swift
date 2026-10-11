import Foundation
import EndpointSecurity
import Darwin

// Development prototype: NOTIFY only, explicit root, no authorization/blocking events.
func tokenString(_ token: es_string_token_t) -> String {
    guard let data = token.data else { return "" }
    return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: token.length), as: UTF8.self)
}
// Shared by CLI and XPC to keep event coverage identical.
let auditEventTypes = [ES_EVENT_TYPE_NOTIFY_OPEN, ES_EVENT_TYPE_NOTIFY_CLOSE,
    ES_EVENT_TYPE_NOTIFY_CREATE, ES_EVENT_TYPE_NOTIFY_WRITE,
    ES_EVENT_TYPE_NOTIFY_UNLINK, ES_EVENT_TYPE_NOTIFY_RENAME]
func auditEvent(_ message: UnsafePointer<es_message_t>) -> [String: Any]? {
    let msg = message.pointee
    var destination: String?
    let path: String
    let kind: String
    var modified: Bool?
    switch msg.event_type {
    case ES_EVENT_TYPE_NOTIFY_OPEN: path = tokenString(msg.event.open.file.pointee.path); kind = "open"
    case ES_EVENT_TYPE_NOTIFY_WRITE: path = tokenString(msg.event.write.target.pointee.path); kind = "write"
    case ES_EVENT_TYPE_NOTIFY_CREATE:
        let create = msg.event.create
        kind = "create"
        switch create.destination_type {
        case ES_DESTINATION_TYPE_EXISTING_FILE: path = tokenString(create.destination.existing_file.pointee.path)
        case ES_DESTINATION_TYPE_NEW_PATH:
            path = URL(fileURLWithPath: tokenString(create.destination.new_path.dir.pointee.path))
                .appendingPathComponent(tokenString(create.destination.new_path.filename)).path
        default: return nil
        }
    case ES_EVENT_TYPE_NOTIFY_CLOSE:
        path = tokenString(msg.event.close.target.pointee.path); kind = "close"; modified = msg.event.close.modified
    case ES_EVENT_TYPE_NOTIFY_UNLINK: path = tokenString(msg.event.unlink.target.pointee.path); kind = "unlink"
    case ES_EVENT_TYPE_NOTIFY_RENAME:
        path = tokenString(msg.event.rename.source.pointee.path); kind = "rename"
        let rename = msg.event.rename
        switch rename.destination_type {
        case ES_DESTINATION_TYPE_EXISTING_FILE:
            destination = tokenString(rename.destination.existing_file.pointee.path)
        case ES_DESTINATION_TYPE_NEW_PATH:
            destination = URL(fileURLWithPath: tokenString(rename.destination.new_path.dir.pointee.path))
                .appendingPathComponent(tokenString(rename.destination.new_path.filename)).path
        default: break
        }
    default: return nil
    }
    var event: [String: Any] = ["schemaVersion": 1, "eventID": UUID().uuidString, "kind": kind, "path": path,
        "pid": msg.process.pointee.audit_token.val.5,
        "executable": tokenString(msg.process.pointee.executable.pointee.path),
        "receivedAt": Date().timeIntervalSince1970]
    let process = msg.process.pointee
    event["pidVersion"] = process.audit_token.val.7
    event["parentPID"] = process.ppid
    event["signingID"] = tokenString(process.signing_id)
    event["teamID"] = tokenString(process.team_id)
    event["codeSigningFlags"] = process.codesigning_flags
    event["platformBinary"] = process.is_platform_binary
    if msg.event_type == ES_EVENT_TYPE_NOTIFY_OPEN { event["openFlags"] = msg.event.open.fflag }
    if msg.version >= 2 { event["sequence"] = msg.seq_num }
    if msg.version >= 4 { event["globalSequence"] = msg.global_seq_num }
    if let modified { event["modified"] = modified }
    if let destination { event["destinationPath"] = destination }
    return event
}
func auditEventMatches(_ event: [String: Any], root: String) -> Bool {
    func inside(_ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    return (event["path"] as? String).map(inside) == true || (event["destinationPath"] as? String).map(inside) == true
}
if CommandLine.arguments.count == 1, Bundle.main.bundleIdentifier == AuditIPCIdentity.bundleID {
    guard let team = AuditIPCIdentity.team(), let name = Bundle.main.object(forInfoDictionaryKey: "NSEndpointSecurityMachServiceName") as? String,
          name == team + "." + AuditIPCIdentity.bundleID else { fputs("Audit IPC signing or service configuration invalid.\n", stderr); exit(1) }
    let service = AuditIPCService(team: team, serviceName: name)
    service.start(); dispatchMain()
}
guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
    fputs("Usage: AILockAuditPrototype /absolute/directory\nRequires approved ES entitlement, root privileges and Full Disk Access.\n", stderr); exit(2)
}
let root = FilesystemPath.canonical(URL(fileURLWithPath: CommandLine.arguments[1])).path
let sequences = AuditSequenceTracker()
let output = BoundedAuditWriter { try FileHandle.standardOutput.write(contentsOf: $0) }
var client: OpaquePointer?
let result = es_new_client(&client) { _, message in
    let msg = message.pointee
    if msg.version >= 2 {
        let dropped = sequences.observe(type: msg.event_type.rawValue, sequence: msg.seq_num)
        if dropped > 0 { output.submit(["schemaVersion": 1, "kind": "kernel-events-dropped", "eventType": msg.event_type.rawValue, "count": dropped]) }
    }
    guard let event = auditEvent(message), auditEventMatches(event, root: root) else { return }
    output.submit(event)
}
guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let client else {
    fputs("Endpoint Security client creation failed: \(result.rawValue). No events collected.\n", stderr); exit(1)
}
var events = auditEventTypes
guard es_subscribe(client, &events, UInt32(events.count)) == ES_RETURN_SUCCESS else {
    es_delete_client(client); fputs("Endpoint Security subscription failed.\n", stderr); exit(1)
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let stopInterrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let stopTerminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
for source in [stopInterrupt, stopTerminate] {
    source.setEventHandler { es_delete_client(client); exit(0) }
    source.resume()
}
dispatchMain()
