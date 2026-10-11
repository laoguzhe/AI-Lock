import Foundation

@objc(AILockFilterHealthIPC) protocol AILockFilterHealthIPC {
    func install(policy: Data, reply: @escaping (Data?, String?) -> Void)
    func heartbeat(revision: String, reply: @escaping (Data?, String?) -> Void)
}
