import AppKit
import Darwin
import IOKit

/// Small DDC/CI brightness control for external displays exposed by Apple Silicon's AV services.
/// IOAVService is an undocumented system interface, so lack of the symbols is treated as unsupported.
enum ExternalDisplayDDC {
    private static let ddcAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let commandQueue = DispatchQueue(label: "com.ailock.display-brightness-ddc")

    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias CopyEDID = @convention(c) (AnyObject, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    private typealias WriteI2C = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn

    private struct Functions {
        let library: UnsafeMutableRawPointer
        let createService: CreateService
        let writeI2C: WriteI2C
        let copyEDID: CopyEDID?
    }

    private static let functionTable: Functions? = loadFunctions()

    private static func functions() -> Functions? { functionTable }

    private static func loadFunctions() -> Functions? {
        #if arch(arm64)
        guard let library = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) else { return nil }
        guard let createSymbol = dlsym(library, "IOAVServiceCreateWithService"),
              let writeSymbol = dlsym(library, "IOAVServiceWriteI2C") else {
            dlclose(library)
            return nil
        }
        return Functions(
            library: library,
            createService: unsafeBitCast(createSymbol, to: CreateService.self),
            writeI2C: unsafeBitCast(writeSymbol, to: WriteI2C.self),
            copyEDID: dlsym(library, "IOAVServiceCopyEDID").map { unsafeBitCast($0, to: CopyEDID.self) }
        )
        #else
        return nil
        #endif
    }

    private static func externalServices() -> [io_service_t] {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External" {
                services.append(service)
            } else {
                IOObjectRelease(service)
            }
        }
        return services
    }

    struct DisplayTarget: Identifiable, Sendable {
        let id: CGDirectDisplayID
        let name: String
        let builtIn: Bool
    }

    static func connectedDisplays() -> [DisplayTarget] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return DisplayTarget(id: id, name: screen.localizedName, builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    private static func onlineExternalIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Resolve each physical bus by EDID, never by enumeration order. Ambiguous
    /// identical monitors are left unmapped rather than writing to another screen.
    private static func displayID(for service: AnyObject, functions: Functions, candidates: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        guard let copy = functions.copyEDID else { return nil }
        var unmanaged: Unmanaged<CFData>?
        guard copy(service, &unmanaged) == KERN_SUCCESS, let data = unmanaged?.takeRetainedValue() else { return nil }
        let bytes = [UInt8](data as Data)
        guard bytes.count >= 128, Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
              bytes.prefix(128).reduce(0, { ($0 + Int($1)) & 255 }) == 0 else { return nil }
        let vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        let product = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        let serial = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[12 + $1]) << (8 * $1) }
        let matches = candidates.filter {
            CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == product
                && (serial == 0 || CGDisplaySerialNumber($0) == serial)
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func setControl(_ code: UInt8, percent: Int, displayIDs: Set<CGDirectDisplayID>) -> (sent: Int, failed: Int, lastError: IOReturn?)? {
        commandQueue.sync {
            guard let functions = functions() else { return nil }
            let services = externalServices()
            defer { services.forEach { _ = IOObjectRelease($0) } }
            let candidates = onlineExternalIDs()
            var sent = 0
            var failed = 0
            var handled = Set<CGDirectDisplayID>()
            var lastError: IOReturn?
            for registryService in services {
                guard let service = functions.createService(kCFAllocatorDefault, registryService)?.takeRetainedValue() else { continue }
                let mapped = displayID(for: service, functions: functions, candidates: candidates)
                guard let id = mapped, displayIDs.contains(id), handled.insert(id).inserted else { continue }
                var packet: [UInt8] = [0x84, 0x03, code, 0x00, UInt8(max(0, min(100, percent))), 0]
                packet[5] = packet.dropLast().reduce(UInt8((ddcAddress << 1) ^ dataAddress), ^)
                let result = packet.withUnsafeMutableBufferPointer {
                    functions.writeI2C(service, ddcAddress, dataAddress, $0.baseAddress!, UInt32($0.count))
                }
                if result == KERN_SUCCESS { sent += 1 }
                else { failed += 1; lastError = result }
            }
            // A missing/ambiguous mapping must be reported as failure.
            failed += displayIDs.subtracting(handled).count
            return (sent, failed, lastError)
        }
    }

}
