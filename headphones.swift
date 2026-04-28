import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Configuration

let warningThreshold: TimeInterval = 60 * 60 // 60 minutes
let pollInterval: TimeInterval = 10 // seconds
let maxVolume: Float32 = 0.35 // ~35% as a safe hearing threshold proxy

// MARK: - State

var bluetoothStartTime: Date?
var previousOutputDeviceID: AudioDeviceID?

// MARK: - Helpers

/// kAudioHardwareServiceDeviceProperty_VirtualMainVolume = "vmvc" (removed in macos 12+)
let kVirtualMainVolume: AudioObjectPropertySelector = 0x766D7663 // "vmvc"

func getCurrentVolume(_ deviceID: AudioDeviceID) -> Float32 {
    var volume: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)

    // Try virtual master volume first (most reliable for Bluetooth)
    var address = AudioObjectPropertyAddress(
        mSelector: kVirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &address) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return volume
    }

    // Fall back: try channel 0 then channel 1
    for channel: UInt32 in [kAudioObjectPropertyElementMain, 1] {
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        if AudioObjectHasProperty(deviceID, &address) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            return volume
        }
    }
    return volume
}

func setVolume(_ deviceID: AudioDeviceID, volume: Float32) {
    var newVolume = volume
    let size = UInt32(MemoryLayout<Float32>.size)

    // Try virtual master volume first (most reliable for Bluetooth)
    var address = AudioObjectPropertyAddress(
        mSelector: kVirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &address) {
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(deviceID, &address, &settable)
        if settable.boolValue {
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newVolume)
            return
        }
    }

    // Fall back: try channel 0 (master) then channel 1
    for channel: UInt32 in [kAudioObjectPropertyElementMain, 1] {
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        if AudioObjectHasProperty(deviceID, &address) {
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &address, &settable)
            if settable.boolValue {
                AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newVolume)
                return
            }
        }
    }
    print("setVolume: no settable volume property found for device \(deviceID)")
}

func getDeviceName(_ deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
    return name?.takeRetainedValue() as String? ?? "Unknown"
}

func isBluetoothOutputDeviceActive() -> (isBluetooth: Bool, deviceID: AudioDeviceID) {
    var defaultDeviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &defaultDeviceID
    )

    if status != noErr {
        return (false, defaultDeviceID)
    }

    // Get transport type (Bluetooth, USB, etc.)
    var transportType: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)

    address.mSelector = kAudioDevicePropertyTransportType

    let transportStatus = AudioObjectGetPropertyData(
        defaultDeviceID,
        &address,
        0,
        nil,
        &size,
        &transportType
    )

    if transportStatus != noErr {
        print("Error getting transport type: \(transportStatus)")
        return (false, defaultDeviceID)
    }

    return (transportType == kAudioDeviceTransportTypeBluetooth, defaultDeviceID)
}

func enforceVolumeLimit(_ deviceID: AudioDeviceID) {
    let current = (getCurrentVolume(deviceID) * 100).rounded() / 100
    if current > maxVolume {
        print("[\(dateFormatter.string(from: Date()))] Volume capped: \(String(format: "%.2f", current)) → \(String(format: "%.2f", maxVolume))")
        setVolume(deviceID, volume: maxVolume)
    }
}

func runProcess(_ launchPath: String, _ arguments: [String]) {
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments
    try? task.run()
}

func showWarning() {
    let title = "Headphone Usage Warning"
    let body = "You have been using Bluetooth headphones for 60 minutes. Consider taking a break."

    // Play sound independently so it always fires
    runProcess("/usr/bin/afplay", ["/System/Library/Sounds/Basso.aiff"])

    // Send notification via osascript
    let script = """
    tell application "System Events"
        display notification "\(body)" with title "\(title)"
    end tell
    """
    runProcess("/usr/bin/osascript", ["-e", script])
}

// MARK: - Main Loop

let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
dateFormatter.timeZone = .current

print("[\(dateFormatter.string(from: Date()))] Bluetooth Headphone Monitor started")

Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
    let result = isBluetoothOutputDeviceActive()
    let currentDeviceID = result.deviceID

    if previousOutputDeviceID == nil {
        previousOutputDeviceID = currentDeviceID
    } else if currentDeviceID != previousOutputDeviceID {
        let deviceName = getDeviceName(currentDeviceID)
        let timestamp = dateFormatter.string(from: Date())
        print("[\(timestamp)] Audio output changed to: \(deviceName)")
        previousOutputDeviceID = currentDeviceID
    }

    if result.isBluetooth {
        enforceVolumeLimit(currentDeviceID)
        if bluetoothStartTime == nil {
            bluetoothStartTime = Date()
            print("[\(dateFormatter.string(from: Date()))] Bluetooth headphones detected")
        }
        if let start = bluetoothStartTime, Date().timeIntervalSince(start) >= warningThreshold {
            print("[\(dateFormatter.string(from: Date()))] Headphone Usage Warning")
            showWarning()
            bluetoothStartTime = Date() // reset timer after warning
        }
    } else {
        if bluetoothStartTime != nil {
            print("[\(dateFormatter.string(from: Date()))] Bluetooth headphones disconnected")
            setVolume(currentDeviceID, volume: 0)
        }
        bluetoothStartTime = nil
    }
}

RunLoop.main.run()

// Test that your system settings allow notifications (may need to adjust Focus settings)
// Run:
// osascript -e 'tell application "System Events" to display notification "Test body" with title "Test Title"'

// To build and run this app run:
// swiftc -o headphones headphones.swift -framework AudioToolbox
// ./headphones
