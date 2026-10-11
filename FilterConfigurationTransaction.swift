import Foundation
import Darwin

struct ExactHostPolicy: Equatable {
    let hosts: [String]
    init(_ input: [String]) throws {
        guard input.count <= 256 else { throw Failure("最多 256 条规则") }
        var normalized = Set<String>()
        for item in input {
            var host = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty, host.utf8.count <= 253,
                  host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:").contains($0) }) else {
                throw Failure("请输入精确主机名或 IP；不支持通配符、URL 或端口")
            }
            if host.contains(":") {
                var address = in6_addr()
                guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw Failure("IPv6 格式无效；不支持附带端口的主机规则") }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { throw Failure("IPv6 格式无效") }
                host = String(cString: buffer)
            } else {
                if host.hasSuffix(".") { host.removeLast() }
                let labels = host.split(separator: ".", omittingEmptySubsequences: false)
                guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" }) else { throw Failure("主机名格式无效") }
            }
            normalized.insert(host)
        }
        hosts = normalized.sorted()
    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
}

/// Read, save, verify; restore and verify the original on either write or readback failure.
/// The caller serializes operations. A rollback failure is explicitly reported.
final class FilterConfigurationTransaction<Snapshot: Equatable> {
    typealias Read = (@escaping (Result<Snapshot, Error>) -> Void) -> Void
    typealias Save = (Snapshot, @escaping (Error?) -> Void) -> Void
    private let read: Read
    private let save: Save
    private let canRestore: (Snapshot) -> Bool
    init(read: @escaping Read, save: @escaping Save, canRestore: @escaping (Snapshot) -> Bool = { _ in true }) { self.read = read; self.save = save; self.canRestore = canRestore }
    func apply(change: @escaping (Snapshot) throws -> Snapshot, completion: @escaping (Result<Snapshot, Error>) -> Void) {
        read { [self] initial in
            switch initial {
            case .failure(let error): completion(.failure(error))
            case .success(let original):
                let desired: Snapshot
                do { desired = try change(original) } catch { completion(.failure(error)); return }
                if desired == original { completion(.success(original)); return }
                func rollback(_ cause: Error) {
                    self.read { current in
                        guard case .success(let actual) = current else {
                            completion(.failure(ExactHostPolicy.Failure("\(cause.localizedDescription)；无法读取当前配置，未覆盖，请检查系统网络设置"))); return
                        }
                        if actual == original { completion(.failure(ExactHostPolicy.Failure("\(cause.localizedDescription)；原配置未改变"))); return }
                        guard self.canRestore(actual) else { completion(.failure(ExactHostPolicy.Failure("\(cause.localizedDescription)；配置已由其他来源改变，未覆盖"))); return }
                        self.save(original) { failure in
                            if let failure { completion(.failure(ExactHostPolicy.Failure("\(cause.localizedDescription)；回滚失败：\(failure.localizedDescription)，请检查系统网络设置"))); return }
                            self.read { result in
                                if case .success(let restored) = result, restored == original {
                                    completion(.failure(ExactHostPolicy.Failure("\(cause.localizedDescription)；已恢复原配置")))
                                } else { completion(.failure(ExactHostPolicy.Failure("\(cause.localizedDescription)；无法确认回滚结果，请检查系统网络设置"))) }
                            }
                        }
                    }
                }

                save(desired) { failure in
                    if let failure { rollback(failure); return }
                    self.read { result in
                        switch result {
                        case .success(let actual) where actual == desired: completion(.success(actual))
                        case .success: rollback(ExactHostPolicy.Failure("保存后的配置与请求不一致"))
                        case .failure(let error): rollback(error)
                        }
                    }
                }
            }
        }
    }
}
