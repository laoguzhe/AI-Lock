import AVFoundation
import CoreAudio
import Foundation

/// Polls system device state only. It never starts a capture session or reads media.
final class MediaAccessMonitor {
    static let shared = MediaAccessMonitor()

    private(set) var cameraInUse = false
    private(set) var microphoneInUse = false
    private let queue = DispatchQueue(label: "com.laogu.ailock.media-access", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    func configureFromPreferences() {
        dispatchPrecondition(condition: .onQueue(.main))
        let defaults = UserDefaults.standard
        let watchCamera = defaults.bool(forKey: "alert.camera.enabled")
        let watchMicrophone = defaults.bool(forKey: "alert.microphone.enabled")
        timer?.cancel()
        timer = nil

        guard watchCamera || watchMicrophone else {
            publish(camera: false, microphone: false)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let camera = watchCamera && Self.isCameraInUse()
            let microphone = watchMicrophone && Self.isMicrophoneInUse()
            self.publish(camera: camera, microphone: microphone)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.cancel()
        timer = nil
        publish(camera: false, microphone: false)
    }

    private func publish(camera: Bool, microphone: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.cameraInUse != camera || self.microphoneInUse != microphone else { return }
            self.cameraInUse = camera
            self.microphoneInUse = microphone
            NotificationCenter.default.post(name: .mediaAccessStateChanged, object: self)
        }
    }

    private static func isCameraInUse() -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.contains(where: \.isInUseByAnotherApplication)
    }

    private static func isMicrophoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioDeviceID>.size else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let status = devices.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else { return false }

        return devices.contains { device in
            guard hasInputChannels(device) else { return false }
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &size, &running) == noErr && running != 0
        }
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else { return false }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let buffers = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, storage) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(buffers).contains { $0.mNumberChannels > 0 }
    }
}

extension Notification.Name {
    static let mediaMonitoringSettingsChanged = Notification.Name("AILockMediaMonitoringSettingsChanged")
    static let mediaAccessStateChanged = Notification.Name("AILockMediaAccessStateChanged")
}
