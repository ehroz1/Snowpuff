import AppKit
import CoreAudio
import CoreMediaIO

/// Notices a call or a recording: another app using the camera or the microphone. Checked every few seconds;
/// it takes a few seconds of use to count, and a few without to end, so a quick dictation doesn't flicker it.
final class CallMonitor {
    var changed: (Bool) -> Void = { _ in }
    private(set) var inCall = false
    private var timer: Timer?
    private var busySince: Date?
    private var freeSince: Date?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        busySince = nil
        freeSince = nil
        if inCall {
            inCall = false
            changed(false)
        }
    }

    private func check() {
        let busy = Self.cameraInUse() || microphoneInUseByOthers()
        let now = Date()
        if busy {
            freeSince = nil
            busySince = busySince ?? now
            if !inCall, now.timeIntervalSince(busySince!) >= 3 {
                inCall = true
                changed(true)
            }
        } else {
            busySince = nil
            freeSince = freeSince ?? now
            if inCall, now.timeIntervalSince(freeSince!) >= 4 {
                inCall = false
                changed(false)
            }
        }
    }

    // MARK: - Camera

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, runningSize, &runningSize, &running) == 0, running != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Microphone

    /// Another process recording: macOS 14.2 lists the processes using audio, so the app's own breath listening
    /// doesn't count. Before that, any use of the default input does.
    private func microphoneInUseByOthers() -> Bool {
        if #available(macOS 14.2, *) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
            var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return false }
            for process in processes {
                guard Self.uint32(process, kAudioProcessPropertyIsRunningInput) != 0 else { continue }
                var pid: pid_t = 0
                var pidSize = UInt32(MemoryLayout<pid_t>.size)
                var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }
                if pid != ownPID { return true }
            }
            return false
        }
        var device = AudioObjectID(0)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &deviceSize, &device) == noErr else { return false }
        return Self.uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}
