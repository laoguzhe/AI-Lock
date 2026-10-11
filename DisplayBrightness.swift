import AppKit
import Darwin
import IOKit
import SwiftUI

/// Small DDC/CI brightness control for external displays exposed by Apple Silicon's AV services.
/// IOAVService is an undocumented system interface, so lack of the symbols is treated as unsupported.
enum ExternalDisplayDDC {
    private static let ddcAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias WriteI2C = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn

    private struct Functions {
        let library: UnsafeMutableRawPointer
        let createService: CreateService
        let writeI2C: WriteI2C
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
            writeI2C: unsafeBitCast(writeSymbol, to: WriteI2C.self)
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

    static func availableChannelCount() -> Int? {
        guard functions() != nil else { return nil }
        let services = externalServices()
        services.forEach { _ = IOObjectRelease($0) }
        return services.count
    }

    /// Sends VCP 0x10 to every external AV service. Success means the host API accepted
    /// the I2C write; the monitor may still ignore DDC/CI or require it to be enabled in its OSD.
    static func setBrightness(_ percent: Int) -> (sent: Int, failed: Int)? {
        guard let functions = functions() else { return nil }
        let services = externalServices()
        defer { services.forEach { _ = IOObjectRelease($0) } }
        guard !services.isEmpty else { return (0, 0) }

        var sent = 0
        var failed = 0
        for registryService in services {
            guard let avService = functions.createService(kCFAllocatorDefault, registryService)?.takeRetainedValue() else {
                failed += 1
                continue
            }

            var packet: [UInt8] = [0x84, 0x03, 0x10, 0x00, UInt8(max(0, min(100, percent))), 0]
            var checksum = UInt8((ddcAddress << 1) ^ dataAddress)
            for byte in packet.dropLast() { checksum ^= byte }
            packet[packet.count - 1] = checksum

            let result = packet.withUnsafeMutableBufferPointer { buffer in
                functions.writeI2C(avService, ddcAddress, dataAddress, buffer.baseAddress!, UInt32(buffer.count))
            }
            if result == KERN_SUCCESS { sent += 1 } else { failed += 1 }
        }
        return (sent, failed)
    }
}

struct DisplayBrightnessView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @State private var brightness = 50.0
    @State private var channelCount: Int?
    @State private var isApplying = false
    @State private var status = ""

    private var english: Bool { L10n.isEnglish }

    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 18) {
            Label(english ? "External Display Brightness" : "外接显示器亮度", systemImage: "sun.max")
                .font(.title2.weight(.semibold))

            Text(english
                 ? "Set one brightness value for all external displays that accept DDC/CI commands."
                 : "为所有接受 DDC/CI 命令的外接显示器设置统一亮度。")
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Image(systemName: "sun.min")
                Slider(value: $brightness, in: 0...100, step: 1)
                    .disabled(isApplying || channelCount == 0)
                Image(systemName: "sun.max.fill")
                Text("\(Int(brightness))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Button(action: applyBrightness) {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(english ? "Apply to all displays" : "应用到全部显示器")
                    }
                }
                .disabled(isApplying || channelCount == 0)

                Button(english ? "Rescan" : "重新扫描", action: scan)
                    .disabled(isApplying)
            }

            if let channelCount {
                Label(english ? "\(channelCount) external DDC channel(s) found" : "发现 \(channelCount) 个外接 DDC 通道", systemImage: channelCount > 0 ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(channelCount > 0 ? Color.secondary : Color.orange)
            } else {
                Label(english ? "Scanning for supported displays…" : "正在扫描可控制的显示器…", systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }

            Text(english
                 ? "This MVP sends hardware brightness commands only. It does not read the monitor's current value. DDC/CI must be supported and enabled by the display. Some HDMI adapters, docks, and Intel Macs are not supported."
                 : "此版本只发送硬件亮度命令，不读取显示器当前亮度。显示器需支持并启用 DDC/CI；部分 HDMI 转接器、扩展坞及 Intel Mac 不支持。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 700, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: scan)
    }

    private func scan() {
        status = ""
        Task {
            let count = await Task.detached(priority: .utility) { ExternalDisplayDDC.availableChannelCount() }.value
            channelCount = count ?? 0
            if count == nil {
                status = english
                    ? "DDC control is unavailable on this Mac."
                    : "此 Mac 当前无法使用 DDC 控制接口。"
            } else if count == 0 {
                status = english
                    ? "No supported external display was found."
                    : "未发现可用的外接显示器 DDC 通道。"
            }
        }
    }

    private func applyBrightness() {
        isApplying = true
        status = ""
        let value = Int(brightness)
        Task {
            let result = await Task.detached(priority: .userInitiated) { ExternalDisplayDDC.setBrightness(value) }.value
            isApplying = false
            guard let result else {
                channelCount = 0
                status = english ? "DDC control is unavailable on this Mac." : "此 Mac 当前无法使用 DDC 控制接口。"
                return
            }
            channelCount = result.sent + result.failed
            if result.sent == 0 {
                status = english
                    ? "No DDC command was sent. Check that DDC/CI is enabled in the monitor settings."
                    : "未能发送 DDC 命令。请检查显示器设置中的 DDC/CI 是否已开启。"
            } else if result.failed == 0 {
                status = english
                    ? "Command sent to \(result.sent) channel(s). The monitor may ignore unsupported commands."
                    : "已向 \(result.sent) 个通道发送命令；显示器可能忽略不支持的指令。"
            } else {
                status = english
                    ? "Sent to \(result.sent) channel(s); \(result.failed) failed."
                    : "已发送到 \(result.sent) 个通道，\(result.failed) 个通道失败。"
            }
        }
    }
}
