import Foundation

// MARK: - Fan Info

struct FanInfo {
    let index: Int
    let name: String
    let actualSpeed: Float
    let targetSpeed: Float?
    let minSpeed: Float?
    let maxSpeed: Float?

    var isRunning: Bool { actualSpeed > 10 }

    /// Health status evaluated in isolation. Use `FanMonitor.detectWarnings`
    /// for context-aware diagnostics (e.g. one fan dead while the other spins).
    func healthStatus(otherFanSpeed: Float? = nil) -> FanHealth {
        if actualSpeed < 10 {
            // If SMC reports a target, the fan should be spinning
            if let target = targetSpeed, target > 100 {
                return .stalled
            }
            // If the OTHER fan is spinning significantly, this fan is likely stuck
            // (the system needs cooling but this fan isn't responding)
            if let other = otherFanSpeed, other > 500 {
                return .stalled
            }
            return .stopped
        }
        if let target = targetSpeed, target > 100 {
            let ratio = actualSpeed / target
            if ratio < 0.5 { return .underperforming }
        }
        return .normal
    }

    enum FanHealth {
        case normal
        case stopped         // Not spinning, no demand
        case stalled         // Not spinning despite demand — likely broken
        case underperforming // Spinning well below target
    }
}

// MARK: - Thermal Reading

struct ThermalReading {
    let key: String
    let label: String
    let temperature: Float

    var isWarning: Bool { temperature > 90 }
    var isCritical: Bool { temperature > 100 }
}

// MARK: - Fan Monitor

class FanMonitor {
    let smc: SMCConnection

    init(smc: SMCConnection) {
        self.smc = smc
    }

    // MARK: - Fan Data

    var fanCount: Int {
        Int(smc.readUInt8("FNum") ?? 0)
    }

    func readFan(_ index: Int) -> FanInfo? {
        let prefix = "F\(index)"
        guard let actual = smc.readFloat("\(prefix)Ac") else { return nil }

        let target = smc.readFloat("\(prefix)Tg")
        let minSpeed = smc.readFloat("\(prefix)Mn")
        let maxSpeed = smc.readFloat("\(prefix)Mx")

        // On the 14" MacBook Pro, fan 0 is left, fan 1 is right
        let name: String
        switch index {
        case 0: name = "Left Fan"
        case 1: name = "Right Fan"
        default: name = "Fan \(index)"
        }

        return FanInfo(
            index: index,
            name: name,
            actualSpeed: actual,
            targetSpeed: target,
            minSpeed: minSpeed,
            maxSpeed: maxSpeed
        )
    }

    func readAllFans() -> [FanInfo] {
        let count = fanCount
        guard count > 0 else { return [] }
        return (0..<count).compactMap { readFan($0) }
    }

    // MARK: - Temperature Data

    func readTemperatures() -> [ThermalReading] {
        // Curated list of temperature keys for Apple Silicon Macs.
        // Not all keys exist on every model — we try each and keep what works.
        let candidates: [(key: String, label: String)] = [
            // CPU
            ("Tp09", "CPU P-Core 1"),
            ("Tp0T", "CPU P-Core 2"),
            ("Tp01", "CPU E-Core 1"),
            ("Tp05", "CPU E-Core 2"),
            ("TC0P", "CPU Proximity"),
            ("Tc0p", "CPU Proximity"),
            ("Tp0P", "CPU Package"),
            // GPU
            ("Tg05", "GPU 1"),
            ("Tg0D", "GPU 2"),
            ("Tg0P", "GPU Proximity"),
            ("TG0P", "GPU Proximity"),
            // System
            ("TW0P", "Wireless"),
            ("Tm0P", "Memory"),
            ("TB0T", "Battery"),
            ("Ts0P", "Palm Rest"),
            ("TaLP", "Airflow Left"),
            ("TaRP", "Airflow Right"),
            ("TH0a", "Heatsink 1"),
            ("TH0b", "Heatsink 2"),
            ("TN0P", "SSD"),
        ]

        var readings: [ThermalReading] = []
        var seenLabels = Set<String>()

        for (key, label) in candidates {
            guard !seenLabels.contains(label) else { continue }
            if let temp = smc.readFloat(key),
               temp > 1, temp < 150 {  // >1 filters out 0.0°C "ghost" keys
                readings.append(ThermalReading(key: key, label: label, temperature: temp))
                seenLabels.insert(label)
            }
        }

        return readings
    }

    // MARK: - Warning Detection

    func detectWarnings(fans: [FanInfo]) -> [String] {
        var warnings: [String] = []

        // Build context: what is the other fan doing?
        for (i, fan) in fans.enumerated() {
            let otherSpeed: Float? = fans.count >= 2
                ? fans[i == 0 ? 1 : 0].actualSpeed
                : nil

            switch fan.healthStatus(otherFanSpeed: otherSpeed) {
            case .stalled:
                let otherInfo: String
                if let other = otherSpeed, other > 100 {
                    otherInfo = String(format: " (other fan at %.0f RPM)", other)
                } else {
                    let target = fan.targetSpeed.map { String(format: ", target: %.0f RPM", $0) } ?? ""
                    otherInfo = target
                }
                warnings.append(
                    "CRITICAL: \(fan.name) is NOT SPINNING!\(otherInfo) "
                    + "— fan may be stuck or dead"
                )

            case .underperforming:
                let actual = String(format: "%.0f", fan.actualSpeed)
                let target = fan.targetSpeed.map { String(format: "%.0f", $0) } ?? "?"
                warnings.append(
                    "WARNING: \(fan.name) at \(actual) RPM "
                    + "(target: \(target) RPM — significantly below target)"
                )

            case .stopped, .normal:
                break
            }
        }

        return warnings
    }
}
