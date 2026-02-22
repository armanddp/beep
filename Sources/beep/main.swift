import Foundation

// MARK: - Argument Parsing

let args = CommandLine.arguments
let runOnce = args.contains("--once")
let dumpKeys = args.contains("--dump")
let silenceAlerts = args.contains("--silence")
let showHelp = args.contains("--help") || args.contains("-h")

let refreshInterval: TimeInterval = {
    if let idx = args.firstIndex(of: "--interval"),
       idx + 1 < args.count,
       let val = TimeInterval(args[idx + 1]) {
        return max(0.5, val)
    }
    return 1.0
}()

if showHelp {
    print("""
    beep — Fan & Thermal Monitor for MacBook Pro

    Usage: beep [options]

    Options:
      --once          Run once and exit (no live updating)
      --interval N    Refresh interval in seconds (default: 1.0)
      --silence       Mute macOS alert sounds while monitoring
                      (restores original volume on exit)
      --dump          Dump all readable SMC keys and exit
      --help, -h      Show this help

    Monitors fan speeds and temperatures via the System Management
    Controller (SMC) to help diagnose cooling issues like stuck fans.

    The --silence flag temporarily sets the macOS alert volume to 0,
    which suppresses thermal warning beeps played through the audio
    system. The original volume is restored when you exit (Ctrl+C).

    Tip: If you see "No fans detected", try running with sudo.
    """)
    exit(0)
}

// MARK: - SMC Connection

let smc: SMCConnection
do {
    smc = try SMCConnection()
} catch {
    fputs("\(ANSI.red)Error: \(error)\(ANSI.reset)\n", stderr)
    fputs("\n", stderr)
    fputs("Could not connect to the SMC. Possible causes:\n", stderr)
    fputs("  1. Run with sudo:  sudo \(args[0])\n", stderr)
    fputs("  2. SIP or security policy is blocking IOKit access\n", stderr)
    exit(1)
}
defer { smc.close() }

// MARK: - Key Dump Mode

if dumpKeys {
    guard let total = smc.keyCount() else {
        print("Could not read key count from SMC.")
        exit(1)
    }
    print("SMC reports \(total) keys. Reading...\n")

    var found = 0
    for i: UInt32 in 0..<UInt32(total) {
        guard let keyName = smc.keyAtIndex(i) else { continue }
        guard let value = try? smc.readKey(keyName) else { continue }

        let typeName = SMCConnection.dataTypeName(value.dataType)
        let floatVal = SMCConnection.parseAsFloat(value)
        let hex = String(format: "%02X %02X %02X %02X",
                         value.bytes.0, value.bytes.1, value.bytes.2, value.bytes.3)

        if floatVal > -200, floatVal < 50_000, !floatVal.isNaN {
            print(String(format: "  %-6s  type=%-4s  size=%d  hex=[%s]  value=%.2f",
                         keyName, typeName, value.dataSize, hex, floatVal))
            found += 1
        }
    }
    print("\nShowed \(found) keys with reasonable float values.")
    exit(0)
}

// MARK: - Alert Silencing

let silencer = AlertSilencer()
if silenceAlerts {
    if silencer.silence() {
        // Restored on exit via cleanup() or deinit
    } else {
        fputs("\(ANSI.yellow)Warning: Could not silence alert sounds.\(ANSI.reset)\n", stderr)
    }
}

func cleanup() {
    silencer.restore()
    print(ANSI.showCursor)
}

// MARK: - Signal Handling (Ctrl+C)

signal(SIGINT) { _ in
    cleanup()
    print("\n\(ANSI.dim)Bye.\(ANSI.reset)")
    exit(0)
}

// MARK: - Main Monitoring Loop

if !runOnce {
    print(ANSI.hideCursor, terminator: "")
}

let monitor = FanMonitor(smc: smc)

repeat {
    let fans = monitor.readAllFans()
    let temps = monitor.readTemperatures()
    let warnings = monitor.detectWarnings(fans: fans)

    if !runOnce {
        Display.clear()
    }
    Display.render(
        fans: fans,
        temperatures: temps,
        warnings: warnings,
        interval: refreshInterval,
        silenced: silencer.isSilenced
    )

    if !runOnce {
        Thread.sleep(forTimeInterval: refreshInterval)
    }
} while !runOnce

cleanup()
