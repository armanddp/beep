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
    private let fanReadRetries = 3
    private let temperatureReadRetries = 2
    private let staleTTL: TimeInterval = 5
    private let discoveryInterval: TimeInterval = 30

    private var cachedFanCount: Int?
    private var lastFanReadAt: [Int: Date] = [:]
    private var cachedFans: [Int: FanInfo] = [:]

    private var activeTemperatureSensors: [(key: String, label: String)] = []
    private var cachedTemperatures: [String: ThermalReading] = [:]
    private var lastTemperatureReadAt: [String: Date] = [:]
    private var lastDiscoveryAt = Date.distantPast

    init(smc: SMCConnection) {
        self.smc = smc
    }

    // MARK: - Fan Data

    var fanCount: Int {
        if let count = smc.readUInt8("FNum"), count > 0 {
            cachedFanCount = Int(count)
            return Int(count)
        }
        return cachedFanCount ?? 0
    }

    func readFan(_ index: Int) -> FanInfo? {
        let prefix = "F\(index)"
        guard let actual = readValidatedFanValue("\(prefix)Ac") else { return nil }

        let target = readValidatedFanValue("\(prefix)Tg")
        let minSpeed = readValidatedFanValue("\(prefix)Mn")
        let maxSpeed = readValidatedFanValue("\(prefix)Mx")

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

    func readAllFans(now: Date = Date()) -> [FanInfo] {
        let count = fanCount
        guard count > 0 else {
            return fallbackFansIfFresh(now: now)
        }

        var fans: [FanInfo] = []
        for idx in 0..<count {
            if let fan = readFanWithRetry(idx, now: now) {
                fans.append(fan)
            }
        }

        if fans.isEmpty {
            return fallbackFansIfFresh(now: now)
        }
        return fans
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

        return readTemperatures(candidates: candidates)
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

    // MARK: - Internal Helpers

    private func readFanWithRetry(_ index: Int, now: Date) -> FanInfo? {
        for _ in 0..<fanReadRetries {
            if let fan = readFan(index) {
                cachedFans[index] = fan
                lastFanReadAt[index] = now
                return fan
            }
        }

        if let cached = cachedFans[index],
           let lastSeen = lastFanReadAt[index],
           now.timeIntervalSince(lastSeen) <= staleTTL {
            return cached
        }
        return nil
    }

    private func fallbackFansIfFresh(now: Date) -> [FanInfo] {
        let fresh = cachedFans.values.filter { fan in
            guard let lastSeen = lastFanReadAt[fan.index] else { return false }
            return now.timeIntervalSince(lastSeen) <= staleTTL
        }
        return fresh.sorted { $0.index < $1.index }
    }

    private func readValidatedFanValue(_ key: String) -> Float? {
        guard let raw = smc.readFloat(key), raw.isFinite else { return nil }
        if raw < 0 || raw > 20_000 {
            return nil
        }
        return raw
    }

    private func readTemperatures(candidates: [(key: String, label: String)]) -> [ThermalReading] {
        let now = Date()

        if activeTemperatureSensors.isEmpty || now.timeIntervalSince(lastDiscoveryAt) >= discoveryInterval {
            activeTemperatureSensors = discoverTemperatureSensors(candidates: candidates)
            lastDiscoveryAt = now
        }

        var readings: [ThermalReading] = []
        for (key, label) in activeTemperatureSensors {
            if let reading = readTemperatureWithRetry(key: key, label: label, now: now) {
                readings.append(reading)
            }
        }

        return readings
    }

    private func discoverTemperatureSensors(
        candidates: [(key: String, label: String)]
    ) -> [(key: String, label: String)] {
        var sensors: [(key: String, label: String)] = []
        var seenLabels = Set<String>()

        for (key, label) in candidates {
            guard !seenLabels.contains(label) else { continue }
            if readValidTemperature(key: key) != nil {
                sensors.append((key, label))
                seenLabels.insert(label)
            }
        }
        return sensors
    }

    private func readTemperatureWithRetry(key: String, label: String, now: Date) -> ThermalReading? {
        for _ in 0..<temperatureReadRetries {
            if let temp = readValidTemperature(key: key) {
                let reading = ThermalReading(key: key, label: label, temperature: temp)
                cachedTemperatures[key] = reading
                lastTemperatureReadAt[key] = now
                return reading
            }
        }

        if let cached = cachedTemperatures[key],
           let lastSeen = lastTemperatureReadAt[key],
           now.timeIntervalSince(lastSeen) <= staleTTL {
            return cached
        }
        return nil
    }

    private func readValidTemperature(key: String) -> Float? {
        guard let temp = smc.readFloat(key), temp.isFinite else { return nil }
        guard temp > 1, temp < 150 else { return nil }
        return temp
    }
}
