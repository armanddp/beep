import Foundation
import IOKit

// MARK: - SMC Data Structures
//
// These structs mirror the kernel-side SMCParamStruct used by the AppleSMC driver.
// The total size MUST be exactly 80 bytes for IOConnectCallStructMethod to work.

struct SMCKeyData_vers_t {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyData_pLimitData_t {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes_t = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers: SMCKeyData_vers_t = SMCKeyData_vers_t()
    var pLimitData: SMCKeyData_pLimitData_t = SMCKeyData_pLimitData_t()
    var keyInfo: SMCKeyData_keyInfo_t = SMCKeyData_keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                             0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - SMC Constants

private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kKernelIndexSMC: UInt32 = 2

// MARK: - SMC Data Types

enum SMCDataType: UInt32 {
    case flt  = 0x666C7420 // "flt "
    case fpe2 = 0x66706532 // "fpe2"
    case sp78 = 0x73703738 // "sp78"
    case ui8  = 0x75693820 // "ui8 "
    case ui16 = 0x75693136 // "ui16"
    case ui32 = 0x75693332 // "ui32"
    case flag = 0x666C6167 // "flag"
}

// MARK: - SMC Errors

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case couldNotOpenConnection(kern_return_t)
    case keyNotFound(String)
    case readError(kern_return_t)
    case writeError(kern_return_t)
    case writeFailed(String)

    var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found in IOKit registry"
        case .couldNotOpenConnection(let code):
            return "Could not open SMC connection (error: \(code))"
        case .keyNotFound(let key):
            return "SMC key '\(key)' not found"
        case .readError(let code):
            return "SMC read failed (error: \(code))"
        case .writeError(let code):
            return "SMC write failed (error: \(code))"
        case .writeFailed(let msg):
            return "SMC write failed: \(msg)"
        }
    }
}

// MARK: - SMC Value

struct SMCValue {
    var dataType: UInt32
    var dataSize: UInt32
    var bytes: SMCBytes_t
}

// MARK: - SMC Connection

class SMCConnection {
    private var connection: io_connect_t = 0

    init() throws {
        // Verify struct layout at initialization
        let size = MemoryLayout<SMCKeyData_t>.size
        guard size == 80 else {
            fatalError("SMCKeyData_t is \(size) bytes, expected 80. Struct layout mismatch.")
        }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else {
            throw SMCError.serviceNotFound
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        guard result == kIOReturnSuccess else {
            throw SMCError.couldNotOpenConnection(result)
        }
    }

    deinit {
        close()
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    // MARK: - Key Reading

    func readKey(_ key: String) throws -> SMCValue {
        // Step 1: Get key info (data size, type)
        var input = SMCKeyData_t()
        input.key = Self.fourCharCode(key)
        input.data8 = kSMCGetKeyInfo

        var output = SMCKeyData_t()
        try callSMC(input: &input, output: &output)

        // Step 2: Read the actual value
        input.keyInfo = output.keyInfo
        input.data8 = kSMCReadKey

        output = SMCKeyData_t()
        try callSMC(input: &input, output: &output)

        return SMCValue(
            dataType: input.keyInfo.dataType,
            dataSize: input.keyInfo.dataSize,
            bytes: output.bytes
        )
    }

    /// Read a key and parse it as a floating-point value. Returns nil if the key doesn't exist.
    func readFloat(_ key: String) -> Float? {
        guard let value = try? readKey(key) else { return nil }
        return Self.parseAsFloat(value)
    }

    /// Read a key and return the first byte as UInt8. Returns nil if the key doesn't exist.
    func readUInt8(_ key: String) -> UInt8? {
        guard let value = try? readKey(key) else { return nil }
        return value.bytes.0
    }

    // MARK: - Key Writing

    /// Write a value to an SMC key. This is more risky than reading — use with caution.
    func writeKey(_ key: String, value: UInt8) throws {
        // Step 1: Get key info to know the data type and size
        var input = SMCKeyData_t()
        input.key = Self.fourCharCode(key)
        input.data8 = kSMCGetKeyInfo

        var output = SMCKeyData_t()
        try callSMC(input: &input, output: &output)

        // Step 2: Verify it's a ui8 type (safe to write a single byte)
        guard SMCDataType(rawValue: output.keyInfo.dataType) == .ui8 else {
            throw SMCError.writeFailed("Key '\(key)' is not ui8 type (type: \(Self.dataTypeName(output.keyInfo.dataType)))")
        }

        // Step 3: Write the value
        input.keyInfo = output.keyInfo
        input.data8 = kSMCWriteKey
        input.bytes.0 = value

        output = SMCKeyData_t()
        try callSMC(input: &input, output: &output)
    }

    // MARK: - Value Parsing

    static func parseAsFloat(_ value: SMCValue) -> Float {
        switch SMCDataType(rawValue: value.dataType) {
        case .flt:
            // IEEE 754 float. SMC stores in big-endian byte order.
            let bits = UInt32(value.bytes.0) << 24
                     | UInt32(value.bytes.1) << 16
                     | UInt32(value.bytes.2) << 8
                     | UInt32(value.bytes.3)
            let bigEndian = Float(bitPattern: bits)

            // On some Apple Silicon firmware, SMC may use native (little-endian) order.
            // If the big-endian interpretation is unreasonable, try native order.
            if bigEndian < -200 || bigEndian > 50_000 || bigEndian.isNaN {
                var nativeBytes = [value.bytes.0, value.bytes.1, value.bytes.2, value.bytes.3]
                var native: Float = 0
                memcpy(&native, &nativeBytes, 4)
                if !native.isNaN && native >= -200 && native <= 50_000 {
                    return native
                }
            }
            return bigEndian

        case .fpe2:
            // Fixed-point 14.2 (big-endian): value = raw / 4.0
            let raw = (UInt16(value.bytes.0) << 8) | UInt16(value.bytes.1)
            return Float(raw) / 4.0

        case .sp78:
            // Signed fixed-point 8.8 (big-endian): value = raw / 256.0
            let raw = Int16(bitPattern: (UInt16(value.bytes.0) << 8) | UInt16(value.bytes.1))
            return Float(raw) / 256.0

        case .ui8:
            return Float(value.bytes.0)

        case .ui16:
            let raw = (UInt16(value.bytes.0) << 8) | UInt16(value.bytes.1)
            return Float(raw)

        case .ui32:
            let raw = (UInt32(value.bytes.0) << 24) | (UInt32(value.bytes.1) << 16)
                    | (UInt32(value.bytes.2) << 8) | UInt32(value.bytes.3)
            return Float(raw)

        case .flag:
            return Float(value.bytes.0)

        default:
            // Unknown type — try interpreting as big-endian float
            let bits = UInt32(value.bytes.0) << 24
                     | UInt32(value.bytes.1) << 16
                     | UInt32(value.bytes.2) << 8
                     | UInt32(value.bytes.3)
            return Float(bitPattern: bits)
        }
    }

    static func dataTypeName(_ type: UInt32) -> String {
        fourCharCodeToString(type)
    }

    // MARK: - Key Enumeration

    /// Returns the total number of SMC keys available.
    func keyCount() -> Int? {
        guard let value = try? readKey("#KEY") else { return nil }
        let count = (UInt32(value.bytes.0) << 24) | (UInt32(value.bytes.1) << 16)
                  | (UInt32(value.bytes.2) << 8) | UInt32(value.bytes.3)
        return Int(count)
    }

    /// Returns the SMC key at the given index (0-based).
    func keyAtIndex(_ index: UInt32) -> String? {
        var input = SMCKeyData_t()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = index

        var output = SMCKeyData_t()
        guard (try? callSMC(input: &input, output: &output)) != nil else { return nil }

        return Self.fourCharCodeToString(output.key)
    }

    // MARK: - Helpers

    private func callSMC(input: inout SMCKeyData_t, output: inout SMCKeyData_t) throws {
        var outputSize = MemoryLayout<SMCKeyData_t>.size
        let result = IOConnectCallStructMethod(
            connection,
            kKernelIndexSMC,
            &input,
            MemoryLayout<SMCKeyData_t>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else {
            throw SMCError.readError(result)
        }
    }

    static func fourCharCode(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    static func fourCharCodeToString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
