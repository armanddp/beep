import Foundation

/// Temporarily mutes macOS alert sounds and restores them on cleanup.
///
/// On macOS, thermal warnings are typically played through the alert sound system,
/// which has a separate volume from media audio. This silencer sets the alert
/// volume to 0 while active and restores the original level on `restore()`.
///
/// Note: If the beep originates from SMC firmware directly (bypassing CoreAudio),
/// this won't help — but that's uncommon on Apple Silicon Macs.
class AlertSilencer {
    private var savedAlertVolume: Int?
    private var isActive = false

    /// Mute alert sounds. Returns true if successful.
    @discardableResult
    func silence() -> Bool {
        // Save current alert volume
        if let current = runOsascript("get alert volume of (get volume settings)"),
           let vol = Int(current.trimmingCharacters(in: .whitespacesAndNewlines)) {
            savedAlertVolume = vol
        } else {
            savedAlertVolume = 50 // sensible fallback
        }

        // Set alert volume to 0
        if runOsascript("set volume alert volume 0") != nil {
            isActive = true
            return true
        }
        return false
    }

    /// Restore the original alert volume.
    func restore() {
        guard isActive, let vol = savedAlertVolume else { return }
        _ = runOsascript("set volume alert volume \(vol)")
        isActive = false
    }

    /// Whether alerts are currently silenced by us.
    var isSilenced: Bool { isActive }

    /// Human-readable status for display.
    var statusText: String {
        if isActive {
            return "Alert sounds silenced (was \(savedAlertVolume ?? 0)%)"
        }
        return ""
    }

    deinit {
        restore()
    }

    // MARK: - Private

    @discardableResult
    private func runOsascript(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            }
        } catch {
            // silently fail
        }
        return nil
    }
}
