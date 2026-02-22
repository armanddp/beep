import Foundation

// MARK: - ANSI Terminal Codes

enum ANSI {
    static let reset      = "\u{1B}[0m"
    static let bold       = "\u{1B}[1m"
    static let dim        = "\u{1B}[2m"
    static let red        = "\u{1B}[31m"
    static let green      = "\u{1B}[32m"
    static let yellow     = "\u{1B}[33m"
    static let cyan       = "\u{1B}[36m"
    static let white      = "\u{1B}[37m"
    static let bgRed      = "\u{1B}[41m"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let clearScreen = "\u{1B}[2J\u{1B}[H"
    static let moveHome   = "\u{1B}[H"
}

// MARK: - Display

struct Display {

    static func clear() {
        print(ANSI.clearScreen, terminator: "")
    }

    static func render(
        fans: [FanInfo],
        temperatures: [ThermalReading],
        warnings: [String],
        interval: TimeInterval,
        silenced: Bool = false
    ) {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)

        // Header
        print("\(ANSI.bold)\(ANSI.cyan)beep\(ANSI.reset) \(ANSI.dim)Fan & Thermal Monitor\(ANSI.reset)")
        print("\(ANSI.dim)MacBook Pro 14\u{22} M2 Pro  \u{2502}  \(now)\(ANSI.reset)")
        print("\(ANSI.dim)\(String(repeating: "\u{2500}", count: 56))\(ANSI.reset)")
        print()

        // Fans
        if fans.isEmpty {
            print("  \(ANSI.yellow)No fans detected — SMC access may be restricted.\(ANSI.reset)")
            print("  \(ANSI.dim)Try: sudo .build/debug/beep\(ANSI.reset)")
            print()
        } else {
            renderFans(fans)
        }

        // Temperatures
        if !temperatures.isEmpty {
            renderTemperatures(temperatures)
        }

        // Warnings
        if !warnings.isEmpty {
            print()
            for warning in warnings {
                if warning.hasPrefix("CRITICAL") {
                    print("  \(ANSI.bgRed)\(ANSI.bold)\(ANSI.white) \u{26A0}  \(warning) \(ANSI.reset)")
                } else {
                    print("  \(ANSI.yellow)\(ANSI.bold)\u{26A0}  \(warning)\(ANSI.reset)")
                }
            }
        } else if !fans.isEmpty {
            print()
            print("  \(ANSI.green)\u{2713} All fans operating normally\(ANSI.reset)")
        }

        // Footer
        print()
        let intervalStr = interval == 1.0 ? "1s" : String(format: "%.1fs", interval)
        let silenceInfo = silenced ? "  \u{2502}  \(ANSI.yellow)Alerts muted\(ANSI.dim)" : ""
        print("\(ANSI.dim)Ctrl+C to exit  \u{2502}  Refresh: \(intervalStr)\(silenceInfo)\(ANSI.reset)")
    }

    // MARK: - Fan Rendering

    private static func renderFans(_ fans: [FanInfo]) {
        if fans.count >= 2 {
            renderTwoFans(fans[0], fans[1])
            for fan in fans.dropFirst(2) {
                print()
                renderSingleFan(fan)
            }
        } else if let fan = fans.first {
            renderSingleFan(fan)
        }
        print()
    }

    private static func renderTwoFans(_ left: FanInfo, _ right: FanInfo) {
        let colWidth = 28

        print("  \(pad("\(ANSI.bold)\(left.name)\(ANSI.reset)", colWidth))"
            + "\(ANSI.bold)\(right.name)\(ANSI.reset)")

        // Pass each fan's speed as context for the other
        print("  \(pad(formatSpeed(left, otherFanSpeed: right.actualSpeed), colWidth))"
            + formatSpeed(right, otherFanSpeed: left.actualSpeed))

        let lt = left.targetSpeed.flatMap  { $0 > 10 ? String(format: "Target: %.0f RPM", $0) : nil }
        let rt = right.targetSpeed.flatMap { $0 > 10 ? String(format: "Target: %.0f RPM", $0) : nil }
        if lt != nil || rt != nil {
            print("  \(ANSI.dim)\(pad(lt ?? "", colWidth))\(rt ?? "")\(ANSI.reset)")
        }

        let lr = formatRange(left)
        let rr = formatRange(right)
        if !lr.isEmpty || !rr.isEmpty {
            print("  \(ANSI.dim)\(pad(lr, colWidth))\(rr)\(ANSI.reset)")
        }
    }

    private static func renderSingleFan(_ fan: FanInfo) {
        print("  \(ANSI.bold)\(fan.name)\(ANSI.reset)")
        print("  \(formatSpeed(fan))")
        if let t = fan.targetSpeed {
            print("  \(ANSI.dim)Target: \(String(format: "%.0f", t)) RPM\(ANSI.reset)")
        }
    }

    private static func formatSpeed(_ fan: FanInfo, otherFanSpeed: Float? = nil) -> String {
        let speed = abs(fan.actualSpeed) < 1 ? Float(0) : fan.actualSpeed // avoid "-0"
        let rpm = String(format: "%.0f RPM", speed)
        switch fan.healthStatus(otherFanSpeed: otherFanSpeed) {
        case .normal:
            return "\(ANSI.green)\u{25CF} \(rpm)\(ANSI.reset)"
        case .stopped:
            return "\(ANSI.dim)\u{25CB} \(rpm) (idle)\(ANSI.reset)"
        case .stalled:
            return "\(ANSI.red)\(ANSI.bold)\u{2717} \(rpm) \u{2190} STALLED\(ANSI.reset)"
        case .underperforming:
            return "\(ANSI.yellow)\u{25BC} \(rpm) \u{2190} SLOW\(ANSI.reset)"
        }
    }

    private static func formatRange(_ fan: FanInfo) -> String {
        if let mn = fan.minSpeed, let mx = fan.maxSpeed, mx > 100 {
            return String(format: "Range: %.0f\u{2013}%.0f RPM", mn, mx)
        }
        return ""
    }

    // MARK: - Temperature Rendering

    private static func renderTemperatures(_ temps: [ThermalReading]) {
        print("  \(ANSI.bold)Temperatures\(ANSI.reset)")

        let colWidth = 28
        let half = (temps.count + 1) / 2

        for i in 0..<half {
            let left = formatTemp(temps[i])
            if i + half < temps.count {
                let right = formatTemp(temps[i + half])
                print("  \(pad(left, colWidth))\(right)")
            } else {
                print("  \(left)")
            }
        }
    }

    private static func formatTemp(_ reading: ThermalReading) -> String {
        let temp = String(format: "%.1f\u{00B0}C", reading.temperature)
        let color: String
        if reading.isCritical {
            color = ANSI.red + ANSI.bold
        } else if reading.isWarning || reading.temperature > 70 {
            color = ANSI.yellow
        } else {
            color = ""
        }
        let label = reading.label.padding(toLength: 14, withPad: " ", startingAt: 0)
        return "\(ANSI.dim)\(label)\(ANSI.reset) \(color)\(temp)\(ANSI.reset)"
    }

    // MARK: - Helpers

    /// Pad a string to a given visible width, accounting for ANSI escape codes.
    private static func pad(_ str: String, _ width: Int) -> String {
        let visible = str.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
        let padding = max(0, width - visible.count)
        return str + String(repeating: " ", count: padding)
    }
}
