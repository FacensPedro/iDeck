

#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). The sign-in
// errors are the ones sign-in raises; the connection, library and download
// errors belong to the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Errors raised by the Steam sign-in, library and download code.
enum SteamError: LocalizedError, Equatable {
    /// Logon EResults that mean the stored sign-in token itself is unusable:
    /// InvalidPassword, AccessDenied, AccountNotFound, Revoked, Expired,
    /// InvalidSignature.
    static let signInExpiredCodes: Set<UInt32> = [5, 15, 18, 26, 27, 94]

    // Sign-in
    case authenticationFailed(String)
    case invalidCredentials
    case rateLimited
    case accountDisabled
    case rsaKeyFetchFailed
    case qrCodeExpired
    case authSessionExpired
    case protobufError(String)

    // Connection
    case noServersAvailable
    case connectionFailed(String)
    case connectionTimeout
    case disconnected
    /// The CM refused the logon with this EResult. Lets callers tell a revoked
    /// or expired sign-in from a transient network failure.
    case logonDenied(UInt32)
    case invalidMessage

    // Library
    case appInfoNotFound(UInt32)
    case depotNotFound(UInt32)

    // Content
    case manifestFetchFailed(String)
    case chunkDownloadFailed(String)
    case decryptionFailed(String)
    case decompressionFailed
    /// A downloaded chunk could not be decoded; the value names the encoding
    /// (vzip, vzstd, zip) or its leading bytes.
    case chunkDecodeFailed(String)
    case checksumMismatch
    case depotKeyNotFound(UInt32)
    case insufficientDiskSpace(needed: UInt64, available: UInt64)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            return reason
        case .invalidCredentials:
            return "The account name or password is incorrect."
        case .rateLimited:
            return "Too many attempts. Please try again later."
        case .accountDisabled:
            return "This Steam account has been disabled"
        case .rsaKeyFetchFailed:
            return "Failed to fetch RSA public key for password encryption"
        case .qrCodeExpired:
            return "QR code has expired. Please try again."
        case .authSessionExpired:
            return "The sign-in request expired. Start again."
        case .protobufError(let detail):
            return "Protocol buffer error: \(detail)"
        case .noServersAvailable:
            return "No Steam servers are available."
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .connectionTimeout:
            return "Steam did not respond in time. Check your internet connection and try again."
        case .disconnected:
            return "Disconnected from Steam."
        case .logonDenied(let code):
            return SteamError.signInExpiredCodes.contains(code)
                ? "Your Steam sign-in is no longer valid. Sign in again."
                : "Steam refused the connection (code \(code)). Try again later."
        case .invalidMessage:
            return "Received an invalid message from Steam."
        case .appInfoNotFound(let appID):
            return "Steam has no information for app \(appID)."
        case .depotNotFound:
            return "Steam has no Windows download for this game."
        case .manifestFetchFailed(let reason):
            return "Could not read the game's file list: \(reason)"
        case .chunkDownloadFailed(let reason):
            return "Download failed: \(reason)"
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        case .decompressionFailed:
            return "Failed to decompress downloaded data."
        case .chunkDecodeFailed(let format):
            return "Part of the game could not be decoded (\(format)). Try again; downloaded parts are kept."
        case .checksumMismatch:
            return "A downloaded part failed its checksum."
        case .depotKeyNotFound:
            return "Steam did not allow this account to download the game's files. Check that the account owns it."
        case .insufficientDiskSpace(let needed, let available):
            return String(format: "Not enough free space: the download needs %.1f GB and %.1f GB is available.",
                          Double(needed) / 1_000_000_000, Double(available) / 1_000_000_000)
        }
    }
}

/// Where a Steam Guard code comes from.
enum SteamGuardType: String, Codable {
    case email = "email"
    case device = "device"          // Steam Mobile Authenticator
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). The protobuf
// helpers and the IAuthenticationService messages are what sign-in uses; the
// CM logon, license, product-info (PICS), depot-key and service-call messages
// were added for the owned library and downloads (docs/STEAM_LIBRARY.md).
// Field numbers are Valve's, from its public protocol definitions.

import Foundation

// MARK: - Steam Protobuf Message Stubs
//
// These are hand-written Swift structs that mirror the essential Steam protobuf messages.
// They implement manual protobuf encoding/decoding (field tag + wire type + value)
// without requiring the swift-protobuf dependency.
//
// Wire types: 0=varint, 1=64-bit, 2=length-delimited, 5=32-bit

// MARK: - Protobuf Encoding Helpers

enum ProtoWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct ProtobufEncoder {
    private(set) var data = Data()

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func writeTag(fieldNumber: UInt32, wireType: ProtoWireType) {
        writeVarint(UInt64(fieldNumber << 3 | UInt32(wireType.rawValue)))
    }

    mutating func writeString(fieldNumber: UInt32, value: String) {
        guard !value.isEmpty else { return }
        let bytes = Data(value.utf8)
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeBytes(fieldNumber: UInt32, value: Data) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeUInt32(fieldNumber: UInt32, value: UInt32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeUInt64(fieldNumber: UInt32, value: UInt64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeInt32(fieldNumber: UInt32, value: Int32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    /// Write an int32 field unconditionally, even when value is 0.
    mutating func writeInt32Always(fieldNumber: UInt32, value: Int32) {
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func writeInt64(fieldNumber: UInt32, value: Int64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: value))
    }

    mutating func writeBool(fieldNumber: UInt32, value: Bool) {
        guard value else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(1)
    }

    mutating func writeFixed32(fieldNumber: UInt32, value: UInt32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .fixed32)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    mutating func writeFixed64(fieldNumber: UInt32, value: UInt64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .fixed64)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    /// Write a fixed64 field unconditionally, even when value is 0.
    /// The message header's steamid must always be present.
    mutating func writeFixed64Always(fieldNumber: UInt32, value: UInt64) {
        writeTag(fieldNumber: fieldNumber, wireType: .fixed64)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    mutating func writeSubmessage(fieldNumber: UInt32, value: Data) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }
}

struct ProtobufDecoder {
    let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw SteamError.protobufError("Varint too long")
            }
        }
        throw SteamError.protobufError("Unexpected end of data reading varint")
    }

    mutating func readTag() throws -> (fieldNumber: UInt32, wireType: ProtoWireType)? {
        guard !isAtEnd else { return nil }
        let tag = try readVarint()
        let wireTypeRaw = UInt8(tag & 0x7)
        guard let wireType = ProtoWireType(rawValue: wireTypeRaw) else {
            throw SteamError.protobufError("Unknown wire type: \(wireTypeRaw)")
        }
        return (fieldNumber: UInt32(tag >> 3), wireType: wireType)
    }

    /// A length prefix, checked against the bytes that remain. Lengths come
    /// from the network, so an oversized value must throw, not trap.
    mutating func readLength() throws -> Int {
        let length = try readVarint()
        guard length <= UInt64(data.count - offset) else {
            throw SteamError.protobufError("Length past end of data")
        }
        return Int(length)
    }

    mutating func readBytes() throws -> Data {
        let length = try readLength()
        guard offset + length <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading bytes")
        }
        let bytes = data[offset..<offset + length]
        offset += length
        return Data(bytes)
    }

    mutating func readString() throws -> String {
        let bytes = try readBytes()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw SteamError.protobufError("Invalid UTF-8 string")
        }
        return str
    }

    mutating func readFixed32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading fixed32")
        }
        let value = data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading fixed64")
        }
        let value = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func skip(wireType: ProtoWireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            offset += 8
        case .lengthDelimited:
            offset += try readLength()
        case .fixed32:
            offset += 4
        }
        guard offset <= data.count else {
            throw SteamError.protobufError("Skip went past end of data")
        }
    }
}

// MARK: - CMsgProtoBufHeader

/// Header included with every protobuf-encoded Steam message
struct CMsgProtoBufHeader {
    var steamid: UInt64 = 0
    var clientSessionid: Int32 = 0
    var jobidSource: UInt64 = UInt64.max
    var jobidTarget: UInt64 = UInt64.max
    var targetJobName: String = ""
    var eresult: Int32 = 0

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Always write steamid and client_sessionid — CM servers silently drop
        // messages with an empty protobuf header (all fields at default = nothing on wire).
        encoder.writeFixed64Always(fieldNumber: 1, value: steamid)
        encoder.writeInt32Always(fieldNumber: 2, value: clientSessionid)
        // Field numbers from Valve's steammessages_base.proto:
        // jobid_source=10, jobid_target=11, target_job_name=12, eresult=13
        if jobidSource != UInt64.max {
            encoder.writeFixed64(fieldNumber: 10, value: jobidSource)
        }
        if jobidTarget != UInt64.max {
            encoder.writeFixed64(fieldNumber: 11, value: jobidTarget)
        }
        encoder.writeString(fieldNumber: 12, value: targetJobName)
        encoder.writeInt32(fieldNumber: 13, value: eresult)
        return encoder.data
    }

    static func deserialize(from data: Data) throws -> CMsgProtoBufHeader {
        var decoder = ProtobufDecoder(data)
        var header = CMsgProtoBufHeader()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: header.steamid = try decoder.readFixed64()
            case 2: header.clientSessionid = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 10: header.jobidSource = try decoder.readFixed64()
            case 11: header.jobidTarget = try decoder.readFixed64()
            case 12: header.targetJobName = try decoder.readString()
            case 13: header.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }

        return header
    }
}

// MARK: - Authentication Messages

/// Request RSA public key for password encryption
struct CAuthentication_GetPasswordRSAPublicKey_Request {
    var accountName: String = ""

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: accountName)
        return encoder.data
    }
}

struct CAuthentication_GetPasswordRSAPublicKey_Response {
    var publicKeyMod: String = ""
    var publicKeyExp: String = ""
    var timestamp: UInt64 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.publicKeyMod = try decoder.readString()
            case 2: msg.publicKeyExp = try decoder.readString()
            case 3: msg.timestamp = try decoder.readVarint()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Begin credential-based auth session
struct CAuthentication_BeginAuthSessionViaCredentials_Request {
    var accountName: String = ""
    var encryptedPassword: String = ""  // Base64 encoded RSA-encrypted password
    var encryptionTimestamp: UInt64 = 0
    var platformType: UInt32 = 1       // k_EAuthTokenPlatformType_SteamClient = 1
    var persistence: UInt32 = 1        // k_ESessionPersistence_Persistent = 1
    var deviceFriendlyName: String = ""
    var websiteId: String = "Client"

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Field numbers from steammessages_auth.steamclient.proto:
        //   1 device_friendly_name, 2 account_name, 3 encrypted_password,
        //   4 encryption_timestamp, 6 platform_type, 7 persistence,
        //   8 website_id, 9 device_details.
        // An earlier version of this port sent the account name as field 1 and the
        // encrypted password as field 2, so Steam read the password blob as the
        // account name and every typed sign-in failed with InvalidPassword /
        // AccountNotFound ("account name or password is incorrect").
        encoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        encoder.writeString(fieldNumber: 2, value: accountName)
        encoder.writeString(fieldNumber: 3, value: encryptedPassword)
        encoder.writeUInt64(fieldNumber: 4, value: encryptionTimestamp)
        encoder.writeUInt32(fieldNumber: 6, value: platformType)
        encoder.writeUInt32(fieldNumber: 7, value: persistence)
        encoder.writeString(fieldNumber: 8, value: websiteId)
        // CAuthentication_DeviceDetails: 1 device_friendly_name, 2 platform_type.
        var deviceEncoder = ProtobufEncoder()
        deviceEncoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        deviceEncoder.writeUInt32(fieldNumber: 2, value: platformType)
        encoder.writeSubmessage(fieldNumber: 9, value: deviceEncoder.data)
        return encoder.data
    }
}

struct CAuthentication_BeginAuthSessionViaCredentials_Response {
    var clientID: UInt64 = 0
    var requestID: Data = Data()
    var interval: Float = 5.0
    var allowedConfirmations: [AllowedConfirmation] = []
    var steamid: UInt64 = 0

    struct AllowedConfirmation {
        var confirmationType: UInt32 = 0  // k_EAuthSessionGuardType
        var associatedMessage: String = ""
    }

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.clientID = try decoder.readVarint()
            case 2: msg.requestID = try decoder.readBytes()
            case 3:
                let bits = UInt32(try decoder.readFixed32())
                msg.interval = Float(bitPattern: bits)
            case 4:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var confirmation = AllowedConfirmation()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: confirmation.confirmationType = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: confirmation.associatedMessage = try subDecoder.readString()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.allowedConfirmations.append(confirmation)
            // steamid: accept either encoding rather than trust one.
            case 5: msg.steamid = try (tag.wireType == .fixed64 ? decoder.readFixed64() : decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Begin QR auth session
struct CAuthentication_BeginAuthSessionViaQR_Request {
    var deviceFriendlyName: String = ""
    var platformType: UInt32 = 1

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        encoder.writeUInt32(fieldNumber: 2, value: platformType)
        return encoder.data
    }
}

struct CAuthentication_BeginAuthSessionViaQR_Response {
    var clientID: UInt64 = 0
    var challengeURL: String = ""
    var requestID: Data = Data()
    var interval: Float = 5.0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.clientID = try decoder.readVarint()
            case 2: msg.challengeURL = try decoder.readString()
            case 3: msg.requestID = try decoder.readBytes()
            case 4:
                let bits = try decoder.readFixed32()
                msg.interval = Float(bitPattern: bits)
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Update auth session with Steam Guard code
struct CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request {
    var clientID: UInt64 = 0
    var steamid: UInt64 = 0
    var code: String = ""
    var codeType: UInt32 = 0  // k_EAuthSessionGuardType

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt64(fieldNumber: 1, value: clientID)
        encoder.writeFixed64(fieldNumber: 2, value: steamid)   // fixed64 steamid = 2 in the proto
        encoder.writeString(fieldNumber: 3, value: code)
        encoder.writeUInt32(fieldNumber: 4, value: codeType)
        return encoder.data
    }
}

/// Poll for auth session status
struct CAuthentication_PollAuthSessionStatus_Request {
    var clientID: UInt64 = 0
    var requestID: Data = Data()

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt64(fieldNumber: 1, value: clientID)
        encoder.writeBytes(fieldNumber: 2, value: requestID)
        return encoder.data
    }
}

struct CAuthentication_PollAuthSessionStatus_Response {
    var newClientID: UInt64 = 0
    var newChallengeURL: String = ""
    var refreshToken: String = ""
    var accessToken: String = ""
    var hadRemoteInteraction: Bool = false
    var accountName: String = ""
    var newGuardData: String = ""

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.newClientID = try decoder.readVarint()
            case 2: msg.newChallengeURL = try decoder.readString()
            case 3: msg.refreshToken = try decoder.readString()
            case 4: msg.accessToken = try decoder.readString()
            case 5: msg.hadRemoteInteraction = try decoder.readVarint() != 0
            case 6: msg.accountName = try decoder.readString()
            case 7: msg.newGuardData = try decoder.readString()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Client Hello

/// Sent immediately after WebSocket connection to initiate the Steam3 handshake.
/// Without this, the CM server will reject messages and close the connection.
struct CMsgClientHello {
    var protocolVersion: UInt32 = 65580

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: protocolVersion)
        return encoder.data
    }
}

// MARK: - Client Login Messages

/// Client logon request
struct CMsgClientLogon {
    var accountName: String = ""
    var accessToken: String = ""
    var protocolVersion: UInt32 = 65580
    var cellID: UInt32 = 0
    var clientOSType: Int32 = -102  // MacOS
    var clientLanguage: String = "english"
    var shouldRememberPassword: Bool = true
    var machineName: String = ""
    var machineID: Data = Data()
    var supportsRateLimitResponse: Bool = true
    var clientPackageVersion: UInt32 = 1771

    /// Get the machine's primary IPv4 address in host byte order (for obfuscation).
    /// getifaddrs works on both macOS and iOS — Host.current() doesn't exist on iOS.
    private static func getLocalIPv4() -> UInt32 {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return 0 }
        defer { freeifaddrs(addrList) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return UInt32(bigEndian: raw)  // same byte order as a<<24|b<<16|c<<8|d
        }
        return 0
    }

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Field numbers from Valve's steammessages_clientserver_login.proto
        encoder.writeUInt32(fieldNumber: 1, value: protocolVersion)             // protocol_version = 1
        // obfuscated_private_ip (field 11) — CMsgIPAddress sub-message with local IPv4 XOR'd with mask.
        // Valve's own client always sends this; without it some CM servers silently ignore the logon.
        // NOTE: field 2 is deprecated_obfustucated_private_ip (uint32), field 11 is the correct CMsgIPAddress.
        let localIP = CMsgClientLogon.getLocalIPv4()
        let obfuscatedIP = localIP ^ 0xBAADF00D
        var ipEncoder = ProtobufEncoder()
        ipEncoder.writeFixed32(fieldNumber: 1, value: obfuscatedIP)
        encoder.writeSubmessage(fieldNumber: 11, value: ipEncoder.data)         // obfuscated_private_ip = 11
        if cellID != 0 {
            encoder.writeUInt32(fieldNumber: 3, value: cellID)                  // cell_id = 3
        }
        encoder.writeUInt32(fieldNumber: 5, value: clientPackageVersion)        // client_package_version = 5
        encoder.writeString(fieldNumber: 6, value: clientLanguage)              // client_language = 6
        // client_os_type = 7 (uint32 in proto; Steam uses negative values for macOS e.g. -102)
        encoder.writeUInt32(fieldNumber: 7, value: UInt32(bitPattern: clientOSType)) // client_os_type = 7
        encoder.writeBool(fieldNumber: 8, value: shouldRememberPassword)        // should_remember_password = 8
        encoder.writeBytes(fieldNumber: 30, value: machineID)                   // machine_id = 30
        encoder.writeString(fieldNumber: 50, value: accountName)                // account_name = 50
        encoder.writeString(fieldNumber: 96, value: machineName)                // machine_name = 96
        encoder.writeBool(fieldNumber: 102, value: supportsRateLimitResponse)   // supports_rate_limit_response = 102
        encoder.writeString(fieldNumber: 108, value: accessToken)               // access_token = 108
        return encoder.data
    }
}

/// Client logon response
struct CMsgClientLogonResponse {
    var eresult: Int32 = 0
    var heartbeatSeconds: Int32 = 0
    var clientSuppliedSteamID: UInt64 = 0
    var vanityURL: String = ""
    var cellID: UInt32 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())       // eresult = 1
            case 3: msg.heartbeatSeconds = Int32(truncatingIfNeeded: try decoder.readVarint()) // heartbeat_seconds = 3
            case 7: msg.cellID = UInt32(truncatingIfNeeded: try decoder.readVarint())                           // cell_id = 7
            case 14: msg.vanityURL = try decoder.readString()                               // vanity_url = 14
            case 20: msg.clientSuppliedSteamID = try decoder.readFixed64()                  // client_supplied_steamid = 20
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - License / Ownership Messages

struct CMsgClientLicenseList {
    struct License {
        var packageID: UInt32 = 0
        var timeCreated: UInt32 = 0
        var timeNextProcess: UInt32 = 0
        var minuteLimit: Int32 = 0
        var minutesUsed: Int32 = 0
        var paymentMethod: UInt32 = 0
        var flags: UInt32 = 0
        var purchaseCountryCode: String = ""
        var licenseType: UInt32 = 0
        var territoryCode: Int32 = 0
        var ownerID: UInt32 = 0
    }

    var eresult: Int32 = 0
    var licenses: [License] = []

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 2:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var license = License()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: license.packageID = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: license.timeCreated = try subDecoder.readFixed32()      // fixed32 on the wire, not varint
                    case 3: license.timeNextProcess = try subDecoder.readFixed32()  // fixed32 on the wire, not varint
                    case 4: license.minuteLimit = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 5: license.minutesUsed = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 6: license.paymentMethod = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 7: license.flags = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 8: license.purchaseCountryCode = try subDecoder.readString()
                    case 9: license.licenseType = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 10: license.territoryCode = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 14: license.ownerID = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.licenses.append(license)
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - PICS Messages

struct CMsgClientPICSProductInfoRequest {
    struct AppInfo {
        var appid: UInt32 = 0
        var accessToken: UInt64 = 0
    }
    struct PackageInfo {
        var packageid: UInt32 = 0
        var accessToken: UInt64 = 0
    }

    var apps: [AppInfo] = []
    var packages: [PackageInfo] = []
    var metaDataOnly: Bool = false

    func serialize() -> Data {
        // Field numbers per steammessages_clientserver_appinfo.proto:
        // packages = 1, apps = 2; access_token is uint64 (varint).
        var encoder = ProtobufEncoder()
        for pkg in packages {
            var subEncoder = ProtobufEncoder()
            subEncoder.writeUInt32(fieldNumber: 1, value: pkg.packageid)
            subEncoder.writeUInt64(fieldNumber: 2, value: pkg.accessToken)
            encoder.writeSubmessage(fieldNumber: 1, value: subEncoder.data)
        }
        for app in apps {
            var subEncoder = ProtobufEncoder()
            subEncoder.writeUInt32(fieldNumber: 1, value: app.appid)
            subEncoder.writeUInt64(fieldNumber: 2, value: app.accessToken)
            encoder.writeSubmessage(fieldNumber: 2, value: subEncoder.data)
        }
        encoder.writeBool(fieldNumber: 3, value: metaDataOnly)
        return encoder.data
    }
}

struct CMsgClientPICSProductInfoResponse {
    struct AppInfo {
        var appid: UInt32 = 0
        var changeNumber: UInt32 = 0
        /// Field 3, set when the request lacked a valid access token.
        var missingToken = false
        var buffer: Data = Data()  // VDF binary format app info
    }
    struct PackageInfo {
        var packageid: UInt32 = 0
        var changeNumber: UInt32 = 0
        var buffer: Data = Data()
    }

    var apps: [AppInfo] = []
    var packages: [PackageInfo] = []
    var unknownApps: [UInt32] = []
    var unknownPackages: [UInt32] = []
    // Field 6: how many more PICSProductInfoResponse messages are coming for this job.
    // When 0, all parts have been received.
    var pendingResponseCount: Int32 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var app = AppInfo()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: app.appid = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: app.changeNumber = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 3 where subTag.wireType == .varint: app.missingToken = try subDecoder.readVarint() != 0
                    case 5: app.buffer = try subDecoder.readBytes()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.apps.append(app)
            case 2: msg.unknownApps.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 3:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var pkg = PackageInfo()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: pkg.packageid = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: pkg.changeNumber = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 5: pkg.buffer = try subDecoder.readBytes()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.packages.append(pkg)
            case 4: msg.unknownPackages.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 6: msg.pendingResponseCount = Int32(truncatingIfNeeded: try decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Depot Messages

struct CMsgClientGetDepotDecryptionKey {
    var depotID: UInt32 = 0
    var appID: UInt32 = 0

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: depotID)
        encoder.writeUInt32(fieldNumber: 2, value: appID)
        return encoder.data
    }
}

struct CMsgClientGetDepotDecryptionKeyResponse {
    var eresult: Int32 = 0
    var depotID: UInt32 = 0
    var depotEncryptionKey: Data = Data()

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 2: msg.depotID = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 3: msg.depotEncryptionKey = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Service Method Wrapper

/// Wraps a service method call for sending via EMsg.serviceMethodCallFromClient
struct CMsgClientServiceMethod {
    var methodName: String = ""
    var serializedMethod: Data = Data()
    var isNotification: Bool = false

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: methodName)
        encoder.writeBytes(fieldNumber: 2, value: serializedMethod)
        encoder.writeBool(fieldNumber: 3, value: isNotification)
        return encoder.data
    }
}

struct CMsgClientServiceMethodResponse {
    var methodName: String = ""
    var serializedMethodResponse: Data = Data()

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.methodName = try decoder.readString()
            case 2: msg.serializedMethodResponse = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Multi Message (for bundled responses)

struct CMsgMulti {
    var sizeUnzipped: UInt32 = 0
    var messageBody: Data = Data()

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.sizeUnzipped = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 2: msg.messageBody = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - PICS Access Token Messages

struct CMsgClientPICSAccessTokenRequest {
    var appids: [UInt32] = []
    var packageids: [UInt32] = []

    func serialize() -> Data {
        // Field numbers per steammessages_clientserver_appinfo.proto:
        // packageids = 1, appids = 2.
        var encoder = ProtobufEncoder()
        for pkgid in packageids {
            encoder.writeUInt32(fieldNumber: 1, value: pkgid)
        }
        for appid in appids {
            encoder.writeUInt32(fieldNumber: 2, value: appid)
        }
        return encoder.data
    }
}

struct CMsgClientPICSAccessTokenResponse {
    struct AppToken {
        var appid: UInt32 = 0
        var accessToken: UInt64 = 0
    }
    struct PackageToken {
        var packageid: UInt32 = 0
        var accessToken: UInt64 = 0
    }

    var appAccessTokens: [AppToken] = []
    var packageAccessTokens: [PackageToken] = []
    var appAccessTokensDenied: [UInt32] = []
    var packageAccessTokensDenied: [UInt32] = []

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        // Field numbers per steammessages_clientserver_appinfo.proto:
        // package_access_tokens = 1, package_denied_tokens = 2,
        // app_access_tokens = 3, app_denied_tokens = 4.
        // access_token is uint64 (varint), not fixed64.
        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1:
                let subData = try decoder.readBytes()
                var sub = ProtobufDecoder(subData)
                var token = PackageToken()
                while let st = try sub.readTag() {
                    switch st.fieldNumber {
                    case 1: token.packageid = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case 2: token.accessToken = try sub.readVarint()
                    default: try sub.skip(wireType: st.wireType)
                    }
                }
                msg.packageAccessTokens.append(token)
            case 2: msg.packageAccessTokensDenied.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 3:
                let subData = try decoder.readBytes()
                var sub = ProtobufDecoder(subData)
                var token = AppToken()
                while let st = try sub.readTag() {
                    switch st.fieldNumber {
                    case 1: token.appid = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case 2: token.accessToken = try sub.readVarint()
                    default: try sub.skip(wireType: st.wireType)
                    }
                }
                msg.appAccessTokens.append(token)
            case 4: msg.appAccessTokensDenied.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// The request construction comes from the per-flow helper in Jfishin's
// Madeira Steam client (used with the author's permission, see
// docs/STEAM_SIGNIN.md, "Provenance"); the shared transport and the
// x-eresult handling are 125hz's.

import Foundation

/// IAuthenticationService over HTTPS (api.steampowered.com), shared by the
/// QR and password flows.
///
/// Steam reports most authentication failures as HTTP 200 with an
/// `x-eresult` header and an empty body. The original port ignored that
/// header, so a wrong password or Steam Guard code turned into an empty
/// session followed by minutes of polling. The header is checked here and
/// mapped to a specific error. Request and response bodies are never logged.
enum SteamAuthAPI {
    static func call(_ method: String, body: Data, httpMethod: String = "POST") async throws -> Data {
        let baseURL = "https://api.steampowered.com/IAuthenticationService/\(method)/v1/"

        // Percent-encode the base64 string. Base64 contains +, /, = — all need encoding
        // whether sent as a form body (POST) or a query parameter (GET).
        let base64 = body.base64EncodedString()
        let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64

        var request: URLRequest
        if httpMethod == "GET" {
            request = URLRequest(url: URL(string: "\(baseURL)?input_protobuf_encoded=\(encoded)")!)
            request.httpMethod = "GET"
        } else {
            request = URLRequest(url: URL(string: baseURL)!)
            request.httpMethod = httpMethod
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "input_protobuf_encoded=\(encoded)".data(using: .utf8)
        }
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SteamError.authenticationFailed("Steam did not respond. Check your internet connection.")
        }
        if http.statusCode == 429 { throw SteamError.rateLimited }
        guard http.statusCode == 200 else {
            throw SteamError.authenticationFailed("Steam sign-in is unavailable right now (HTTP \(http.statusCode)).")
        }
        if let text = http.value(forHTTPHeaderField: "x-eresult"), let code = UInt32(text), code != 1 {
            SteamLog.trace("\(method) eresult=\(code)")
            throw error(for: code)
        }
        return data
    }

    /// EResult values Steam returns from the authentication service.
    static func error(for code: UInt32) -> SteamError {
        switch code {
        case 5, 18: return .invalidCredentials               // InvalidPassword, AccountNotFound
        case 65, 88: return .authenticationFailed("That Steam Guard code is not correct. Try again with a new code.")
        case 84, 87: return .rateLimited                     // RateLimitExceeded, AccountLoginDeniedThrottle
        case 17: return .accountDisabled                     // Banned
        case 9, 27: return .authSessionExpired               // FileNotFound (expired session), Expired
        default: return .authenticationFailed("Steam refused the sign-in (code \(code)).")
        }
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance").

import Foundation
import Security

/// What Steam Guard asks for after the password is accepted.
struct SteamGuardPrompt: Equatable {
    /// A code can be typed: from the Steam mobile app (.device) or email (.email).
    var codeType: SteamGuardType?
    /// The sign-in can also be approved directly in the Steam mobile app or
    /// from a link in email; polling picks that up without a code.
    var canApprove: Bool
    /// Steam's hint for email codes (for example the address domain).
    var hint: String
}

/// Handles account name + password + Steam Guard authentication via the
/// Steam HTTPS Web API. The refresh token it returns is what Valve's own
/// client accepts for a later sign-in (see SteamSignIn.credentialsForDock()).
///
/// Madeira: the flow is split into begin / submit code / poll so the
/// interface can offer a code field and in-app approval at the same time.
/// The original port only looked at the first allowed confirmation, which
/// hid the code option whenever Steam listed app approval first. The password
/// is encrypted with Steam's RSA key before it leaves the device and is not
/// stored.
@MainActor
class SteamCredentialAuth {

    // Auth session state
    private var clientID: UInt64 = 0
    private var requestIDData: Data = Data()
    private var pollInterval: Double = 5.0
    private var steamID: UInt64 = 0
    private(set) var accountName = ""

    // MARK: - Public API

    /// Start a password sign-in. Returns nil when Steam needs no further
    /// confirmation; otherwise the Steam Guard options to present. In both
    /// cases call `pollForTokens()` next.
    func begin(username: String, password: String) async throws -> SteamGuardPrompt? {
        accountName = username

        // Step 1: Get RSA public key for password encryption
        var rsaRequest = CAuthentication_GetPasswordRSAPublicKey_Request()
        rsaRequest.accountName = username

        // GetPasswordRSAPublicKey is the one IAuthenticationService method that requires GET.
        let rsaData = try await SteamAuthAPI.call("GetPasswordRSAPublicKey", body: rsaRequest.serialize(), httpMethod: "GET")
        let rsaResponse = try CAuthentication_GetPasswordRSAPublicKey_Response.deserialize(from: rsaData)

        guard !rsaResponse.publicKeyMod.isEmpty else {
            throw SteamError.invalidCredentials
        }

        // Step 2: Encrypt password with Steam's RSA public key
        let encryptedPassword = try encryptPassword(
            password: password,
            modulus: rsaResponse.publicKeyMod,
            exponent: rsaResponse.publicKeyExp
        )

        // Step 3: Begin auth session
        var beginRequest = CAuthentication_BeginAuthSessionViaCredentials_Request()
        beginRequest.accountName = username
        beginRequest.encryptedPassword = encryptedPassword
        beginRequest.encryptionTimestamp = rsaResponse.timestamp
        beginRequest.deviceFriendlyName = SteamDevice.name
        beginRequest.platformType = 1  // k_EAuthTokenPlatformType_SteamClient: a token the Steam client can use
        beginRequest.persistence = 1   // Persistent session

        let beginData = try await SteamAuthAPI.call("BeginAuthSessionViaCredentials", body: beginRequest.serialize())
        let beginResponse = try CAuthentication_BeginAuthSessionViaCredentials_Response.deserialize(from: beginData)
        guard beginResponse.clientID != 0 else { throw SteamError.invalidCredentials }

        clientID = beginResponse.clientID
        steamID = beginResponse.steamid
        requestIDData = beginResponse.requestID
        pollInterval = Double(beginResponse.interval > 0 ? beginResponse.interval : 5.0)

        // Step 4: Steam Guard. k_EAuthSessionGuardType: 1 none, 2 email code,
        // 3 device code, 4 device confirmation, 5 email confirmation.
        let types = Set(beginResponse.allowedConfirmations.map(\.confirmationType))
        if types.isEmpty || types == [1] { return nil }
        let codeType: SteamGuardType? = types.contains(3) ? .device : (types.contains(2) ? .email : nil)
        let hint = beginResponse.allowedConfirmations.first(where: { $0.confirmationType == 2 }).map(\.associatedMessage) ?? ""
        return SteamGuardPrompt(codeType: codeType, canApprove: types.contains(4) || types.contains(5), hint: hint)
    }

    /// Submit a Steam Guard code. Polling (already running or started next)
    /// then receives the tokens.
    func submitSteamGuardCode(_ code: String, type: SteamGuardType) async throws {
        var updateRequest = CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request()
        updateRequest.clientID = clientID
        updateRequest.steamid = steamID
        updateRequest.code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        updateRequest.codeType = type == .email ? 2 : 3

        _ = try await SteamAuthAPI.call("UpdateAuthSessionWithSteamGuardCode", body: updateRequest.serialize())
    }

    /// Poll until Steam issues tokens (after a code, an in-app approval, or
    /// immediately when no confirmation is needed). Cancel the task to stop.
    func pollForTokens() async throws -> (refreshToken: String, accessToken: String, accountName: String) {
        let deadline = Date().addingTimeInterval(5 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var pollRequest = CAuthentication_PollAuthSessionStatus_Request()
            pollRequest.clientID = clientID
            pollRequest.requestID = requestIDData

            let responseData = try await SteamAuthAPI.call("PollAuthSessionStatus", body: pollRequest.serialize())
            let pollResponse = try CAuthentication_PollAuthSessionStatus_Response.deserialize(from: responseData)

            if pollResponse.newClientID != 0 {
                clientID = pollResponse.newClientID
            }

            if !pollResponse.refreshToken.isEmpty && !pollResponse.accessToken.isEmpty {
                let name = pollResponse.accountName.isEmpty ? accountName : pollResponse.accountName
                return (refreshToken: pollResponse.refreshToken, accessToken: pollResponse.accessToken, accountName: name)
            }

            try await Task.sleep(nanoseconds: UInt64(max(1, pollInterval) * 1_000_000_000))
        }
        throw SteamError.authSessionExpired
    }

    // MARK: - RSA Password Encryption

    private func encryptPassword(password: String, modulus: String, exponent: String) throws -> String {
        guard let modulusData = Data(hexString: modulus),
              let exponentData = Data(hexString: exponent) else {
            throw SteamError.rsaKeyFetchFailed
        }

        let passwordData = Data(password.utf8)
        let keyData = buildRSAPublicKeyDER(modulus: modulusData, exponent: exponentData)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulusData.count * 8,
        ]

        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw SteamError.rsaKeyFetchFailed
        }

        guard let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, passwordData as CFData, &error) else {
            throw SteamError.rsaKeyFetchFailed
        }

        return (encrypted as Data).base64EncodedString()
    }

    private func buildRSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func lengthField(_ length: Int) -> Data {
            if length < 128 {
                return Data([UInt8(length)])
            } else if length < 256 {
                return Data([0x81, UInt8(length)])
            } else {
                return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
            }
        }

        func integerField(_ data: Data) -> Data {
            var bytes = Data([0x02])
            var payload = data
            if let first = payload.first, first & 0x80 != 0 {
                payload.insert(0x00, at: 0)
            }
            bytes.append(contentsOf: lengthField(payload.count))
            bytes.append(payload)
            return bytes
        }

        let modulusField = integerField(modulus)
        let exponentField = integerField(exponent)

        var rsaKeyBody = Data([0x30])
        let bodyLen = modulusField.count + exponentField.count
        rsaKeyBody.append(contentsOf: lengthField(bodyLen))
        rsaKeyBody.append(modulusField)
        rsaKeyBody.append(exponentField)

        return rsaKeyBody
    }
}

// MARK: - Data Hex Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance").

import Foundation
import CoreImage
#if canImport(AppKit)
import AppKit
typealias SteamImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias SteamImage = UIImage
#endif

/// Handles QR code authentication flow with Steam via HTTPS Steam Web API.
/// Auth uses api.steampowered.com directly — no CM WebSocket connection needed for this step.
/// The refresh token it returns is kept in the Keychain by SteamSignInModel.
@MainActor
class SteamQRAuth {

    enum QRAuthState: Equatable {
        case idle
        case generating
        case showingQR(image: SteamImage, url: String)
        case polling
        case success(accountName: String)
        case expired
        case failed(String)
    }

    private(set) var authState: QRAuthState = .idle
    /// Madeira: called when Steam rotates the challenge during polling, so the
    /// interface can replace the displayed code (and its same-device link).
    var onNewChallenge: ((SteamImage, String) -> Void)?

    // Auth session state
    private var clientID: UInt64 = 0
    private var requestIDData: Data = Data()
    private var pollInterval: Double = 5.0

    // MARK: - Public API

    /// Start QR auth: calls Steam HTTPS API, returns QR code image.
    /// Follow with pollForConfirmation() to wait for user to scan.
    func beginQRAuth() async throws -> SteamImage {
        authState = .generating

        var request = CAuthentication_BeginAuthSessionViaQR_Request()
        request.deviceFriendlyName = SteamDevice.name
        request.platformType = 1  // k_EAuthTokenPlatformType_SteamClient: a token the Steam client can use

        let responseData = try await callSteamAuthAPI(method: "BeginAuthSessionViaQR", body: request.serialize())
        let response = try CAuthentication_BeginAuthSessionViaQR_Response.deserialize(from: responseData)

        guard !response.challengeURL.isEmpty else {
            authState = .failed("No challenge URL received")
            throw SteamError.authenticationFailed("Empty challenge URL from Steam")
        }

        clientID = response.clientID
        requestIDData = response.requestID
        pollInterval = Double(response.interval > 0 ? response.interval : 5.0)

        let qrImage = generateQRCode(from: response.challengeURL)
        authState = .showingQR(image: qrImage, url: response.challengeURL)
        return qrImage
    }

    /// Poll Steam HTTPS API until user scans QR. Returns tokens on success.
    func pollForConfirmation() async throws -> (refreshToken: String, accessToken: String, accountName: String) {
        authState = .polling

        let maxAttempts = 120  // ~10 minutes at 5-second intervals
        for _ in 0..<maxAttempts {
            try Task.checkCancellation()
            var pollRequest = CAuthentication_PollAuthSessionStatus_Request()
            pollRequest.clientID = clientID
            pollRequest.requestID = requestIDData

            let responseData = try await callSteamAuthAPI(method: "PollAuthSessionStatus", body: pollRequest.serialize())
            let pollResponse = try CAuthentication_PollAuthSessionStatus_Response.deserialize(from: responseData)

            // Update client ID if it changed (Steam may rotate it)
            if pollResponse.newClientID != 0 {
                clientID = pollResponse.newClientID
            }

            // Update QR image if challenge URL changed
            if !pollResponse.newChallengeURL.isEmpty {
                let newImage = generateQRCode(from: pollResponse.newChallengeURL)
                authState = .showingQR(image: newImage, url: pollResponse.newChallengeURL)
                onNewChallenge?(newImage, pollResponse.newChallengeURL)
            }

            if !pollResponse.refreshToken.isEmpty && !pollResponse.accessToken.isEmpty {
                let accountName = pollResponse.accountName
                authState = .success(accountName: accountName)
                return (refreshToken: pollResponse.refreshToken, accessToken: pollResponse.accessToken, accountName: accountName)
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        authState = .expired
        throw SteamError.qrCodeExpired
    }

    func cancel() {
        authState = .idle
        clientID = 0
        requestIDData = Data()
    }

    // MARK: - HTTPS Steam Auth API

    /// POST to IAuthenticationService HTTPS endpoint.
    /// Steam returns a binary protobuf response when input_protobuf_encoded is used.
    func callSteamAuthAPI(method: String, body: Data) async throws -> Data {
        // Madeira: shared transport; checks Steam's x-eresult header.
        try await SteamAuthAPI.call(method, body: body)
    }

    // MARK: - QR Code Generation

    private func generateQRCode(from string: String) -> SteamImage {
        let data = string.data(using: .ascii)
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        let scale = CGAffineTransform(scaleX: 8, y: 8)
        guard let ciImage = filter.outputImage else {
            #if canImport(AppKit)
            return NSImage(size: NSSize(width: 200, height: 200))
            #else
            return UIImage()
            #endif
        }
        let scaledImage = ciImage.transformed(by: scale)

        #if canImport(AppKit)
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
        #else
        // UIImage(ciImage:) stays CIImage-backed and renders blank in SwiftUI —
        // materialize to a CGImage.
        guard let cg = CIContext().createCGImage(scaledImage, from: scaledImage.extent) else {
            return UIImage()
        }
        return UIImage(cgImage: cg)
        #endif
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance").

import Foundation
import Security

/// Securely stores Steam authentication tokens in the Keychain
class SteamTokenStore {
    private let serviceName = "madeira.steam.tokens"

    struct StoredTokens: Codable {
        var accountName: String
        var refreshToken: String
        var accessToken: String
        var steamID: UInt64
        var savedAt: Date
    }

    // MARK: - Public API

    /// Save tokens to Keychain
    func saveTokens(accountName: String, refreshToken: String, accessToken: String, steamID: UInt64) {
        let tokens = StoredTokens(
            accountName: accountName,
            refreshToken: refreshToken,
            accessToken: accessToken,
            steamID: steamID,
            savedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(tokens) else {
            SteamLog.trace("Failed to encode tokens for storage")
            return
        }

        // Delete existing entry first
        deleteKeychainItem()

        // Add new entry
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "steam_tokens",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            SteamLog.trace("Tokens saved to Keychain")
        } else {
            SteamLog.trace("Failed to save tokens to Keychain: \(status)")
        }
    }

    /// Load tokens from Keychain
    func loadTokens() -> StoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "steam_tokens",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return nil
        }

        return tokens
    }

    /// Clear all stored tokens (sign out)
    func clearTokens() {
        deleteKeychainItem()
        SteamLog.trace("Tokens cleared from Keychain")
    }

    /// Check if we have stored tokens
    var hasTokens: Bool {
        loadTokens() != nil
    }

    // MARK: - Private

    private func deleteKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "steam_tokens"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance").

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Cross-platform device name — `Host.current()` doesn't exist on iOS.
enum SteamDevice {
    static var name: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "SwiftSteam"
        #endif
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Logging for Steam sign-in.
///
/// `event` lines are the always-on, low-volume record ([steam-signin]). They
/// never contain tokens, passwords, Steam Guard codes, account names, Steam
/// IDs or message payloads.
///
/// `trace` lines are protocol-level detail, off by default. Enable with
/// `env.MADEIRA_STEAM_TRACE = 1` in madeira.cfg. They are still written
/// without credentials or payload bytes.
enum SteamLog {
    static let tracing = SteamSignIn.flag("MADEIRA_STEAM_TRACE", default: false)

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        // LogStore, not stderr: stderr is only captured into the log once a
        // Wine session starts, and sign-in happens before one.
        print("[steam-trace] " + message())
    }

    static func event(_ message: String) {
        print(message)
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// The sign-in model is adapted from the account model built around Jfishin's
// Madeira Steam client (used with the author's permission, see
// docs/STEAM_SIGNIN.md, "Provenance"); the public API is 125hz's.

import Foundation
import SwiftUI
import UIKit

/// The public face of Steam sign-in, for other parts of the app (Madeira Dock
/// is the first user). The sign-in token lives only in the iOS Keychain
/// (SteamTokenStore: this device only, available while unlocked).
enum SteamSignIn {
    /// Posted on the main queue after a sign-in is stored or removed.
    static let didChange = Notification.Name("MadeiraSteamSignInDidChange")

    /// `env.NAME` from madeira.cfg, then the process environment. "0" is off.
    static func flag(_ name: String, default fallback: Bool) -> Bool {
        guard let value = nil ?? ProcessInfo.processInfo.environment[name] else {
            return fallback
        }
        return value.trimmingCharacters(in: .whitespaces) != "0"
    }

    /// `env.MADEIRA_STEAM_SIGNIN = 0` hides the sign-in button.
    static var isEnabled: Bool { flag("MADEIRA_STEAM_SIGNIN", default: true) }

    static var isSignedIn: Bool { credentialsForDock() != nil }

    static var accountName: String? { credentialsForDock()?.accountName }

    /// The stored account name and refresh token, or nil when there is no
    /// usable sign-in. A token whose own expiry time has passed counts as
    /// none. Valve still decides whether the token is accepted.
    static func credentialsForDock() -> (accountName: String, refreshToken: String)? {
        guard let tokens = SteamTokenStore().loadTokens() else { return nil }
        return usable(accountName: tokens.accountName, refreshToken: tokens.refreshToken, now: Date())
    }

    static func signOut() {
        SteamTokenStore().clearTokens()
        SteamLog.event("[steam-signin] signed out")
        notifyChange()
    }

    /// Stores a sign-in. Returns false when the Keychain did not keep it.
    static func store(accountName: String, refreshToken: String, accessToken: String) -> Bool {
        let store = SteamTokenStore()
        store.saveTokens(accountName: accountName, refreshToken: refreshToken, accessToken: accessToken, steamID: 0)
        let saved = store.loadTokens()?.refreshToken == refreshToken
        notifyChange()
        return saved
    }

    /// Pure check behind `credentialsForDock()` (host-tested).
    static func usable(accountName: String, refreshToken: String, now: Date) -> (accountName: String, refreshToken: String)? {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !refreshToken.isEmpty else { return nil }
        if let expiry = expiry(of: refreshToken), expiry <= now { return nil }
        return (name, refreshToken)
    }

    /// The `exp` claim of a JWT, when there is one. Anything else is nil: the
    /// token is not validated here, only an expiry it states itself is honoured.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].utf8.count <= 8192 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    // MARK: Messages

    static func message(_ error: Error) -> String {
        if let steam = error as? SteamError, let text = steam.errorDescription { return text }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection. Connect and try again."
            case .timedOut: return "Steam did not respond in time. Try again."
            default: return "A network error occurred (\(url.code.rawValue)). Try again."
            }
        }
        return error.localizedDescription
    }

    /// Short, credential-free reason for the log.
    static func reason(_ error: Error) -> String {
        switch error {
        case SteamError.invalidCredentials: return "credentials"
        case SteamError.rateLimited: return "rate-limited"
        case SteamError.accountDisabled: return "disabled"
        case SteamError.authSessionExpired: return "expired"
        case SteamError.qrCodeExpired: return "qr-expired"
        case SteamError.rsaKeyFetchFailed: return "rsa"
        case SteamError.protobufError: return "protobuf"
        case SteamError.authenticationFailed: return "refused"
        case let url as URLError: return "url-\(url.code.rawValue)"
        default: return String(describing: type(of: error))
        }
    }
}

/// State of the sign-in sheet: password + Steam Guard (code or in-app
/// approval, offered together when Steam allows both) or a QR code.
@MainActor
final class SteamSignInModel: ObservableObject {
    static let shared = SteamSignInModel()

    enum SignInMethod: String { case password, qr }

    @Published private(set) var accountName: String?
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var qrLink: URL?
    @Published private(set) var guardPrompt: SteamGuardPrompt?
    @Published private(set) var signInBusy = false
    @Published var signInError: String?

    private let credentials = SteamCredentialAuth()
    private let qr = SteamQRAuth()
    private var signInTask: Task<Void, Never>?

    var signedIn: Bool { accountName != nil }

    init() { refresh() }

    func refresh() { accountName = SteamSignIn.accountName }

    func beginQR() {
        cancelSignIn()
        signInBusy = true; signInError = nil
        qr.onNewChallenge = { [weak self] image, url in
            self?.qrImage = image; self?.qrLink = URL(string: url)
        }
        signInTask = Task { @MainActor in
            do {
                let image = try await qr.beginQRAuth()
                qrImage = image
                if case .showingQR(_, let url) = qr.authState { qrLink = URL(string: url) }
                signInBusy = false
                let tokens = try await qr.pollForConfirmation()
                finishSignIn(account: tokens.accountName, refresh: tokens.refreshToken, access: tokens.accessToken, method: "qr")
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failSignIn(error, method: "qr") }
            }
        }
    }

    func signIn(account: String, password: String) {
        cancelSignIn()
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else { return }
        signInBusy = true; signInError = nil
        signInTask = Task { @MainActor in
            do {
                let prompt = try await credentials.begin(username: name, password: password)
                guardPrompt = prompt
                signInBusy = prompt == nil
                let tokens = try await credentials.pollForTokens()
                finishSignIn(account: tokens.accountName, refresh: tokens.refreshToken, access: tokens.accessToken, method: "password")
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failSignIn(error, method: "password") }
            }
        }
    }

    /// Submit a Steam Guard code; the running poll receives the tokens.
    func submitGuardCode(_ code: String) {
        guard let type = guardPrompt?.codeType, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        signInBusy = true; signInError = nil
        Task { @MainActor in
            do { try await credentials.submitSteamGuardCode(code, type: type) }
            catch { signInError = SteamSignIn.message(error); signInBusy = false }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel(); signInTask = nil
        qr.cancel(); qr.onNewChallenge = nil
        qrImage = nil; qrLink = nil; guardPrompt = nil; signInBusy = false
    }

    func signOut() {
        cancelSignIn()
        SteamSignIn.signOut()
        refresh()
    }

    private func failSignIn(_ error: Error, method: String) {
        signInError = SteamSignIn.message(error)
        signInBusy = false; guardPrompt = nil; qrImage = nil; qrLink = nil
        SteamLog.event("[steam-signin] sign-in failed method=\(method) reason=\(SteamSignIn.reason(error))")
    }

    private func finishSignIn(account: String, refresh: String, access: String, method: String) {
        // This runs inside the sign-in task: clear its state without cancelling it.
        signInTask = nil; qr.onNewChallenge = nil
        qrImage = nil; qrLink = nil; guardPrompt = nil; signInBusy = false
        guard SteamSignIn.store(accountName: account, refreshToken: refresh, accessToken: access) else {
            signInError = "Steam accepted the sign-in, but Madeira could not save it in this device's Keychain. Check the app's signing and try again."
            SteamLog.event("[steam-signin] sign-in keychain-store failed method=\(method)")
            return
        }
        signInError = nil
        self.refresh()
        SteamLog.event("[steam-signin] signed in method=\(method)")
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

/// Steam sign-in sheet: account name + password with Steam Guard (a code and
/// in-app approval, offered together when Steam allows both), or a QR code
/// scanned with the Steam app (default on iPad). When signed in it shows the
/// account and Sign out.
struct SteamSignInView: View {
    @ObservedObject private var steam = SteamSignInModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var method: SteamSignInModel.SignInMethod = UIDevice.current.userInterfaceIdiom == .pad ? .qr : .password
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    private enum Field { case account, password, code }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Sign in to Steam", systemImage: "person.crop.circle.fill").font(.title2.bold())
                        Text("Madeira keeps a Steam sign-in so it can start your Steam games with your own account.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if let name = steam.accountName {
                    signedInSection(name)
                } else if let prompt = steam.guardPrompt {
                    guardSection(prompt)
                } else {
                    Section {
                        Picker("Sign-in method", selection: $method) {
                            Text("Password").tag(SteamSignInModel.SignInMethod.password)
                            Text("QR code").tag(SteamSignInModel.SignInMethod.qr)
                        }.pickerStyle(.segmented)
                    }
                    if method == .password { passwordSection } else { qrSection }
                }
                if let error = steam.signInError {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Text("Madeira signs in with Steam directly. Your password is sent only to Steam and is never stored. A sign-in token is kept in this device's Keychain until you sign out.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Steam").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(steam.signedIn ? "Done" : "Cancel") { steam.cancelSignIn(); dismiss() }
                }
            }
            .onAppear {
                steam.refresh(); steam.signInError = nil
                guard !steam.signedIn else { return }
                if method == .qr { steam.beginQR() } else { focus = .account }
            }
            .onChange(of: method) { _, value in
                steam.signInError = nil
                guard !steam.signedIn else { return }
                if value == .qr { steam.beginQR() } else { steam.cancelSignIn(); focus = .account }
            }
            .onChange(of: steam.accountName) { _, name in if name != nil { dismiss() } }
            .onChange(of: steam.guardPrompt) { _, prompt in if prompt?.codeType != nil { focus = .code } }
            .onDisappear { if !steam.signedIn { steam.cancelSignIn() } }
        }
    }

    private func signedInSection(_ name: String) -> some View {
        Section {
            LabeledContent("Account", value: name)
            Button("Sign out", role: .destructive) { steam.signOut() }
        } footer: {
            Text("Signing out removes the token from this device's Keychain.")
        }
    }

    private var passwordSection: some View {
        Section {
            TextField("Steam account name", text: $account)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .account).submitLabel(.next).onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .textContentType(.password).focused($focus, equals: .password)
                .submitLabel(.go).onSubmit(submit)
            Button(action: submit) {
                HStack {
                    Text("Sign in").fontWeight(.semibold)
                    if steam.signInBusy { Spacer(); ProgressView() }
                }
            }.disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || steam.signInBusy)
        } footer: {
            Text("Use your Steam account name, which can differ from your email address.")
        }
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, !steam.signInBusy else { return }
        steam.signIn(account: account, password: password)
        password = ""
    }

    private func guardSection(_ prompt: SteamGuardPrompt) -> some View {
        Section {
            if let type = prompt.codeType {
                Text(type == .device
                     ? "Enter the Steam Guard code shown in the Steam app on your phone."
                     : "Enter the code Steam sent to your email" + (prompt.hint.isEmpty ? "." : " (\(prompt.hint))."))
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.title3.monospaced()).focused($focus, equals: .code)
                    .submitLabel(.go).onSubmit { steam.submitGuardCode(code) }
                Button {
                    steam.submitGuardCode(code)
                } label: {
                    HStack { Text("Continue").fontWeight(.semibold); if steam.signInBusy { Spacer(); ProgressView() } }
                }.disabled(code.trimmingCharacters(in: .whitespaces).count < 5 || steam.signInBusy)
            }
            if prompt.canApprove {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(prompt.codeType == nil
                         ? "Approve this sign-in in the Steam app on your phone."
                         : "Or approve this sign-in in the Steam app.")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Start over", role: .cancel) { code = ""; steam.cancelSignIn() }
        } header: { Text("Steam Guard") }
    }

    private var qrSection: some View {
        Section {
            if let image = steam.qrImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 240).padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Steam sign-in QR code")
                Text("On another device, open the Steam app, go to Steam Guard, and scan this code.")
                if let link = steam.qrLink {
                    Button { UIApplication.shared.open(link) } label: {
                        Label("Open in the Steam app on this device", systemImage: "arrow.up.forward.app")
                    }
                }
                HStack(spacing: 12) { ProgressView(); Text("Waiting for approval…").foregroundStyle(.secondary) }
            } else if steam.signInBusy {
                HStack(spacing: 12) { ProgressView(); Text("Getting a sign-in code…").foregroundStyle(.secondary) }
            } else {
                Button("Get a new code") { steam.beginQR() }
            }
        }
    }
}

#endif


import Foundation

class SteamManager {
    func applySteamRegistryFixes(prefixPath: String) {
        let registryPath = prefixPath + "/user.reg"
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: registryPath) else { return }
        
        do {
            var registryContent = try String(contentsOfFile: registryPath, encoding: .utf8)
            
            let overrides = """
            
            [Software\\\\Wine\\\\AppDefaults\\\\steam.exe\\\\DllOverrides]
            "dwrite"="d"
            "winhttp"="n,b"
            "crypt32"="n,b"
            "secur32"="n,b"
            
            [Software\\\\Valve\\\\Steam]
            "DWriteEnable"="0"
            "CEFDisableGPU"="1"
            "SmoothScrollWebviews"="0"
            
            """
            
            if !registryContent.contains("AppDefaults\\\\steam.exe") {
                registryContent.append(overrides)
                try registryContent.write(toFile: registryPath, atomically: true, encoding: .utf8)
            }
        } catch {
            print("SteamManager: Registry override failed.")
        }
    }
}
