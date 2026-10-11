import Foundation
import Darwin

// Bind only loopback fixture sockets; lsof is constrained to this test process.
func endpoint(_ type: Int32) throws -> (Int32, String) {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard result == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return (fd, "127.0.0.1:\(UInt16(bigEndian: address.sin_port))")
}
let (tcp, tcpAddress) = try endpoint(SOCK_STREAM)
let (udp, udpAddress) = try endpoint(SOCK_DGRAM)
defer { close(tcp); close(udp) }
precondition(listen(tcp, 1) == 0)
let output = try CommandRunner.run("/usr/sbin/lsof", arguments: ["-nP", "-a", "-p", String(getpid()), "-iTCP", "-iUDP", "-FpcfPnT"])
let entries = NetworkInspector.parse(output)
precondition(entries.contains { $0.pid == getpid() && $0.protocolName == "TCP" && $0.local == tcpAddress && $0.state == "LISTEN" })
print("PASS: real lsof snapshot includes the fixture TCP listener")
precondition(entries.contains { $0.pid == getpid() && $0.protocolName == "UDP" && $0.local == udpAddress && $0.state == "UNCONNECTED" })
print("PASS: the same lsof snapshot includes the fixture UDP endpoint")
precondition(entries.allSatisfy { $0.pid == getpid() })
print("PASS: snapshot validation reads only its own fixture process")
