import Foundation
import Darwin

struct SystemIdentity {
    let modelName: String
    let chipName: String
    let modelIdentifier: String

    var headerLine: String {
        if chipName.isEmpty {
            return modelName
        }
        return "\(modelName) \(chipName)"
    }

    static func current() -> SystemIdentity {
        if let profiled = fromSystemProfiler() {
            return profiled
        }

        let identifier = sysctlString("hw.model") ?? "Mac"
        let intelBrand = sysctlString("machdep.cpu.brand_string") ?? ""
        return SystemIdentity(
            modelName: "Mac",
            chipName: intelBrand,
            modelIdentifier: identifier
        )
    }

    private static func fromSystemProfiler() -> SystemIdentity? {
        let output = runCommand(
            launchPath: "/usr/sbin/system_profiler",
            arguments: ["SPHardwareDataType", "-detailLevel", "mini"]
        )
        guard !output.isEmpty else { return nil }

        var modelName = ""
        var chipName = ""
        var modelIdentifier = ""

        for line in output.split(separator: "\n") {
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("Model Name:") {
                modelName = raw.replacingOccurrences(of: "Model Name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if raw.hasPrefix("Chip:") {
                chipName = raw.replacingOccurrences(of: "Chip:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if raw.hasPrefix("Processor Name:") {
                chipName = raw.replacingOccurrences(of: "Processor Name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if raw.hasPrefix("Model Identifier:") {
                modelIdentifier = raw.replacingOccurrences(of: "Model Identifier:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        if modelName.isEmpty && chipName.isEmpty && modelIdentifier.isEmpty {
            return nil
        }

        if modelName.isEmpty {
            modelName = "Mac"
        }

        return SystemIdentity(modelName: modelName, chipName: chipName, modelIdentifier: modelIdentifier)
    }

    private static func runCommand(launchPath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func sysctlString(_ key: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer)
    }
}
