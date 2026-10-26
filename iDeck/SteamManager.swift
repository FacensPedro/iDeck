

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
        guard let value = ProcessInfo.processInfo.environment[name] else {
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
        guard let valid = usable(accountName: tokens.accountName, refreshToken: tokens.refreshToken, now: Date()) else { return nil }
        return valid
    }

    static func signOut() {
        let previousAccount = accountName
        SteamTokenStore().clearTokens()
        if let previousAccount {
            SteamLibraryPreviewCache.remove(account: previousAccount)
        }
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
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
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
                        Label(tr("Sign in to Steam"), systemImage: "person.crop.circle.fill").font(.title2.bold())
                        Text(tr("iDeck can use this secure Steam sign-in to access your Steam account."))
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if let name = steam.accountName {
                    signedInSection(name)
                } else if let prompt = steam.guardPrompt {
                    guardSection(prompt)
                } else {
                    Section {
                        Picker(tr("Sign-in method"), selection: $method) {
                            Text(tr("Password")).tag(SteamSignInModel.SignInMethod.password)
                            Text(tr("QR code")).tag(SteamSignInModel.SignInMethod.qr)
                        }.pickerStyle(.segmented)
                    }
                    if method == .password { passwordSection } else { qrSection }
                }
                if let error = steam.signInError {
                    Section { Label(tr(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Text(tr("iDeck signs in with Steam directly. Your password is sent only to Steam and is never stored. A sign-in token is kept in this device's Keychain until you sign out."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(tr("Steam")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(steam.signedIn ? tr("Done") : tr("Cancel")) { steam.cancelSignIn(); dismiss() }
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
            Button(tr("Sign out"), role: .destructive) { steam.signOut() }
        } footer: {
            Text(tr("Signing out removes the token from this device's Keychain."))
        }
    }

    private var passwordSection: some View {
        Section {
            TextField(tr("Steam account name"), text: $account)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .account).submitLabel(.next).onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .textContentType(.password).focused($focus, equals: .password)
                .submitLabel(.go).onSubmit(submit)
            Button(action: submit) {
                HStack {
                    Text(tr("Sign in")).fontWeight(.semibold)
                    if steam.signInBusy { Spacer(); ProgressView() }
                }
            }.disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || steam.signInBusy)
        } footer: {
            Text(tr("Use your Steam account name, which can differ from your email address."))
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
                Text(tr(type == .device
                     ? "Enter the Steam Guard code shown in the Steam app on your phone."
                     : "Enter the code Steam sent to your email") + (type == .device ? "" : (prompt.hint.isEmpty ? "." : " (\(prompt.hint)).")))
                TextField(tr("Code"), text: $code)
                    .textContentType(.oneTimeCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.title3.monospaced()).focused($focus, equals: .code)
                    .submitLabel(.go).onSubmit { steam.submitGuardCode(code) }
                Button {
                    steam.submitGuardCode(code)
                } label: {
                    HStack { Text(tr("Continue")).fontWeight(.semibold); if steam.signInBusy { Spacer(); ProgressView() } }
                }.disabled(code.trimmingCharacters(in: .whitespaces).count < 5 || steam.signInBusy)
            }
            if prompt.canApprove {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(tr(prompt.codeType == nil
                         ? "Approve this sign-in in the Steam app on your phone."
                         : "Or approve this sign-in in the Steam app."))
                        .foregroundStyle(.secondary)
                }
            }
            Button(tr("Start over"), role: .cancel) { code = ""; steam.cancelSignIn() }
        } header: { Text(tr("Steam Guard")) }
    }

    private var qrSection: some View {
        Section {
            if let image = steam.qrImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 240).padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(tr("Steam sign-in QR code"))
                Text(tr("On another device, open the Steam app, go to Steam Guard, and scan this code."))
                if let link = steam.qrLink {
                    Button { UIApplication.shared.open(link) } label: {
                        Label(tr("Open in the Steam app on this device"), systemImage: "arrow.up.forward.app")
                    }
                }
                HStack(spacing: 12) { ProgressView(); Text(tr("Waiting for approval…")).foregroundStyle(.secondary) }
            } else if steam.signInBusy {
                HStack(spacing: 12) { ProgressView(); Text(tr("Getting a sign-in code…")).foregroundStyle(.secondary) }
            } else {
                Button(tr("Get a new code")) { steam.beginQR() }
            }
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
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Reduced to the
// message types the owned library and downloads use. The numbers are Valve's
// (steammessages / enums.proto): interface facts of Steam's public protocol.

import Foundation

// MARK: - Connection state

enum SteamConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected       // WebSocket up, not yet logged on
    case authenticated   // logged on
    case reconnecting    // lost the connection, trying again
}

// MARK: - Message types

/// The message types the library and downloads use.
enum EMsg: UInt32 {
    /// Set on the message type of a protobuf-encoded message.
    static let protoMask: UInt32 = 0x80000000

    case multi = 1
    case clientHeartBeat = 703
    case clientHello = 4006
    case clientLogon = 5514
    case clientLogonResponse = 5515
    case clientLogOff = 5516
    case clientLoggedOff = 5517
    case clientLicenseList = 780
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    case serviceMethod = 146
    case serviceMethodResponse = 147
    case serviceMethodCallFromClient = 151

    /// The raw value with the protobuf flag set.
    var masked: UInt32 { rawValue | EMsg.protoMask }
}

/// Unified-service methods.
enum SteamServiceMethod: String {
    case getManifestRequestCode = "ContentServerDirectory.GetManifestRequestCode#1"
    case getCDNAuthToken = "ContentServerDirectory.GetCDNAuthToken#1"
    /// The account's own playtime and last-played times.
    case getOwnedGames = "Player.GetOwnedGames#1"
    /// The account's Steam Cloud file list for one app.
    case cloudGetAppFileChangelist = "Cloud.GetAppFileChangelist#1"
    /// Where one cloud file can be downloaded from.
    case cloudClientFileDownload = "Cloud.ClientFileDownload#1"
    /// Uploading an app's changed cloud files: a batch, each file, the end of the batch.
    case cloudBeginAppUploadBatch = "Cloud.BeginAppUploadBatch#1"
    case cloudClientBeginFileUpload = "Cloud.ClientBeginFileUpload#1"
    case cloudClientCommitFileUpload = "Cloud.ClientCommitFileUpload#1"
    case cloudCompleteAppUploadBatch = "Cloud.CompleteAppUploadBatchBlocking#1"
}

// MARK: - Result codes

enum EResult: UInt32 {
    case ok = 1
    case tryAnotherCM = 48   // the server is overloaded; connect to another

    var isSuccess: Bool { self == .ok }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Encodes and decodes Steam3 wire format messages over WebSocket
///
/// **Protobuf wire format** (EMsg has 0x80000000 proto mask set):
/// ```
/// [4 bytes] EMsg (uint32 LE) | 0x80000000
/// [4 bytes] Header length (uint32 LE)
/// [N bytes] CMsgProtoBufHeader (protobuf)
/// [M bytes] Message body (protobuf)
/// ```
///
/// **Non-protobuf wire format** (old-style, used by ChannelEncrypt etc.):
/// ```
/// [4 bytes] EMsg (uint32 LE, no proto mask)
/// [8 bytes] targetJobID (uint64 LE, default 0xFFFFFFFFFFFFFFFF)
/// [8 bytes] sourceJobID (uint64 LE, default 0xFFFFFFFFFFFFFFFF)
/// [M bytes] Message body
/// ```
struct SteamMessageCodec {

    /// Size of the old-style MsgHdr (after EMsg): targetJobID(8) + sourceJobID(8)
    private static let msgHdrSize = 16

    // MARK: - Outgoing Message

    struct OutgoingMessage {
        let eMsg: EMsg
        let header: CMsgProtoBufHeader
        let body: Data

        /// Serialize to Steam3 wire format (protobuf)
        func serialize() -> Data {
            let headerData = header.serialize()

            var data = Data(capacity: 8 + headerData.count + body.count)

            // EMsg with protobuf mask
            var maskedEMsg = eMsg.masked.littleEndian
            data.append(Data(bytes: &maskedEMsg, count: 4))

            // Header length
            var headerLen = UInt32(headerData.count).littleEndian
            data.append(Data(bytes: &headerLen, count: 4))

            // Header
            data.append(headerData)

            // Body
            data.append(body)

            return data
        }
    }

    // MARK: - Incoming Message

    struct IncomingMessage {
        let eMsg: EMsg
        let rawEMsg: UInt32
        let isProtobuf: Bool
        let header: CMsgProtoBufHeader
        let body: Data
    }

    // MARK: - Decode

    /// Decode a raw binary message from the WebSocket.
    /// Handles both protobuf and non-protobuf (old-style) message formats.
    static func decode(_ data: Data) throws -> IncomingMessage {
        guard data.count >= 4 else {
            SteamLog.trace("Message too small (\(data.count) bytes)")
            throw SteamError.invalidMessage
        }

        // Read EMsg (first 4 bytes, little-endian)
        let rawEMsg = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }
        let rawEMsgLE = UInt32(littleEndian: rawEMsg)
        let isProtobuf = (rawEMsgLE & EMsg.protoMask) != 0
        let eMsgValue = rawEMsgLE & ~EMsg.protoMask

        if isProtobuf {
            return try decodeProtobuf(data: data, eMsgValue: eMsgValue)
        } else {
            return try decodeNonProtobuf(data: data, eMsgValue: eMsgValue)
        }
    }

    /// Decode a protobuf-format message
    private static func decodeProtobuf(data: Data, eMsgValue: UInt32) throws -> IncomingMessage {
        guard data.count >= 8 else {
            throw SteamError.invalidMessage
        }

        // Read header length (bytes 4-7)
        let headerLen = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }
        let headerLength = Int(UInt32(littleEndian: headerLen))

        guard headerLength >= 0, data.count >= 8 + headerLength else {
            SteamLog.trace("Invalid protobuf header length \(headerLength) for \(data.count) byte message (EMsg: \(eMsgValue))")
            throw SteamError.invalidMessage
        }

        let headerData = data.subdata(in: 8..<(8 + headerLength))
        let header = try CMsgProtoBufHeader.deserialize(from: headerData)
        let body = data.subdata(in: (8 + headerLength)..<data.count)

        let eMsg = EMsg(rawValue: eMsgValue)
        if eMsg == nil {
            SteamLog.trace("Unknown protobuf EMsg \(eMsgValue) (\(body.count) bytes body)")
        }

        return IncomingMessage(
            eMsg: eMsg ?? .multi,
            rawEMsg: eMsgValue,
            isProtobuf: true,
            header: header,
            body: body
        )
    }

    /// Decode a non-protobuf (old-style) message.
    ///
    /// Two header formats exist:
    ///
    /// **Extended header** (MsgHdrExtended, headerSize=36):
    /// `[4 EMsg][1 headerSize=36][2 headerVersion=2][8 targetJobID][8 sourceJobID][1 canary][8 steamID][4 sessionID][body]`
    ///
    /// **Simple header** (MsgHdr, headerSize=20):
    /// `[4 EMsg][8 targetJobID][8 sourceJobID][body]`
    ///
    /// Detect by reading byte 4: if it equals 36 and bytes 5-6 equal version 2, it's the extended header.
    private static func decodeNonProtobuf(data: Data, eMsgValue: UInt32) throws -> IncomingMessage {
        guard data.count >= 5 else {
            SteamLog.trace("Non-protobuf message too small: \(data.count) bytes (EMsg: \(eMsgValue))")
            throw SteamError.invalidMessage
        }

        // Detect extended header: byte[4]=headerSize=36, bytes[5-6]=headerVersion=2
        let possibleHeaderSize = Int(data[4])
        let possibleVersion: UInt16 = data.count >= 7
            ? data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt16.self)) }
            : 0
        let isExtended = (possibleHeaderSize == 36 && possibleVersion == 2)
        let headerSize = isExtended ? 36 : 20

        guard data.count >= headerSize else {
            SteamLog.trace("Non-protobuf message smaller than header: \(data.count) < \(headerSize) (EMsg: \(eMsgValue))")
            throw SteamError.invalidMessage
        }

        var header = CMsgProtoBufHeader()

        if isExtended {
            // MsgHdrExtended layout:
            // [4 EMsg][1 headerSize][2 headerVersion][8 targetJobID][8 sourceJobID][1 canary][8 steamID][4 sessionID]
            header.jobidTarget = data.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 7, as: UInt64.self))
            }
            header.jobidSource = data.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 15, as: UInt64.self))
            }
            if data.count >= 32 {
                header.steamid = data.withUnsafeBytes {
                    UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
                }
            }
            if data.count >= 36 {
                header.clientSessionid = data.withUnsafeBytes {
                    Int32(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self)))
                }
            }
        } else {
            // Simple MsgHdr layout: [4 EMsg][8 targetJobID][8 sourceJobID]
            header.jobidTarget = data.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self))
            }
            header.jobidSource = data.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self))
            }
        }

        let body = data.subdata(in: headerSize..<data.count)
        let eMsg = EMsg(rawValue: eMsgValue)
        SteamLog.trace("Non-protobuf EMsg \(eMsgValue) (header=\(headerSize)B, body=\(body.count)B)")

        return IncomingMessage(
            eMsg: eMsg ?? .multi,
            rawEMsg: eMsgValue,
            isProtobuf: false,
            header: header,
            body: body
        )
    }

    // MARK: - Encode

    /// Create an outgoing message
    static func encode(
        eMsg: EMsg,
        header: CMsgProtoBufHeader,
        body: Data
    ) -> Data {
        OutgoingMessage(eMsg: eMsg, header: header, body: body).serialize()
    }

    /// Create a service method call message
    static func encodeServiceMethod(
        method: SteamServiceMethod,
        body: Data,
        steamID: UInt64 = 0,
        sessionID: Int32 = 0,
        jobID: UInt64? = nil
    ) -> Data {
        var header = CMsgProtoBufHeader()
        header.steamid = steamID
        header.clientSessionid = sessionID
        header.targetJobName = method.rawValue
        if let jobID {
            header.jobidSource = jobID
        }

        return encode(eMsg: .serviceMethodCallFromClient, header: header, body: body)
    }

    /// Create a standard client message
    static func encodeClientMessage(
        eMsg: EMsg,
        body: Data,
        steamID: UInt64 = 0,
        sessionID: Int32 = 0,
        jobID: UInt64? = nil
    ) -> Data {
        var header = CMsgProtoBufHeader()
        header.steamid = steamID
        header.clientSessionid = sessionID
        if let jobID {
            header.jobidSource = jobID
        }

        return encode(eMsg: eMsg, header: header, body: body)
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

// MARK: - WebSocket Delegate

/// Logs WebSocket lifecycle events: protocol negotiation, server-initiated close.
/// URLSession calls these on its internal delegate queue.
private final class SteamWebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // This is the ground truth — what protocol the server actually agreed to.
        // If nil, the server did not echo "steamdataport" in its 101 response.
        SteamLog.trace("WS handshake complete — server protocol: \(`protocol` ?? "(none, server did not echo)")")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        SteamLog.trace("WS server closed — code: \(closeCode.rawValue) reason: \"\(reasonStr)\"")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            SteamLog.trace("WS task completed with error: \(error.localizedDescription)")
        }
    }
}

private final class SteamPingResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed { return false }
        completed = true
        return true
    }
}

// MARK: - SteamConnection

/// WebSocket transport to a Steam CM server (wss://).
/// TLS handles all encryption — no ChannelEncrypt handshake required.
/// Each binary WebSocket frame is exactly one complete Steam protocol message.
actor SteamConnection {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let wsDelegate = SteamWebSocketDelegate()
    private let serverList = CMServerList()
    private var currentEndpoint: String?
    private var messageHandler: ((Data) -> Void)?
    private var disconnectHandler: ((Error?) -> Void)?

    var isConnected: Bool {
        webSocketTask?.state == .running
    }

    // MARK: - Connect

    func connect() async throws {
        var lastError: Error = SteamError.connectionTimeout
        for attempt in 1...3 {
            let server = try await serverList.getServer()
            currentEndpoint = server.endpoint
            SteamLog.trace("Connecting to CM (attempt \(attempt)/3): \(server.url)")
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: config, delegate: wsDelegate, delegateQueue: nil)
            urlSession = session
            let task = session.webSocketTask(with: server.url, protocols: ["steamdataport"])
            webSocketTask = task
            task.resume()
            do {
                let guardOnce = SteamPingResumeGuard()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        guard guardOnce.claim() else { return }
                        if let error { continuation.resume(throwing: SteamError.connectionFailed(error.localizedDescription)) }
                        else { continuation.resume() }
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        guard guardOnce.claim() else { return }
                        continuation.resume(throwing: SteamError.connectionTimeout)
                    }
                }
                await serverList.markSuccess(endpoint: server.endpoint)
                scheduleReceive(task)
                SteamLog.trace("WebSocket connected — ready for protocol messages")
                return
            } catch {
                lastError = error
                SteamLog.trace("CM connection attempt \(attempt) failed: \(error.localizedDescription)")
                await serverList.markFailed(endpoint: server.endpoint)
                disconnect()
                if attempt < 3 { try? await Task.sleep(nanoseconds: 350_000_000) }
            }
        }
        throw lastError
    }

    // MARK: - Receive

    /// Continuously receive WebSocket binary frames.
    /// Each frame is one complete Steam protocol message — no TCP length/magic framing.
    nonisolated private func scheduleReceive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    Task { await self.dispatchMessage(data) }
                case .string(let text):
                    SteamLog.trace("unexpected text frame (\(text.utf8.count) bytes)")
                @unknown default:
                    break
                }
                // Schedule the next receive immediately to keep the loop running
                self.scheduleReceive(task)

            case .failure(let error):
                // NSPOSIXErrorDomain 57 "Socket is not connected" is a normal disconnect
                let nsError = error as NSError
                let isNormalClose = nsError.domain == NSPOSIXErrorDomain && nsError.code == 57
                if !isNormalClose {
                    SteamLog.trace("WS receive error: \(error.localizedDescription)")
                }
                Task { await self.handleDisconnect(error: isNormalClose ? nil : error) }
            }
        }
    }

    private func dispatchMessage(_ data: Data) {
        messageHandler?(data)
    }

    // MARK: - Send

    /// Send raw bytes as a binary WebSocket frame.
    /// Wire format: [4B masked EMsg][4B headerLen][protobuf header][body] — no TCP framing wrapper.
    func send(_ data: Data) async throws {
        guard let task = webSocketTask, task.state == .running else {
            throw SteamError.disconnected
        }
        try await task.send(.data(data))
    }

    func sendMessage(eMsg: EMsg, header: CMsgProtoBufHeader, body: Data) async throws {
        let encoded = SteamMessageCodec.encode(eMsg: eMsg, header: header, body: body)
        try await send(encoded)
    }

    /// WebSocket-level ping (transport keepalive).
    /// Steam protocol heartbeat is handled by SteamSession at the message level.
    func sendPing() async {
        webSocketTask?.sendPing { _ in }
    }

    // MARK: - Handlers

    func setMessageHandler(_ handler: @escaping (Data) -> Void) {
        self.messageHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping (Error?) -> Void) {
        self.disconnectHandler = handler
    }

    private func handleDisconnect(error: Error?) {
        // Only fire disconnect once per connection — clear webSocketTask to prevent repeat
        guard webSocketTask != nil else { return }
        webSocketTask = nil
        if let error {
            SteamLog.trace("Connection lost: \(error.localizedDescription)")
        } else {
            SteamLog.trace("Connection closed cleanly")
        }
        disconnectHandler?(error)
    }

    // MARK: - Disconnect

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        currentEndpoint = nil
        SteamLog.trace("Disconnected")
    }

    func reconnect() async throws {
        if let endpoint = currentEndpoint {
            await serverList.markFailed(endpoint: endpoint)
        }
        disconnect()
        try await connect()
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Discovers and manages Steam CM (Connection Manager) WebSocket endpoints.
actor CMServerList {
    /// A CM server endpoint (WebSocket)
    struct CMServer: Codable, Sendable {
        let host: String
        let port: UInt16
        var lastAttempt: Date?
        var failCount: Int = 0

        var isHealthy: Bool { failCount < 3 }

        var endpoint: String { "\(host):\(port)" }

        var url: URL { URL(string: "wss://\(host):\(port)/cmsocket/")! }
    }

    private var servers: [CMServer] = []
    private var lastFetched: Date?
    private let cacheKey = "swiftsteam_cm_servers_websocket"
    private let staleInterval: TimeInterval = 3600

    // MARK: - Public API

    /// Get the best available CM server to connect to
    func getServer() async throws -> CMServer {
        if servers.isEmpty || isListStale {
            try await refreshServerList()
        }

        guard let server = servers
            .filter({ $0.isHealthy })
            .sorted(by: { ($0.lastAttempt ?? .distantPast) < ($1.lastAttempt ?? .distantPast) })
            .first
        else {
            for i in servers.indices {
                servers[i].failCount = 0
            }
            guard let server = servers.first else {
                throw SteamError.noServersAvailable
            }
            return server
        }

        return server
    }

    func markFailed(endpoint: String) {
        if let index = servers.firstIndex(where: { $0.endpoint == endpoint }) {
            servers[index].failCount += 1
            servers[index].lastAttempt = Date()
        }
    }

    func markSuccess(endpoint: String) {
        if let index = servers.firstIndex(where: { $0.endpoint == endpoint }) {
            servers[index].failCount = 0
            servers[index].lastAttempt = Date()
        }
    }

    func refreshServerList() async throws {
        let freshServers = try await fetchServerList()
        guard !freshServers.isEmpty else {
            throw SteamError.noServersAvailable
        }
        servers = freshServers
        lastFetched = Date()
        cacheServerList()
    }

    // MARK: - Private

    private var isListStale: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > staleInterval
    }

    /// Fetch WebSocket CM server list from Steam Web API
    private func fetchServerList() async throws -> [CMServer] {
        let urlString = "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets"
        guard let url = URL(string: urlString) else {
            throw SteamError.connectionFailed("Invalid CM directory URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            if let cached = loadCachedServers(), !cached.isEmpty {
                SteamLog.trace("CM directory unavailable, using cached servers")
                return cached
            }
            throw SteamError.connectionFailed("CM directory returned non-200 status")
        }

        // Response format: { "response": { "serverlist": [ { "endpoint": "host:port", ... }, ... ] } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverResponse = json["response"] as? [String: Any],
              let serverList = serverResponse["serverlist"] as? [[String: Any]] else {
            throw SteamError.connectionFailed("Invalid CM directory response format")
        }

        // Each entry has an "endpoint" field: "hostname:port"
        let servers = serverList.compactMap { entry -> CMServer? in
            guard let endpoint = entry["endpoint"] as? String else { return nil }
            let parts = endpoint.split(separator: ":")
            guard parts.count == 2,
                  let port = UInt16(parts[1]) else { return nil }
            return CMServer(host: String(parts[0]), port: port)
        }

        SteamLog.trace("Fetched \(servers.count) WebSocket CM servers")
        return servers
    }

    // MARK: - Caching

    private func cacheServerList() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func loadCachedServers() -> [CMServer]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([CMServer].self, from: data) else {
            return nil
        }
        return cached
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// What the library fetcher and the depot downloader need from a logged-on
/// Steam connection. `SteamSession` is the one implementation; the host tests
/// (tests/host/check-steam-library.py) use a scripted one, so the
/// download pipeline runs without a network connection to Steam.
@MainActor
protocol SteamCMSession: AnyObject {
    /// The content-server cell the CM assigned at logon (0 before).
    var cellID: UInt32 { get }
    /// The logged-on account, 0 when not logged on.
    var steamID: UInt64 { get }

    /// Connects and logs on when the session is not already.
    func ensureConnected() async throws
    /// The owned package IDs Steam pushes after logon.
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32]
    /// Sends a client message and waits for its response.
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage
    /// Sends a product-info request and collects every part of its response.
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage]
    /// Calls a unified-service method and returns the response body.
    func callServiceMethod(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> Data
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// One-shot async delivery of the owned-package-ID list.
///
/// Steam pushes `CMsgClientLicenseList` automatically right after every CM
/// logon. `set(_:)` records it; `value(timeout:)` returns it immediately if
/// already received, otherwise waits — with a per-waiter timeout that throws
/// rather than hanging forever. `reset()` is called at the start of each
/// connection so a stale list never satisfies a post-reconnect waiter.
@MainActor
final class LicenseListBox {
    private var packageIDs: [UInt32]?
    private var waiters: [UUID: CheckedContinuation<[UInt32], Error>] = [:]

    /// Record a license list and wake every pending waiter. Overwrites any
    /// previous list so a fresh logon's list supersedes a stale one.
    func set(_ ids: [UInt32]) {
        packageIDs = ids
        let pending = waiters
        waiters = [:]
        for (_, continuation) in pending {
            continuation.resume(returning: ids)
        }
    }

    /// Forget the current list so the next `value(timeout:)` waits for a
    /// fresh push instead of returning a pre-reconnect list.
    func reset() {
        packageIDs = nil
    }

    /// Return the package IDs, waiting up to `timeout` seconds if none have
    /// arrived yet. Throws `SteamError.connectionTimeout` on expiry.
    func value(timeout: TimeInterval) async throws -> [UInt32] {
        if let packageIDs { return packageIDs }
        let waiterID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[waiterID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let waiter = self.waiters.removeValue(forKey: waiterID) else { return }
                waiter.resume(throwing: SteamError.connectionTimeout)
            }
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
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md): the session is
// suspended while a game runs, and the sign-in stays in SteamSignIn.

import Foundation
import Observation

/// Manages the authenticated Steam session: login, heartbeat, reconnection, message routing.
@Observable
@MainActor
class SteamSession: SteamCMSession {
    // MARK: - Published State

    private(set) var connectionState: SteamConnectionState = .disconnected
    private(set) var steamID: UInt64 = 0
    private(set) var accountName: String = ""
    private(set) var personaName: String = ""
    private(set) var cellID: UInt32 = 0
    /// While true the session neither connects nor reconnects: a game session
    /// runs, and Valve's own client must be the only one logged on with this
    /// account (see `suspend()`).
    private(set) var isSuspended = false

    // MARK: - Internal State

    private let connection = SteamConnection()
    let serverList = CMServerList()
    private var sessionID: Int32 = 0
    private var heartbeatInterval: Int32 = 30  // seconds
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var idleDisconnectTask: Task<Void, Never>?
    /// How long to stay connected after the last activity before auto-disconnecting (seconds)
    private let idleTimeout: TimeInterval = 60
    private var jobIDCounter: UInt64 = 0
    private var pendingJobs: [UInt64: CheckedContinuation<SteamMessageCodec.IncomingMessage, Error>] = [:]
    private var messageHandlers: [UInt32: (SteamMessageCodec.IncomingMessage) -> Void] = [:]

    private struct PICSAccumulator {
        var messages: [SteamMessageCodec.IncomingMessage]
        var continuation: CheckedContinuation<[SteamMessageCodec.IncomingMessage], Error>
    }
    private var pendingPICSJobs: [UInt64: PICSAccumulator] = [:]
    private let licenseListBox = LicenseListBox()

    /// SteamID used for pre-logon messages.
    /// Universe=Public(1), Type=Individual(1), Instance=Desktop(1), AccountID=0
    /// → 76561197960265728. Using raw 0 causes EResult 5 (InvalidPassword) on
    /// some CM servers.
    private static let preLogonSteamID: UInt64 = 76561197960265728

    // MARK: - Lifecycle

    /// Connect and authenticate using stored tokens (auto-login)
    func connectAndLogin() async throws {
        guard !isSuspended else { throw SteamError.disconnected }
        guard connectionState == .disconnected || connectionState == .reconnecting else { return }

        connectionState = .connecting

        do {
            // Set up message and disconnect handlers
            await connection.setMessageHandler { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleMessage(data)
                }
            }
            await connection.setDisconnectHandler { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleDisconnect(error: error)
                }
            }

            // Capture the license list Steam pushes right after logon.
            // Registered before connecting so the handler can never miss it.
            licenseListBox.reset()
            registerHandler(for: .clientLicenseList) { [weak self] message in
                guard let self else { return }
                do {
                    let list = try CMsgClientLicenseList.deserialize(from: message.body)
                    let packageIDs = list.licenses.map { $0.packageID }
                    SteamLog.trace("ClientLicenseList: parsed \(packageIDs.count) packages (body \(message.body.count)B, eresult=\(list.eresult))")
                    self.licenseListBox.set(packageIDs)
                } catch {
                    SteamLog.trace("ClientLicenseList deserialize FAILED (body \(message.body.count)B): \(error)")
                }
            }

            // Connect via WebSocket (wss://) — TLS handles encryption, no ChannelEncrypt needed
            try await connection.connect()
            connectionState = .connected

            // Send ClientHello — required after channel encryption is established.
            let helloData = SteamMessageCodec.encodeClientMessage(
                eMsg: .clientHello,
                body: CMsgClientHello().serialize(),
                steamID: Self.preLogonSteamID,
                sessionID: 0
            )
            try await connection.send(helloData)
            SteamLog.trace("Sent ClientHello (\(helloData.count) bytes)")

            // Try to log in with stored tokens, retrying up to 2 different servers on timeout/redirect
            if let tokens = SteamSignIn.credentialsForDock() {
                var lastError: Error = SteamError.connectionTimeout
                var loggedIn = false
                for attempt in 1...2 {
                    do {
                        if attempt > 1 {
                            SteamLog.trace("Logon attempt \(attempt)/2 — reconnecting to different CM server")
                            try await connection.reconnect()
                            connectionState = .connected
                            let helloRetry = SteamMessageCodec.encodeClientMessage(
                                eMsg: .clientHello,
                                body: CMsgClientHello().serialize(),
                                steamID: Self.preLogonSteamID,
                                sessionID: 0
                            )
                            try await connection.send(helloRetry)
                            SteamLog.trace("Sent ClientHello to new server (attempt \(attempt))")
                        }
                        guard !isSuspended else { throw SteamError.disconnected }
                        try await loginWithToken(accessToken: tokens.refreshToken, accountName: tokens.accountName)
                        loggedIn = true
                        break
                    } catch SteamError.connectionFailed(let reason) where reason == "TryAnotherCM" {
                        SteamLog.trace("TryAnotherCM on attempt \(attempt) — will try different server")
                        lastError = SteamError.connectionFailed("TryAnotherCM")
                    } catch SteamError.connectionTimeout {
                        SteamLog.trace("Timeout on attempt \(attempt) — will try different server")
                        lastError = SteamError.connectionTimeout
                    }
                }
                if !loggedIn {
                    throw lastError
                }
            }
        } catch {
            connectionState = .disconnected
            throw error
        }
    }

    /// Connect on demand if not already connected/authenticated.
    /// Call this before any operation that needs the CM connection.
    func ensureConnected() async throws {
        guard !isSuspended else { throw SteamError.disconnected }
        guard connectionState != .authenticated else {
            resetIdleTimer()
            return
        }
        guard connectionState != .connecting else {
            // Already connecting — wait briefly for it to finish
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if connectionState == .authenticated { return }
                if connectionState == .disconnected { break }
            }
            if connectionState != .authenticated {
                throw SteamError.connectionTimeout
            }
            return
        }
        try await connectAndLogin()
        resetIdleTimer()
    }

    /// The owned package IDs from the license list Steam pushes after logon.
    /// Waits for the push if it hasn't landed yet.
    func awaitLicenseList(timeout: TimeInterval = 15) async throws -> [UInt32] {
        try await licenseListBox.value(timeout: timeout)
    }

    /// Reset the idle disconnect timer — called after each activity
    private func resetIdleTimer() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 60) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.connectionState == .authenticated else { return }
            SteamLog.trace("Idle timeout — disconnecting to release the server-side session")
            await self.disconnectGracefully()
        }
    }

    /// Send `ClientLogOff` so Steam servers release the session cleanly,
    /// then tear down the WebSocket. Prefer this over plain `disconnect()`
    /// whenever another session for the same account may log in next —
    /// a raw socket close leaves the session hanging on the server for
    /// several minutes, which can make the next login look like a
    /// duplicate/already-online session.
    ///
    /// Safe to call from any state — only sends logoff when authenticated;
    /// always tears down so a half-connected session can still be cleaned
    /// up.
    func disconnectGracefully() async {
        if connectionState == .authenticated {
            let logoffData = SteamMessageCodec.encodeClientMessage(
                eMsg: .clientLogOff,
                body: Data(),
                steamID: steamID,
                sessionID: sessionID
            )
            try? await connection.send(logoffData)
        }
        disconnect()
    }

    /// Stops the session for the length of a game session: logs off, closes the
    /// socket (awaited, so the account is free before Valve's client signs in)
    /// and refuses to connect until `resume()`. A second logon for the same
    /// account would otherwise log one of the two out.
    func suspend() async {
        isSuspended = true
        await disconnectGracefully()
        await connection.disconnect()
    }

    func resume() { isSuspended = false }

    /// Log in using the refresh token from the auth flow.
    /// NOTE: Despite the parameter name, CM logon requires the *refresh* token (audience: "renew"),
    /// not the access token (audience: "web"). The CMsgClientLogon.access_token field accepts both,
    /// but only the refresh token establishes a CM session.
    /// Single-resume guard for the logon continuation. The logon response,
    /// ClientLoggedOff, the send-error path, and the 20s timeout can each reach
    /// the continuation; without this the timeout double-resumed and crashed
    /// (CheckedContinuation traps on a second resume). Exactly one resume wins.
    private final class LogonResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    func loginWithToken(accessToken: String, accountName: String) async throws {
        guard await connection.isConnected else {
            throw SteamError.disconnected
        }

        self.accountName = accountName

        // Build logon message
        var logon = CMsgClientLogon()
        logon.accountName = accountName
        logon.accessToken = accessToken
        logon.machineName = SteamDevice.name
        logon.clientOSType = -102  // macOS

        let logonData = SteamMessageCodec.encodeClientMessage(
            eMsg: .clientLogon,
            body: logon.serialize(),
            steamID: Self.preLogonSteamID,
            sessionID: 0
        )

        // No logon bytes, token fragments or token claims are logged.

        // ClientLogonResponse (EMsg 5515) is NOT job-correlated — it's an unsolicited push.
        // Register a one-time handler that resolves the continuation when the response arrives.
        // Also handle legacy EMsg 751 (old CMsgClientLogOnResponse numbering).
        let resumeOnce = LogonResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // All resume paths funnel through these so the continuation resumes
            // at most once, even if a handler and the timeout fire together.
            let resumeReturning: () -> Void = {
                if resumeOnce.claim() { continuation.resume(returning: ()) }
            }
            let resumeThrowing: (Error) -> Void = { error in
                if resumeOnce.claim() { continuation.resume(throwing: error) }
            }

            let cleanupHandlers = { [weak self] in
                self?.messageHandlers.removeValue(forKey: EMsg.clientLogonResponse.rawValue)
                self?.messageHandlers.removeValue(forKey: 751)
                self?.messageHandlers.removeValue(forKey: EMsg.clientLoggedOff.rawValue)
            }

            let handleLogonResponse: (SteamMessageCodec.IncomingMessage) -> Void = { [weak self] message in
                guard let self else { return }
                cleanupHandlers()

                let eResultCode: UInt32
                let heartbeatSecs: Int32
                let outCellID: UInt32

                if message.isProtobuf {
                    // EMsg 5515: standard protobuf ClientLogonResponse
                    do {
                        let logonResponse = try CMsgClientLogonResponse.deserialize(from: message.body)
                        eResultCode = UInt32(logonResponse.eresult)
                        heartbeatSecs = logonResponse.heartbeatSeconds > 0 ? logonResponse.heartbeatSeconds : 30
                        outCellID = logonResponse.cellID
                    } catch {
                        resumeThrowing(error)
                        return
                    }
                } else {
                    // EMsg 751: legacy non-protobuf format. Body = [4 bytes EResult as UInt32 LE][...]
                    guard message.body.count >= 4 else {
                        resumeThrowing(SteamError.invalidMessage)
                        return
                    }
                    eResultCode = message.body.withUnsafeBytes {
                        UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                    }
                    heartbeatSecs = 30
                    outCellID = 0
                }

                SteamLog.trace("ClientLogonResponse: eresult=\(eResultCode)")

                // TryAnotherCM (48): server is overloaded, need to connect to a different server
                if eResultCode == EResult.tryAnotherCM.rawValue {
                    SteamLog.trace("Server says TryAnotherCM — will reconnect to different CM server")
                    resumeThrowing(SteamError.connectionFailed("TryAnotherCM"))
                    return
                }

                guard let result = EResult(rawValue: eResultCode), result.isSuccess else {
                    resumeThrowing(SteamError.logonDenied(eResultCode))
                    return
                }

                // A game session took the account while this logon was on its way
                // (suspend() ran): log straight off again instead of staying online
                // next to Valve's client.
                if self.isSuspended {
                    let logoff = SteamMessageCodec.encodeClientMessage(eMsg: .clientLogOff, body: Data(),
                                                                      steamID: message.header.steamid,
                                                                      sessionID: message.header.clientSessionid)
                    Task { [connection = self.connection] in
                        try? await connection.send(logoff)
                        await connection.disconnect()
                    }
                    SteamLog.trace("Logon completed during a game session: logged off again")
                    resumeThrowing(SteamError.disconnected)
                    return
                }

                self.steamID = message.header.steamid
                self.sessionID = message.header.clientSessionid
                self.heartbeatInterval = heartbeatSecs
                self.cellID = outCellID
                self.connectionState = .authenticated
                self.reconnectAttempts = 0
                SteamLog.trace("Authenticated")
                self.startHeartbeat()
                self.resetIdleTimer()
                resumeReturning()
            }

            messageHandlers[EMsg.clientLogonResponse.rawValue] = handleLogonResponse
            messageHandlers[751] = handleLogonResponse  // Legacy EMsg numbering

            // Also catch immediate rejection via ClientLoggedOff
            messageHandlers[EMsg.clientLoggedOff.rawValue] = { _ in
                cleanupHandlers()
                SteamLog.trace("Got ClientLoggedOff during logon")
                resumeThrowing(SteamError.authenticationFailed("Server sent ClientLoggedOff during logon"))
            }

            Task {
                do {
                    try await connection.send(logonData)
                    SteamLog.trace("Sent ClientLogon, waiting for response")
                } catch {
                    cleanupHandlers()
                    resumeThrowing(error)
                }
            }

            // 20-second timeout — if server doesn't respond after 20s, try different CM.
            // The resume guard (not a messageHandlers TOCTOU check) is what prevents a
            // double-resume if the logon response landed at the same moment.
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                cleanupHandlers()
                if resumeOnce.claim() {
                    SteamLog.trace("ClientLogon timed out after 20s: no response from the server")
                    continuation.resume(throwing: SteamError.connectionTimeout)
                }
            }
        }
    }

    /// Disconnect and clean up
    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil

        // Cancel all pending jobs
        for (_, continuation) in pendingJobs {
            continuation.resume(throwing: SteamError.disconnected)
        }
        pendingJobs.removeAll()
        for (_, acc) in pendingPICSJobs {
            acc.continuation.resume(throwing: SteamError.disconnected)
        }
        pendingPICSJobs.removeAll()

        Task {
            await connection.disconnect()
        }

        connectionState = .disconnected
        steamID = 0
        sessionID = 0
        SteamLog.trace("Session disconnected")
    }

    /// Log off and disconnect. The stored sign-in is left alone: signing out
    /// goes through `SteamSignIn.signOut()`.
    func logoff() {
        // Send logoff message (best-effort)
        if connectionState == .authenticated {
            let logoffData = SteamMessageCodec.encodeClientMessage(
                eMsg: .clientLogOff,
                body: Data(),
                steamID: steamID,
                sessionID: sessionID
            )
            Task {
                try? await connection.send(logoffData)
            }
        }

        disconnect()
        accountName = ""
        personaName = ""
    }

    // MARK: - Message Sending

    /// Get a unique job ID for request/response correlation
    func nextJobID() -> UInt64 {
        jobIDCounter += 1
        return jobIDCounter
    }

    /// Send a message and wait for a specific response
    func sendAndWait(
        eMsg: EMsg,
        body: Data,
        responseEMsg: EMsg,
        timeout: TimeInterval = 10
    ) async throws -> SteamMessageCodec.IncomingMessage {
        resetIdleTimer()
        let jobID = nextJobID()

        let data = SteamMessageCodec.encodeClientMessage(
            eMsg: eMsg,
            body: body,
            steamID: steamID,
            sessionID: sessionID,
            jobID: jobID
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingJobs[jobID] = continuation

            Task {
                do {
                    try await connection.send(data)
                } catch {
                    if pendingJobs.removeValue(forKey: jobID) != nil {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = pendingJobs.removeValue(forKey: jobID) {
                    cont.resume(throwing: SteamError.connectionTimeout)
                }
            }
        }
    }

    /// Send a PICSProductInfo request and collect all response messages until pendingResponseCount == 0.
    /// Steam splits large PICS responses across multiple messages with the same jobidTarget.
    func sendAndWaitPICS(
        eMsg: EMsg,
        body: Data,
        timeout: TimeInterval = 30
    ) async throws -> [SteamMessageCodec.IncomingMessage] {
        resetIdleTimer()
        let jobID = nextJobID()

        let data = SteamMessageCodec.encodeClientMessage(
            eMsg: eMsg,
            body: body,
            steamID: steamID,
            sessionID: sessionID,
            jobID: jobID
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingPICSJobs[jobID] = PICSAccumulator(messages: [], continuation: continuation)

            Task {
                do {
                    try await connection.send(data)
                } catch {
                    if pendingPICSJobs.removeValue(forKey: jobID) != nil {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout — return partial results if any arrived, otherwise error
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let acc = pendingPICSJobs.removeValue(forKey: jobID) {
                    if acc.messages.isEmpty {
                        acc.continuation.resume(throwing: SteamError.connectionTimeout)
                    } else {
                        acc.continuation.resume(returning: acc.messages)
                    }
                }
            }
        }
    }

    /// Send a service method call and wait for response
    func callServiceMethod(
        method: SteamServiceMethod,
        body: Data,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        resetIdleTimer()
        let jobID = nextJobID()

        var header = CMsgProtoBufHeader()
        header.steamid = steamID
        header.clientSessionid = sessionID
        header.targetJobName = method.rawValue
        header.jobidSource = jobID

        let data = SteamMessageCodec.encode(
            eMsg: .serviceMethodCallFromClient,
            header: header,
            body: body
        )

        let response: SteamMessageCodec.IncomingMessage = try await withCheckedThrowingContinuation { continuation in
            pendingJobs[jobID] = continuation

            Task {
                do {
                    try await connection.send(data)
                } catch {
                    pendingJobs.removeValue(forKey: jobID)
                    continuation.resume(throwing: error)
                }
            }

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = pendingJobs.removeValue(forKey: jobID) {
                    cont.resume(throwing: SteamError.connectionTimeout)
                }
            }
        }

        if response.header.eresult != 1 {
            SteamLog.trace("\(method.rawValue) header eresult=\(response.header.eresult)")
        }
        return response.body
    }

    /// Send a message without waiting for response
    func sendMessage(eMsg: EMsg, body: Data) async throws {
        let data = SteamMessageCodec.encodeClientMessage(
            eMsg: eMsg,
            body: body,
            steamID: steamID,
            sessionID: sessionID
        )
        try await connection.send(data)
    }

    /// Register a handler for a specific message type
    func registerHandler(for eMsg: EMsg, handler: @escaping (SteamMessageCodec.IncomingMessage) -> Void) {
        messageHandlers[eMsg.rawValue] = handler
    }

    // MARK: - Message Handling

    private func handleMessage(_ data: Data) {
        let message: SteamMessageCodec.IncomingMessage
        do {
            message = try SteamMessageCodec.decode(data)
        } catch {
            SteamLog.trace("Failed to decode message (\(data.count) bytes): \(error)")
            return
        }

        // Every received message, when tracing.
        SteamLog.trace("← \(Self.messageName(message.rawEMsg)) (\(message.body.count) bytes)" +
              (message.header.jobidTarget != UInt64.max ? " jobTarget=\(message.header.jobidTarget)" : "") +
              (!message.header.targetJobName.isEmpty ? " method=\(message.header.targetJobName)" : ""))

        // Handle multi-message containers
        if message.rawEMsg == EMsg.multi.rawValue {
            handleMultiMessage(message)
            return
        }

        // Accumulate multi-part PICSProductInfoResponse messages.
        // Steam sends several responses per request; pendingResponseCount counts down to 0.
        if message.rawEMsg == EMsg.clientPICSProductInfoResponse.rawValue,
           message.header.jobidTarget != UInt64.max,
           var acc = pendingPICSJobs[message.header.jobidTarget] {
            acc.messages.append(message)
            let pending = (try? CMsgClientPICSProductInfoResponse.deserialize(from: message.body))?.pendingResponseCount ?? 0
            if pending == 0 {
                pendingPICSJobs.removeValue(forKey: message.header.jobidTarget)
                acc.continuation.resume(returning: acc.messages)
            } else {
                pendingPICSJobs[message.header.jobidTarget] = acc
            }
            return
        }

        // Check for pending job response (jobidTarget matches our jobidSource)
        if message.header.jobidTarget != UInt64.max,
           let continuation = pendingJobs.removeValue(forKey: message.header.jobidTarget) {
            continuation.resume(returning: message)
            return
        }

        // Log unmatched service method responses for debugging
        if message.rawEMsg == EMsg.serviceMethodResponse.rawValue {
            SteamLog.trace("ServiceMethodResponse not matched: jobTarget=\(message.header.jobidTarget), pending=\(Array(pendingJobs.keys))")
        }

        // Dispatch to registered handlers
        if let handler = messageHandlers[message.rawEMsg] {
            handler(message)
            return
        }

        // Handle known unsolicited messages
        handleUnsolicitedMessage(message)
    }

    private static func messageName(_ raw: UInt32) -> String {
        switch raw {
        case EMsg.multi.rawValue: return "Multi"
        case EMsg.clientLogon.rawValue: return "ClientLogon"
        case EMsg.clientLogonResponse.rawValue: return "ClientLogonResponse"
        case 751: return "ClientLogOnResponse(legacy)"
        case EMsg.clientLoggedOff.rawValue: return "ClientLoggedOff"
        case EMsg.clientHeartBeat.rawValue: return "ClientHeartBeat"
        case EMsg.clientHello.rawValue: return "ClientHello"
        case EMsg.serviceMethodResponse.rawValue: return "ServiceMethodResponse"
        default: return "EMsg\(raw)"
        }
    }

    private func handleMultiMessage(_ message: SteamMessageCodec.IncomingMessage) {
        do {
            let multi = try CMsgMulti.deserialize(from: message.body)
            var payload = multi.messageBody

            // If sizeUnzipped > 0, the payload is gzip compressed
            if multi.sizeUnzipped > 0 {
                guard let decompressed = payload.gunzip(expectedSize: Int(multi.sizeUnzipped)) else {
                    SteamLog.trace("Failed to decompress multi message")
                    return
                }
                payload = decompressed
            }

            // Parse sub-messages: each is [4 bytes length][message data]
            var offset = 0
            while offset + 4 <= payload.count {
                let subLen = payload.withUnsafeBytes { ptr -> UInt32 in
                    ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                }
                let length = Int(UInt32(littleEndian: subLen))
                offset += 4

                guard offset + length <= payload.count else { break }
                let subData = payload.subdata(in: offset..<offset + length)
                offset += length

                handleMessage(subData)
            }
        } catch {
            SteamLog.trace("Failed to parse multi message: \(error)")
        }
    }

    private func handleUnsolicitedMessage(_ message: SteamMessageCodec.IncomingMessage) {
        switch message.rawEMsg {
        case EMsg.clientLoggedOff.rawValue:
            SteamLog.trace("Received ClientLoggedOff")
            handleDisconnect(error: nil)
        case 751:
            // Late-arriving ClientLogOnResponse (handlers already cleaned up by timeout).
            // Parse eresult so we can log it accurately.
            if !message.isProtobuf, message.body.count >= 4 {
                let eResult = message.body.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                }
                let label = eResult == EResult.tryAnotherCM.rawValue ? " (TryAnotherCM — handled by retry logic)" : ""
                SteamLog.trace("Late ClientLogOnResponse: eresult=\(eResult)\(label)")
            }
        default:
            SteamLog.trace("Unhandled EMsg \(message.rawEMsg) (\(message.body.count) bytes)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.heartbeatInterval ?? 30)) * 1_000_000_000)
                guard !Task.isCancelled else { break }

                do {
                    try await self?.sendMessage(eMsg: .clientHeartBeat, body: Data())
                } catch {
                    SteamLog.trace("Heartbeat failed: \(error)")
                    break
                }
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect(error: Error?) {
        guard connectionState != .disconnected else { return }

        let wasAuthenticated = connectionState == .authenticated
        connectionState = .reconnecting
        heartbeatTask?.cancel()

        SteamLog.trace("Connection lost\(error.map { ": \($0.localizedDescription)" } ?? "")")

        if wasAuthenticated && reconnectAttempts < maxReconnectAttempts {
            attemptReconnect()
        } else {
            connectionState = .disconnected
        }
    }

    private func attemptReconnect() {
        reconnectTask = Task { [weak self] in
            guard let self else { return }

            // Exponential backoff: 1s, 2s, 4s, 8s, 16s
            let delay = pow(2.0, Double(reconnectAttempts))
            reconnectAttempts += 1

            SteamLog.trace("Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            do {
                try await connectAndLogin()
                SteamLog.trace("Reconnected successfully")
            } catch {
                SteamLog.trace("Reconnection failed: \(error)")
                if reconnectAttempts < maxReconnectAttempts {
                    attemptReconnect()
                } else {
                    connectionState = .disconnected
                    SteamLog.trace("Max reconnection attempts reached")
                }
            }
        }
    }

}



// MARK: - Data Extensions

import Compression

extension Data {
    /// Decompress gzip data using the Compression framework
    /// `expectedSize` is the sender's declared inflated length (CMsgMulti
    /// size_unzipped). A fixed 10x estimate silently truncated
    /// highly compressible PICS batches; the declared size is used, bounded.
    func gunzip(expectedSize: Int = 0) -> Data? {
        guard count > 10 else { return nil }

        // Check for gzip magic number
        guard self[startIndex] == 0x1f && self[startIndex + 1] == 0x8b else {
            return nil  // Not gzipped
        }

        // Skip the gzip header (RFC 1952: FEXTRA, FNAME, FCOMMENT, FHCRC).
        let bytes = [UInt8](self)
        let flags = bytes[3]
        var pos = 10
        if flags & 0x04 != 0 {
            guard pos + 2 <= bytes.count else { return nil }
            pos += 2 + (Int(bytes[pos]) | Int(bytes[pos + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 0x02 != 0 { pos += 2 }
        guard pos + 8 < bytes.count else { return nil }

        let compressedPayload = Data(bytes[pos..<(bytes.count - 8)]) // Remove header and trailer (CRC32 + size)
        guard compressedPayload.count > 0 else { return nil }

        // Decompress using raw deflate (COMPRESSION_ZLIB)
        let outputSize = expectedSize > 0 && expectedSize <= 256 * 1024 * 1024 ? expectedSize : count * 10
        var outputBuffer = Data(count: outputSize)

        let decompressedSize = compressedPayload.withUnsafeBytes { srcPtr -> Int in
            outputBuffer.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }

                let result = compression_decode_buffer(
                    dst, outputSize,
                    src, compressedPayload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                return result > 0 ? result : 0
            }
        }

        guard decompressedSize > 0 else { return nil }
        outputBuffer.count = decompressedSize
        return outputBuffer
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// App metadata parsed from Steam's product info (PICS).
struct SteamAppInfo {
    let appID: UInt32
    var name: String = ""
    var type: AppType = .game
    var installDir: String = ""
    var oslist: String = ""         // "macos", "windows", "macos,windows", etc.
    var depots: [DepotInfo] = []
    var buildID: UInt32 = 0
    var freeToDownload = false
    /// Apps owning depots this app installs through `depotfromapp`, so the
    /// install record names them the way Valve's client does.
    var sharedOwners: [UInt32: SharedOwner] = [:]
    /// Store artwork file names from `common.library_assets_full` and
    /// `common.header_image`. Newer apps publish them under a hashed folder, so
    /// the fixed legacy URL is missing for them. `parentID` names a demo's full game.
    var libraryCapsule: String?
    var libraryHero: String?
    var headerImage: String?
    var parentID: UInt32?
    /// Steam's launch configuration (`config.launch`), in Steam's order.
    /// SteamDirectStart and Madeira Dock select an installed Windows entry;
    /// Dock passes its original key to Valve's client.
    var launches: [SteamLaunchOption] = []
    /// Steam Auto-Cloud configuration (`ufs`): which files of the game are its
    /// saves, and where another platform keeps them. Empty for a game that
    /// only uses the Steam Cloud API (its files live in the user's `remote` folder).
    var saveFiles: [SaveFile] = []
    var rootOverrides: [RootOverride] = []

    /// One `ufs.savefiles` entry: `root` names a folder ("WinAppDataLocalLow",
    /// "GameInstall", ...), `path` a subfolder of it, `pattern` a wildcard.
    struct SaveFile: Equatable, Sendable {
        var root: String
        var path: String
        var pattern: String
        var recursive: Bool
        /// Lower-cased platform names the entry is limited to; empty = all.
        var platforms: [String]
    }

    /// One `ufs.rootoverrides` entry: on `os`, files the cloud lists under
    /// `root` are kept under `useInstead` + `addPath`.
    struct RootOverride: Equatable, Sendable {
        var root: String
        var os: String
        var useInstead: String
        var addPath: String
    }

    struct SharedOwner: Equatable {
        var name: String
        var installDir: String
        var buildID: UInt32
    }

    enum AppType: String {
        case game = "Game"
        case dlc = "DLC"
        case tool = "Tool"
        case demo = "Demo"
        case application = "Application"
        case music = "Music"
        case unknown = ""

        var isPlayable: Bool {
            self == .game || self == .demo || self == .application
        }

        /// PICS does not capitalize type names consistently (older apps send
        /// "game" rather than "Game"), so names match without case.
        init(pics raw: String) {
            if let exact = AppType(rawValue: raw) { self = exact; return }
            self = [AppType.game, .dlc, .tool, .demo, .application, .music]
                .first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } ?? .unknown
        }
    }

    struct DepotInfo {
        var depotID: UInt32
        var name: String = ""
        var maxSize: UInt64 = 0
        var oslist: String = ""     // "macos", "windows", etc.
        var osarch: String = ""     // "64", "32"
        var dlcAppID: UInt32? = nil
        var manifests: [String: UInt64] = [:]  // branch -> manifestID ("public" is default)
        /// Compressed download size from the modern manifests-dict format
        /// (`manifests.public.download`). 0 when PICS sent the legacy flat
        /// gid format or omitted it.
        var publicDownloadBytes: UInt64 = 0
        /// On-disk size from `manifests.public.size`. 0 when absent.
        var publicSizeBytes: UInt64 = 0
        /// `sharedinstall "1"` marks redistributable depots (DirectX, VC++
        /// runtimes) that live in Steam's common store, not the game dir;
        /// they are excluded from size math.
        var isSharedInstall: Bool = false
        /// `config.language`: empty for common content, otherwise one
        /// language pack ("english", "german", ...).
        var language: String = ""
        /// `config.lowviolence "1"`: regional alternate content.
        var lowViolence: Bool = false
        /// `depotfromapp`: the depot belongs to another app, and Valve's client
        /// installs it as that app ("required app N").
        var fromApp: UInt32? = nil

        /// Check if depot is for the specified OS
        func supports(os: String) -> Bool {
            oslist.isEmpty || oslist.lowercased().contains(os.lowercased())
        }

        /// Get the public branch manifest ID
        var publicManifestID: UInt64? {
            manifests["public"]
        }
    }

    // MARK: - Computed Properties

    /// Shared depots often omit manifests in the consuming app's PICS. Copies
    /// content metadata from the exact depot of its owner, keeping the
    /// consumer's own filters. Returns how many depots were completed.
    mutating func inheritDepots(from owners: [UInt32: SteamAppInfo]) -> Int {
        var changed = 0
        for index in depots.indices {
            let local = depots[index]
            guard local.publicManifestID == nil, let owner = local.fromApp,
                  let source = owners[owner]?.depots.first(where: { $0.depotID == local.depotID }),
                  source.publicManifestID != nil else { continue }
            depots[index].manifests = source.manifests
            depots[index].publicDownloadBytes = source.publicDownloadBytes
            depots[index].publicSizeBytes = source.publicSizeBytes
            if local.oslist.isEmpty { depots[index].oslist = source.oslist }
            if local.osarch.isEmpty { depots[index].osarch = source.osarch }
            if local.language.isEmpty { depots[index].language = source.language }
            depots[index].lowViolence = local.lowViolence || source.lowViolence
            changed += 1
        }
        return changed
    }

    var supportsWindows: Bool {
        oslist.lowercased().contains("windows") || oslist.isEmpty
    }

    /// The depots a Windows install takes: matching OS, architecture-neutral
    /// or matching osarch, common or requested-language content, no
    /// low-violence alternates, no DLC or shared redistributables, and only
    /// depots that publish a public manifest. A 64-bit selection falls back
    /// to 32-bit depots when the app only publishes those.
    func installDepots(os: String = "windows", arch: String = "64",
                       language: String = "english", includingDLC: Set<UInt32> = []) -> [DepotInfo] {
        // Black Desert PICS publishes nine regional alternatives. Summing them
        // would claim ~720 GB and downloading them all would waste storage.
        // Filter the actual install as well as the size estimate. Prefer the
        // user's country, then the global depot if that is what Valve exposes.
        let selectedBlackDesertRegion: UInt32? = {
            guard appID == 582660 else { return nil }
            let ids = Set(depots.filter {
                ideck_steam_black_desert_is_regional_depot($0.depotID) != 0 &&
                $0.publicManifestID != nil && !$0.isSharedInstall &&
                !$0.lowViolence && $0.supports(os: os) &&
                ($0.dlcAppID == nil || includingDLC.contains($0.dlcAppID!)) &&
                ($0.language.isEmpty || $0.language.caseInsensitiveCompare(language) == .orderedSame)
            }.map(\.depotID))
            guard !ids.isEmpty else { return nil }
            let country = Locale.current.region?.identifier ?? ""
            let preferred = country.withCString {
                ideck_steam_black_desert_preferred_depot($0)
            }
            if ids.contains(preferred) { return preferred }
            if ids.contains(582669) { return 582669 }
            if let regional = ids.filter({ $0 != 582661 }).sorted().first { return regional }
            return ids.sorted().first
        }()
        func select(_ arch: String) -> [DepotInfo] {
            depots.filter { d in
                (selectedBlackDesertRegion == nil ||
                    ideck_steam_black_desert_is_regional_depot(d.depotID) == 0 ||
                    d.depotID == selectedBlackDesertRegion) &&
                d.supports(os: os) && (d.dlcAppID == nil || d.dlcAppID.map { includingDLC.contains($0) } == true) && !d.isSharedInstall &&
                d.publicManifestID != nil && !d.lowViolence &&
                (d.osarch.isEmpty || d.osarch == arch) &&
                (d.language.isEmpty || d.language.caseInsensitiveCompare(language) == .orderedSame)
            }.sorted { $0.depotID < $1.depotID }
        }
        let preferred = select(arch)
        if arch == "64", !preferred.contains(where: { $0.osarch == "64" }),
           depots.contains(where: { $0.osarch == "32" && $0.supports(os: os) }) {
            return select("32")
        }
        return preferred
    }

    /// Every depot with why it was or was not selected, for the install log
    /// ("sel", or the first failing rule). IDs and flags only.
    func depotSelectionSummary(os: String = "windows", arch: String = "64",
                               language: String = "english", limit: Int = 24) -> String {
        let chosen = Set(installDepots(os: os, arch: arch, language: language).map(\.depotID))
        return depots.sorted { $0.depotID < $1.depotID }.prefix(limit).map { d in
            let why = selectionRule(d, chosen: chosen, os: os, language: language)
            let from = d.fromApp.map { "<\($0)" } ?? ""
            return "\(d.depotID)[\(d.osarch.isEmpty ? "-" : d.osarch)]\(why)\(from)"
        }.joined(separator: ",")
    }

    /// "sel" or the first rule that left the depot out.
    private func selectionRule(_ d: DepotInfo, chosen: Set<UInt32>, os: String, language: String) -> String {
        if chosen.contains(d.depotID) { return "sel" }
        if !d.supports(os: os) { return "os" }
        if d.dlcAppID != nil { return "dlc" }
        if d.isSharedInstall { return "shared" }
        if d.publicManifestID == nil { return "nomanifest" }
        if d.lowViolence { return "lowviolence" }
        if !d.language.isEmpty && d.language.caseInsensitiveCompare(language) != .orderedSame { return "lang" }
        return "arch"
    }

    /// Owned apps that can be installed for Windows at all.
    var installableOnWindows: Bool {
        supportsWindows && type.isPlayable && !installDepots().isEmpty
    }

    /// Approximate compressed download size for a platform. Per depot it
    /// prefers the modern `manifests.public.download` figure (present for most
    /// apps since Valve's 2023 PICS change) and falls back to the legacy
    /// `maxsize`. DLC depots and `sharedinstall` redistributables are not part
    /// of the base install and are left out. Treat the figure as "about".
    /// Uncompressed installation footprint, when Steam PICS supplies it.
    /// Never interpret a compressed CDN total as disk usage.
    func installedSize(for os: String) -> UInt64 {
        let selected = installDepots(os: os)
        guard !selected.isEmpty else { return 0 }
        var result: UInt64 = 0
        for depot in selected {
            let size = depot.publicSizeBytes > 0 ? depot.publicSizeBytes : depot.maxSize
            guard size > 0 else { return 0 }
            let (sum, overflow) = result.addingReportingOverflow(size)
            if overflow { return 0 }
            result = sum
        }
        return result
    }

    func downloadSize(for os: String) -> UInt64 {
        let selected = installDepots(os: os)
        let candidates: [DepotInfo]
        if !selected.isEmpty {
            candidates = selected
        } else {
            let relevant = depots.filter {
                $0.supports(os: os) && $0.dlcAppID == nil && !$0.isSharedInstall &&
                !$0.lowViolence && ($0.language.isEmpty ||
                 $0.language.caseInsensitiveCompare("english") == .orderedSame)
            }
            let architecture = relevant.contains(where: { $0.osarch == "64" }) ? "64" : "32"
            candidates = relevant.filter { $0.osarch.isEmpty || $0.osarch == architecture }
        }
        var result: UInt64 = 0
        for depot in candidates {
            let size = depot.publicDownloadBytes > 0 ? depot.publicDownloadBytes :
                (depot.maxSize > 0 ? depot.maxSize : depot.publicSizeBytes)
            let (sum, overflow) = result.addingReportingOverflow(size)
            result = overflow ? UInt64.max : sum
        }
        return result
    }

    // MARK: - Parsing

    /// Parse app info from a PICS text-VDF buffer.
    static func parse(appID: UInt32, from data: Data) -> SteamAppInfo? {
        let vdf = VDFParser.parseTextVDF(from: data)
        return parse(appID: appID, from: vdf)
    }

    /// Parse app info from a VDF dictionary
    static func parse(appID: UInt32, from vdf: [String: Any]) -> SteamAppInfo? {
        var info = SteamAppInfo(appID: appID)

        // Navigate to appinfo section
        let appInfo: [String: Any]
        if let nested = vdf["\(appID)"] as? [String: Any] {
            appInfo = nested
        } else if let nested = vdf["appinfo"] as? [String: Any] {
            appInfo = nested
        } else {
            appInfo = vdf
        }

        // Common section
        if let common = appInfo["common"] as? [String: Any] {
            info.name = common["name"] as? String ?? ""
            info.type = AppType(pics: common["type"] as? String ?? "")
            info.oslist = common["oslist"] as? String ?? ""
            info.freeToDownload = (common["freetodownload"] as? String) == "1"
            // Artwork names, English first, else any language.
            func asset(_ node: Any?) -> String? {
                guard let languages = node as? [String: Any] else { return nil }
                let value = (languages["english"] as? String) ?? languages.keys.sorted().compactMap { languages[$0] as? String }.first
                guard let value, !value.isEmpty, value.utf8.count <= 256, !value.contains(".."), !value.hasPrefix("/") else { return nil }
                return value
            }
            if let assets = common["library_assets_full"] as? [String: Any] {
                let capsule = assets["library_capsule"] as? [String: Any]
                info.libraryCapsule = asset(capsule?["image2x"]) ?? asset(capsule?["image"])
                info.libraryHero = asset((assets["library_hero"] as? [String: Any])?["image"])
            }
            info.headerImage = asset(common["header_image"])
            if let parent = (common["parent"] as? String).flatMap(UInt32.init), parent != 0, parent != info.appID {
                info.parentID = parent
            }
        }

        // Config section
        if let config = appInfo["config"] as? [String: Any] {
            info.installDir = config["installdir"] as? String ?? ""
            if let launch = config["launch"] as? [String: Any] {
                info.launches = SteamLaunchOption.parse(launch)
            }
        }

        // Depots section
        if let depots = appInfo["depots"] as? [String: Any] {
            for (key, depotData) in depots {
                guard let depotID = UInt32(key),
                      let depot = depotData as? [String: Any] else { continue }

                var di = DepotInfo(depotID: depotID)
                di.name = depot["name"] as? String ?? ""
                if let config = depot["config"] as? [String: Any] {
                    di.oslist = config["oslist"] as? String ?? ""
                    di.osarch = config["osarch"] as? String ?? ""
                    di.language = config["language"] as? String ?? ""
                    di.lowViolence = (config["lowviolence"] as? String) == "1"
                }
                if let maxSizeStr = depot["maxsize"] as? String, let maxSize = UInt64(maxSizeStr) {
                    di.maxSize = maxSize
                } else if let maxSize = depot["maxsize"] as? UInt32 {
                    di.maxSize = UInt64(maxSize)
                }
                // Text VDF leaves every leaf as a String, so that is checked
                // first; the UInt32 branch serves any binary-VDF caller.
                if let dlcStr = depot["dlcappid"] as? String, let dlc = UInt32(dlcStr) {
                    di.dlcAppID = dlc
                } else if let dlc = depot["dlcappid"] as? UInt32 {
                    di.dlcAppID = dlc
                }
                di.isSharedInstall = (depot["sharedinstall"] as? String) == "1"
                if let from = (depot["depotfromapp"] as? String).flatMap(UInt32.init), from != appID {
                    di.fromApp = from
                }
                if let manifests = depot["manifests"] as? [String: Any] {
                    for (branch, entry) in manifests {
                        if let gidStr = entry as? String, let gid = UInt64(gidStr) {
                            // Legacy flat format: branch -> gid string.
                            di.manifests[branch] = gid
                        } else if let gid = entry as? UInt64 {
                            di.manifests[branch] = gid
                        } else if let dict = entry as? [String: Any] {
                            // Modern format (2023+): branch -> { gid, size, download }.
                            // Most apps carry their sizes here now.
                            if let gidStr = dict["gid"] as? String, let gid = UInt64(gidStr) {
                                di.manifests[branch] = gid
                            }
                            if branch == "public" {
                                if let dStr = dict["download"] as? String, let d = UInt64(dStr) {
                                    di.publicDownloadBytes = d
                                }
                                if let sStr = dict["size"] as? String, let s = UInt64(sStr) {
                                    di.publicSizeBytes = s
                                }
                            }
                        }
                    }
                }
                info.depots.append(di)
            }

            // Build ID
            if let branches = depots["branches"] as? [String: Any],
               let publicBranch = branches["public"] as? [String: Any] {
                if let buildIDStr = publicBranch["buildid"] as? String, let buildID = UInt32(buildIDStr) {
                    info.buildID = buildID
                } else if let buildID = publicBranch["buildid"] as? UInt32 {
                    info.buildID = buildID
                }
            }
        }

        // Auto-Cloud section. Untrusted text: bounded, and only ever used to
        // form paths below known folders (SteamCloud validates each one).
        if let ufs = appInfo["ufs"] as? [String: Any] {
            func text(_ value: Any?) -> String {
                guard let string = value as? String, string.utf8.count <= 512 else { return "" }
                return string
            }
            func entries(_ node: Any?) -> [[String: Any]] {
                guard let dict = node as? [String: Any] else { return [] }
                return dict.keys.compactMap { key in Int(key).map { ($0, key) } }.sorted { $0.0 < $1.0 }
                    .prefix(64).compactMap { dict[$0.1] as? [String: Any] }
            }
            for entry in entries(ufs["savefiles"]) {
                let platforms = (entry["platforms"] as? [String: Any])?.values.compactMap { ($0 as? String)?.lowercased() } ?? []
                info.saveFiles.append(SaveFile(root: text(entry["root"]), path: text(entry["path"]),
                                               pattern: text(entry["pattern"]),
                                               recursive: (entry["recursive"] as? String) == "1",
                                               platforms: platforms.sorted()))
            }
            for entry in entries(ufs["rootoverrides"]) {
                info.rootOverrides.append(RootOverride(root: text(entry["root"]), os: text(entry["os"]),
                                                       useInstead: text(entry["useinstead"]), addPath: text(entry["addpath"])))
            }
        }

        guard !info.name.isEmpty else { return nil }

        return info
    }
}

/// One entry of an app's launch configuration (`config.launch.<n>` in its
/// product info): the program Valve's client would start, relative to the
/// install folder as Steam spells it, its arguments and working folder, the
/// entry's type and the platform, architecture and beta branch it is for.
/// Untrusted text: bounded here, and validated as a path by SteamDirectStart.
struct SteamLaunchOption: Codable, Hashable, Sendable {
    var executable: String
    /// The config.launch key, not the position in the filtered array. Nil in old caches.
    var index: UInt32? = nil
    var requiredDLC: String? = nil
    var arguments = ""
    var workingDir = ""
    /// "default", "none", "option1", "server", "editor", "vr", ... ("" when absent).
    var type = ""
    var oslist = ""
    var osarch = ""
    var betaKey = ""

    /// Entries in Steam's order (numeric keys), without those that name no
    /// program or carry oversized text; at most 32.
    static func parse(_ launch: [String: Any]) -> [SteamLaunchOption] {
        let keys: [(UInt32, String)] = launch.keys.compactMap { key in
            guard let index = UInt32(key), index <= UInt32(Int32.max) else { return nil }
            return (index, key)
        }.sorted { $0.0 < $1.0 }
        var options: [SteamLaunchOption] = []
        for (index, key) in keys.prefix(32) {
            guard let entry = launch[key] as? [String: Any], let executable = entry["executable"] as? String,
                  !executable.isEmpty, executable.utf8.count <= 512 else { continue }
            func text(_ value: Any?, limit: Int = 256) -> String? {
                guard let value else { return "" }
                guard let string = value as? String, string.utf8.count <= limit else { return nil }
                return string
            }
            let config = entry["config"] as? [String: Any] ?? [:]
            guard let arguments = text(entry["arguments"], limit: 2048), let workingDir = text(entry["workingdir"], limit: 512),
                  let type = text(entry["type"]), let oslist = text(config["oslist"]), let osarch = text(config["osarch"]),
                  let betaKey = text(config["betakey"]), let requiredDLC = text(config["ownsdlc"]) else { continue }
            options.append(SteamLaunchOption(executable: executable, index: index, requiredDLC: requiredDLC.isEmpty ? nil : requiredDLC,
                                             arguments: arguments, workingDir: workingDir,
                                             type: type, oslist: oslist, osarch: osarch, betaKey: betaKey))
        }
        return options
    }
}

#endif


#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Fetches the owned games list via Steam's product info service (PICS).
@MainActor
class SteamLibraryFetcher {
    private let session: SteamCMSession

    init(session: SteamCMSession) {
        self.session = session
    }

    // MARK: - Fetch Owned Games

    /// Fetches the account's package IDs from the license list, resolves them
    /// to app IDs and returns the playable apps' metadata.
    func fetchOwnedApps() async throws -> [SteamAppInfo] {
        try await session.ensureConnected()

        // Step 1: the license list (owned packages).
        SteamLog.trace("Fetching license list...")
        let packageIDs = try await fetchLicenseList()
        SteamLog.trace("Got \(packageIDs.count) owned packages")

        // Step 2: PICS access tokens for the packages.
        let packageTokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)

        // Step 3: package info, to extract the app IDs.
        let appIDs = try await fetchAppIDsFromPackages(packageIDs: packageIDs, tokens: packageTokens)
        SteamLog.trace("Found \(appIDs.count) unique app IDs")

        // Step 4: PICS access tokens for the apps.
        let appTokens = try await fetchPICSAccessTokens(appIDs: Array(appIDs))

        // Step 5: app info (name, depots, platform support, ...).
        let appInfos = try await fetchAppInfo(appIDs: Array(appIDs), tokens: appTokens)
        SteamLog.trace("Got info for \(appInfos.count) apps")

        // Playable types only: games, demos and applications. This leaves out
        // DLC, soundtracks and tools (redistributables, runtimes, SDKs, servers).
        let games = appInfos.filter { $0.type.isPlayable }
        SteamLog.trace("\(games.count) of \(appInfos.count) apps are playable (game/demo/application)")
        return games
    }

    /// Depot IDs included in the account's licenses, from the same package
    /// info the library uses (`depotids`). The installer consults it only when
    /// Steam refuses a depot key, to leave out a depot the account does not
    /// own (another edition, extra content). Cached per session.
    private var ownedDepotCache: Set<UInt32>?
    func ownedDepotIDs() async throws -> Set<UInt32> {
        if let cached = ownedDepotCache { return cached }
        try await session.ensureConnected()
        let packageIDs = try await fetchLicenseList()
        let tokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)
        var depots = Set<UInt32>()
        for start in stride(from: 0, to: packageIDs.count, by: 50) {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = packageIDs[start..<min(start + 50, packageIDs.count)].map {
                CMsgClientPICSProductInfoRequest.PackageInfo(packageid: $0, accessToken: tokens[$0] ?? 0)
            }
            let responses = try await session.sendAndWaitPICS(eMsg: .clientPICSProductInfoRequest,
                                                              body: request.serialize(), timeout: 30)
            for response in responses {
                let pics = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in pics.packages { depots.formUnion(VDFParser.parsePackageIDs(key: "depotids", from: pkg.buffer)) }
            }
        }
        ownedDepotCache = depots
        return depots
    }

    /// Fetches PICS info for a single app on demand: one token round trip and
    /// one product-info round trip, no license list. Connects the session if it
    /// sits idle-disconnected.
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? {
        try await session.ensureConnected()
        let tokens = try await fetchPICSAccessTokens(appIDs: [appID])
        return try await fetchAppInfo(appIDs: [appID], tokens: tokens).first
    }

    // MARK: - Install metadata

    /// The app's metadata for an install, with the content metadata of the
    /// apps it shares depots with resolved. This never supplies depot keys or
    /// grants access: every later content request still goes to Valve.
    func fetchInstallInfo(appID: UInt32, cached: SteamAppInfo? = nil) async throws -> SteamAppInfo? {
        try Task.checkCancellation()
        let metadata: SteamAppInfo?
        if let cached, cached.appID == appID, !cached.depots.isEmpty {
            metadata = cached
        } else {
            metadata = try await fetchAppInfo(appID: appID)
        }
        guard var app = metadata else { return nil }
        try Task.checkCancellation()
        var owners: [UInt32: SteamAppInfo] = [appID: app]
        var visited: Set<UInt32> = [appID], references = Set<String>()
        func eligible(_ d: SteamAppInfo.DepotInfo) -> Bool {
            !d.isSharedInstall && d.dlcAppID == nil && d.supports(os: "windows") &&
                !d.lowViolence && (d.language.isEmpty || d.language.lowercased() == "english")
        }
        var pending = app.depots.filter { eligible($0) && $0.publicManifestID == nil && $0.fromApp != nil }
            .map { ($0.fromApp!, $0.depotID) }
        while let (id, depotID) = pending.popLast() {
            try Task.checkCancellation()
            if !references.insert("\(id):\(depotID)").inserted { continue }
            guard references.count <= 1024 else { throw SteamFileError.invalid("Too many shared content references.") }
            if visited.insert(id).inserted {
                guard visited.count <= 32 else { throw SteamFileError.invalid("Too many shared content dependencies.") }
                owners[id] = try await fetchAppInfo(appID: id)
            }
            if let source = owners[id]?.depots.first(where: { $0.depotID == depotID }),
               source.publicManifestID == nil, let next = source.fromApp {
                pending.append((next, depotID))
            }
        }
        // A bounded fixed point handles nested sharing without recursion or cycles.
        try Task.checkCancellation()
        for _ in 0..<owners.count {
            var changed = 0
            for id in owners.keys.sorted() {
                var owner = owners[id]!
                changed += owner.inheritDepots(from: owners)
                owners[id] = owner
            }
            if changed == 0 { break }
        }
        let resolved = app.inheritDepots(from: owners)
        let missing = app.depots.filter { eligible($0) && $0.fromApp != nil && $0.publicManifestID == nil }
        SteamLog.event("[steam-shared] app=\(appID) owners=\(visited.count - 1) resolved=\(resolved) missing=\(missing.count)")
        guard missing.isEmpty else { throw SteamFileError.invalid("Steam did not provide required shared content metadata. Refresh and retry the download.") }
        // The direct owner of each selected shared depot, for its install
        // record. Metadata only; Valve still decides access and launch readiness.
        for id in Set(app.installDepots().compactMap(\.fromApp)).subtracting([appID]).sorted() {
            try Task.checkCancellation()
            if owners[id] == nil {
                guard owners.count <= 64 else { break }
                owners[id] = try await fetchAppInfo(appID: id)
            }
            if let owner = owners[id] {
                app.sharedOwners[id] = .init(name: owner.name, installDir: owner.installDir, buildID: owner.buildID)
            }
        }
        return app
    }

    // MARK: - License List

    private func fetchLicenseList() async throws -> [UInt32] {
        try await session.awaitLicenseList(timeout: 15)
    }

    // MARK: - PICS Access Tokens

    private func fetchPICSAccessTokens(appIDs: [UInt32] = [], packageIDs: [UInt32] = []) async throws -> [UInt32: UInt64] {
        var request = CMsgClientPICSAccessTokenRequest()
        request.appids = appIDs
        request.packageids = packageIDs

        let response = try await session.sendAndWait(
            eMsg: .clientPICSAccessTokenRequest,
            body: request.serialize(),
            responseEMsg: .clientPICSAccessTokenResponse,
            timeout: 30
        )

        let tokenResponse = try CMsgClientPICSAccessTokenResponse.deserialize(from: response.body)

        var tokens: [UInt32: UInt64] = [:]
        for appToken in tokenResponse.appAccessTokens {
            tokens[appToken.appid] = appToken.accessToken
        }
        for pkgToken in tokenResponse.packageAccessTokens {
            tokens[pkgToken.packageid] = pkgToken.accessToken
        }

        return tokens
    }

    // MARK: - Package Info → App IDs

    private func fetchAppIDsFromPackages(packageIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> Set<UInt32> {
        var allAppIDs = Set<UInt32>()

        // Package info requests in batches of 50.
        let batches = stride(from: 0, to: packageIDs.count, by: 50).map {
            Array(packageIDs[$0..<min($0 + 50, packageIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = batch.map { pkgID in
                CMsgClientPICSProductInfoRequest.PackageInfo(
                    packageid: pkgID,
                    accessToken: tokens[pkgID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in picsResponse.packages {
                    allAppIDs.formUnion(VDFParser.parsePackageAppIDs(from: pkg.buffer))
                }
            }
        }

        return allAppIDs
    }

    // MARK: - App Info

    private func fetchAppInfo(appIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> [SteamAppInfo] {
        var allApps: [SteamAppInfo] = []

        // App info requests in batches of 50.
        let batches = stride(from: 0, to: appIDs.count, by: 50).map {
            Array(appIDs[$0..<min($0 + 50, appIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.apps = batch.map { appID in
                CMsgClientPICSProductInfoRequest.AppInfo(
                    appid: appID,
                    accessToken: tokens[appID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for app in picsResponse.apps {
                    if let info = SteamAppInfo.parse(appID: app.appid, from: app.buffer) {
                        allApps.append(info)
                    }
                }
            }
        }

        return allApps
    }
}

// MARK: - Simple VDF Binary Parser

/// Parses Valve Data Format (binary) used in PICS responses
enum VDFParser {
    // VDF binary types
    private static let typeNone: UInt8 = 0x00
    private static let typeString: UInt8 = 0x01
    private static let typeInt32: UInt8 = 0x02
    private static let typeEnd: UInt8 = 0x08

    /// Parse a text-format VDF / KeyValues blob into a nested dictionary.
    /// Steam PICS sends *app* product info in this text format (`"key" "value"`
    /// pairs and `"key" { ... }` sections) — package info uses the binary
    /// format. Leaf values are always `String`. Steam escapes `"` and `\` inside
    /// a quoted string (for example a launch argument `/Name=\"Two Words\"`); read
    /// verbatim, such a string ends early and every later section, the depots
    /// among them, is lost.
    static func parseTextVDF(from data: Data) -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        func skipWhitespaceAndComments() {
            while i < n {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                } else if c == "/" && i + 1 < n && scalars[i + 1] == "/" {
                    while i < n && scalars[i] != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        func nextToken() -> String? {
            skipWhitespaceAndComments()
            guard i < n else { return nil }
            let c = scalars[i]
            if c == "{" || c == "}" {
                i += 1
                return String(c)
            }
            var s = ""
            if c == "\"" {
                i += 1
                while i < n && scalars[i] != "\"" {
                    // \" and \\ are escapes; any other backslash is literal (paths).
                    if scalars[i] == "\\", i + 1 < n, scalars[i + 1] == "\"" || scalars[i + 1] == "\\" {
                        s.unicodeScalars.append(scalars[i + 1])
                        i += 2
                        continue
                    }
                    s.unicodeScalars.append(scalars[i])
                    i += 1
                }
                i += 1 // closing quote
                return s
            }
            while i < n {
                let ch = scalars[i]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
                    || ch == "{" || ch == "}" || ch == "\"" { break }
                s.unicodeScalars.append(ch)
                i += 1
            }
            return s
        }

        func parseSection() -> [String: Any] {
            var dict: [String: Any] = [:]
            while let key = nextToken() {
                if key == "}" { break }
                if key == "{" { continue }
                guard let value = nextToken() else { break }
                if value == "{" {
                    dict[key] = parseSection()
                } else if value == "}" {
                    break
                } else {
                    dict[key] = value
                }
            }
            return dict
        }

        return parseSection()
    }

    /// Extract app IDs from a binary VDF package info buffer
    static func parsePackageAppIDs(from data: Data) -> [UInt32] {
        parsePackageIDs(key: "appids", from: data)
    }

    /// The same scan for any id list in a package ("appids", "depotids").
    static func parsePackageIDs(key searchKey: String, from data: Data) -> [UInt32] {
        var appIDs: [UInt32] = []
        var offset = 0

        // Look for the requested section and extract UInt32 values
        // This is a simplified parser that searches for known patterns
        if let range = findKey(searchKey, in: data) {
            offset = range
            // After "appids" key, we expect sub-keys with numeric names and uint32 values
            while offset < data.count {
                guard offset < data.count else { break }
                let type = data[offset]
                offset += 1

                if type == typeEnd { break }

                // Read key name (null-terminated string)
                guard let (_, newOffset) = readNullTerminatedString(from: data, at: offset) else { break }
                offset = newOffset

                if type == typeInt32 {
                    guard offset + 4 <= data.count else { break }
                    let value = data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                    appIDs.append(UInt32(littleEndian: value))
                    offset += 4
                } else if type == typeString {
                    guard let (_, newOff) = readNullTerminatedString(from: data, at: offset) else { break }
                    offset = newOff
                } else if type == typeNone {
                    // Sub-section - skip or recurse
                    continue
                }
            }
        }

        return appIDs
    }

    private static func findKey(_ key: String, in data: Data) -> Int? {
        let keyBytes = Array(key.utf8) + [0] // null-terminated
        let keyData = Data(keyBytes)
        guard data.count >= keyData.count else { return nil }

        for i in 0..<(data.count - keyData.count) {
            if data[i..<i + keyData.count] == keyData {
                return i + keyData.count
            }
        }
        return nil
    }

    private static func readNullTerminatedString(from data: Data, at offset: Int) -> (String, Int)? {
        var end = offset
        while end < data.count && data[end] != 0 {
            end += 1
        }
        guard end < data.count else { return nil }
        let str = String(data: data[offset..<end], encoding: .utf8) ?? ""
        return (str, end + 1)
    }
}

#endif


#if os(iOS)
enum SteamFileError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

@MainActor
final class SteamOwnedGamesModel: ObservableObject {
    @Published private(set) var games: [SteamAppInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var installingApps: Set<UInt32> = []
    @Published private(set) var downloadProgress: [UInt32: SteamDownloadProgress] = [:]
    @Published private(set) var downloadErrors: [UInt32: String] = [:]
    @Published private(set) var installedApps: Set<UInt32> = []
    @Published private(set) var availableDLC: [UInt32: [UInt32]] = [:]
    @Published private(set) var dlcMetadata: [UInt32: SteamAppInfo] = [:]
    @Published private(set) var installedDLC: [UInt32: Set<UInt32>] = [:]
    @Published private(set) var cancellingApps: Set<UInt32> = []
    @Published private(set) var installingDLC: [UInt32: UInt32] = [:]
    @Published private(set) var cancellingDLC: Set<UInt32> = []
    @Published private(set) var cloudMessages: [UInt32: String] = [:]
    @Published private(set) var cloudConflicts: Set<UInt32> = []
    @Published private(set) var cloudSyncing: Set<UInt32> = []

    private var installTasks: [UInt32: Task<Void, Never>] = [:]
    private var dlcTasks: [UInt32: Task<Void, Never>] = [:]
    private var lastRefresh: Date?
    private var lastAccountName: String?
    private let session = SteamSession()
    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private lazy var cloudEngine = SteamCloudSyncEngine(session: session)

    /// Display a lightweight cached library immediately while PICS refreshes.
    /// Cached preview entries contain no depot metadata: installing a game
    /// still requires fresh Steam metadata and authorization.
    func refresh(force: Bool = false) async {
        guard SteamSignIn.isSignedIn, let account = SteamSignIn.accountName,
              !account.isEmpty else {
            games = []
            lastAccountName = nil
            lastRefresh = nil
            errorMessage = nil
            return
        }
        guard !isLoading else { return }
        if lastAccountName != account {
            games = []
            lastRefresh = nil
            lastAccountName = account
        }
        if !force, !games.isEmpty, let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < 120 {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if games.isEmpty {
            let preview = await Task.detached(priority: .utility) {
                SteamLibraryPreviewCache.load(account: account)
            }.value
            guard SteamSignIn.accountName == account else { return }
            if let preview {
                games = preview.map { cached in
                    var app = SteamAppInfo(appID: cached.appID)
                    app.name = cached.name
                    app.type = SteamAppInfo.AppType(pics: cached.type)
                    app.installDir = cached.installDir
                    app.oslist = cached.oslist
                    app.buildID = cached.buildID
                    app.libraryCapsule = cached.libraryCapsule
                    app.libraryHero = cached.libraryHero
                    app.headerImage = cached.headerImage
                    app.parentID = cached.parentID
                    return app
                }
                SteamLog.event("[steam-library] loaded \(games.count) cached game previews")
            }
        }

        do {
            let fresh = try await fetcher.fetchOwnedApps().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            guard SteamSignIn.accountName == account else { return }
            games = fresh
            lastRefresh = Date()
            lastAccountName = account
            let previews = fresh.map { game in
                SteamLibraryCachedGame(
                    appID: game.appID, name: game.name,
                    type: game.type.rawValue, installDir: game.installDir,
                    oslist: game.oslist, buildID: game.buildID,
                    libraryCapsule: game.libraryCapsule,
                    libraryHero: game.libraryHero,
                    headerImage: game.headerImage, parentID: game.parentID
                )
            }
            Task.detached(priority: .utility) {
                SteamLibraryPreviewCache.save(account: account, games: previews)
            }
        } catch {
            guard SteamSignIn.accountName == account else { return }
            errorMessage = SteamSignIn.message(error)
        }
    }

    func loadDLC(appID: UInt32) async {
        do {
            let info: SteamAppInfo?
            if let cached = games.first(where: { $0.appID == appID }) {
                info = cached
            } else {
                info = try await fetcher.fetchInstallInfo(appID: appID)
            }
            guard let info else {
                availableDLC[appID] = []
                return
            }
            guard info.appID == appID else {
                availableDLC[appID] = []
                return
            }
            let ids = Array(Set(info.depots.compactMap { depot -> UInt32? in
                guard depot.publicManifestID != nil,
                      depot.supports(os: "windows"),
                      let dlc = depot.dlcAppID,
                      dlc != appID else { return nil }
                return dlc
            })).sorted()
            availableDLC[appID] = ids
            for id in ids.prefix(32) where dlcMetadata[id] == nil {
                if let details = try? await fetcher.fetchAppInfo(appID: id), details.appID == id {
                    dlcMetadata[id] = details
                }
            }
        } catch {
            availableDLC[appID] = []
        }
    }

    func startInstall(appID: UInt32, prefixPath: URL) {
        guard installTasks[appID] == nil else { return }
        installTasks[appID] = Task { @MainActor in
            await self.install(appID: appID, prefixPath: prefixPath)
            self.installTasks.removeValue(forKey: appID)
            self.cancellingApps.remove(appID)
        }
    }

    func canCancelInstall(appID: UInt32) -> Bool {
        installTasks[appID] != nil
    }

    func cancelInstall(appID: UInt32) {
        guard let task = installTasks[appID] else { return }
        cancellingApps.insert(appID)
        task.cancel()
    }

    func startDLCInstall(appID: UInt32, dlcAppID: UInt32, prefixPath: URL) {
        guard dlcTasks[appID] == nil, !installingApps.contains(appID) else { return }
        installingDLC[appID] = dlcAppID
        dlcTasks[appID] = Task { @MainActor in
            await installDLC(appID: appID, dlcAppID: dlcAppID, prefixPath: prefixPath)
            dlcTasks.removeValue(forKey: appID)
            installingDLC.removeValue(forKey: appID)
            cancellingDLC.remove(dlcAppID)
        }
    }

    func cancelDLCInstall(appID: UInt32, dlcAppID: UInt32) {
        guard installingDLC[appID] == dlcAppID, let task = dlcTasks[appID] else { return }
        cancellingDLC.insert(dlcAppID)
        task.cancel()
    }

    func syncCloud(appID: UInt32, prefixPath: URL) async {
        guard !cloudSyncing.contains(appID), SteamSignIn.isSignedIn else { return }
        cloudSyncing.insert(appID)
        cloudMessages[appID] = "Sincronizando saves com a Steam..."
        defer { cloudSyncing.remove(appID) }
        do {
            guard let info = games.first(where: { $0.appID == appID }) else {
                throw SteamFileError.invalid("O jogo não está disponível na biblioteca Steam.")
            }
            let result = try await cloudEngine.sync(
                appID: appID, info: info, prefixPath: prefixPath)
            cloudMessages[appID] = result.message
            if result.conflicts > 0 {
                cloudConflicts.insert(appID)
            } else {
                cloudConflicts.remove(appID)
            }
        } catch {
            cloudMessages[appID] = "Steam Cloud: " + SteamSignIn.message(error)
        }
    }

    func resolveCloud(appID: UInt32, prefixPath: URL, preferCloud: Bool) async {
        guard !cloudSyncing.contains(appID), SteamSignIn.isSignedIn else { return }
        cloudSyncing.insert(appID)
        defer { cloudSyncing.remove(appID) }
        do {
            guard let info = games.first(where: { $0.appID == appID }) else {
                throw SteamFileError.invalid("O jogo não está disponível na biblioteca Steam.")
            }
            let result = try await cloudEngine.resolve(
                appID: appID, info: info, prefixPath: prefixPath, preferCloud: preferCloud)
            cloudMessages[appID] = result.message
            if result.conflicts == 0 { cloudConflicts.remove(appID) }
        } catch {
            cloudMessages[appID] = SteamSignIn.message(error)
        }
    }

    func refreshInstalledDLC(appID: UInt32, prefixPath: URL) {
        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        let ids = availableDLC[appID] ?? []
        installedDLC[appID] = Set(ids.filter {
            SteamDLCRecords.isInstalled(parentID: appID, dlcID: $0, steamApps: steamApps)
        })
    }

    func uninstallDLC(appID: UInt32, dlcAppID: UInt32, prefixPath: URL) -> Bool {
        guard availableDLC[appID]?.contains(dlcAppID) == true,
              !installingApps.contains(appID) else { return false }
        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        let removed = SteamDLCRecords.uninstall(parentID: appID, dlcID: dlcAppID,
                                                 steamApps: steamApps)
        refreshInstalledDLC(appID: appID, prefixPath: prefixPath)
        return removed
    }

    func refreshInstalledApps(prefixPath: URL) {
        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: steamApps.path)) ?? []
        installedApps = Set(names.compactMap { filename -> UInt32? in
            guard filename.hasPrefix("appmanifest_"), filename.hasSuffix(".acf") else { return nil }
            return UInt32(filename.dropFirst("appmanifest_".count).dropLast(4))
        })
    }

    func isInstalled(appID: UInt32, prefixPath: URL) -> Bool {
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        return SteamInstallFiles.buildID(appID: Int(appID), steamApps: steamApps) != nil
    }

    func uninstall(appID: UInt32, prefixPath: URL) -> Bool {
        guard let app = games.first(where: { $0.appID == appID }),
              !app.installDir.isEmpty else {
            downloadErrors[appID] = "Steam install metadata is missing. Refresh the library before uninstalling."
            return false
        }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        SteamInstallFiles.delete(appID: Int(appID), folderName: app.installDir, steamApps: steamApps)
        installedApps.remove(appID)
        downloadProgress.removeValue(forKey: appID)
        installingApps.remove(appID)
        downloadErrors.removeValue(forKey: appID)
        return !isInstalled(appID: appID, prefixPath: prefixPath)
    }

    func install(appID: UInt32, prefixPath: URL) async {
        guard !installingApps.contains(appID) else { return }
        guard SteamSignIn.isSignedIn else {
            downloadErrors[appID] = "Sign in to install Steam games."
            return
        }
        installingApps.insert(appID)
        downloadErrors[appID] = nil
        downloadProgress[appID] = SteamDownloadProgress()
        defer { installingApps.remove(appID) }
        var installFolder: String?
        var installFolderAlreadyExisted = false
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        let wasInstalled = isInstalled(appID: appID, prefixPath: prefixPath)
        do {
            try Task.checkCancellation()
            guard let app = try await fetcher.fetchInstallInfo(
                appID: appID, cached: games.first(where: { $0.appID == appID })) else {
                throw SteamError.depotNotFound(appID)
            }
            installFolder = SteamInstallFiles.safeFolderName(
                app.installDir.isEmpty ? "app_\(app.appID)" : app.installDir)
            if let installFolder {
                installFolderAlreadyExisted = FileManager.default.fileExists(atPath:
                    steamApps.appendingPathComponent("common", isDirectory: true)
                        .appendingPathComponent(installFolder, isDirectory: true).path)
            }
            guard app.installableOnWindows else {
                throw SteamError.depotNotFound(appID)
            }
            try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
            _ = try await downloader.install(
                app,
                steamApps: steamApps,
                ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() },
                progress: { [weak self] progress in
                    self?.downloadProgress[appID] = progress
                }
            )
            try Task.checkCancellation()
            installedApps.insert(appID)
            downloadErrors[appID] = nil
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            if cancelled, !wasInstalled {
                if !installFolderAlreadyExisted, let installFolder {
                    SteamInstallFiles.delete(appID: Int(appID), folderName: installFolder,
                                             steamApps: steamApps)
                } else {
                    try? FileManager.default.removeItem(at:
                        steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
                }
            }
            downloadProgress.removeValue(forKey: appID)
            downloadErrors[appID] = cancelled ? nil : SteamSignIn.message(error)
        }
    }

    func installDLC(appID: UInt32, dlcAppID: UInt32, prefixPath: URL) async {
        guard isInstalled(appID: appID, prefixPath: prefixPath) else {
            downloadErrors[appID] = "Install this game before installing its DLC."
            return
        }
        guard !installingApps.contains(appID) else { return }
        guard SteamSignIn.isSignedIn else {
            downloadErrors[appID] = "Sign in to install Steam games."
            return
        }
        installingApps.insert(appID)
        downloadErrors[appID] = nil
        downloadProgress[appID] = SteamDownloadProgress()
        defer { installingApps.remove(appID) }
        do {
            try Task.checkCancellation()
            guard let app = try await fetcher.fetchInstallInfo(
                appID: appID, cached: games.first(where: { $0.appID == appID })),
                  app.appID == appID,
                  app.installableOnWindows,
                  availableDLC[appID]?.contains(dlcAppID) == true,
                  app.depots.contains(where: {
                      $0.dlcAppID == dlcAppID &&
                      $0.publicManifestID != nil &&
                      $0.supports(os: "windows")
                  }) else {
                throw SteamError.depotNotFound(dlcAppID)
            }
            let steamApps = SteamInstallPaths.steamApps(
                drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
            try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
            _ = try await downloader.install(app, steamApps: steamApps,
                ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() },
                includedDLC: [dlcAppID],
                dlcOnly: true,
                progress: { [weak self] progress in self?.downloadProgress[appID] = progress })
            try Task.checkCancellation()
            installedApps.insert(appID)
            refreshInstalledDLC(appID: appID, prefixPath: prefixPath)
        } catch {
            if Task.isCancelled || error is CancellationError {
                downloadErrors[appID] = nil
                downloadProgress.removeValue(forKey: appID)
            } else {
                downloadErrors[appID] = SteamSignIn.message(error)
            }
        }
    }

    func disconnect() {
        for task in dlcTasks.values { task.cancel() }
        dlcTasks.removeAll()
        installingDLC.removeAll()
        cancellingDLC.removeAll()
        cloudMessages.removeAll()
        cloudConflicts.removeAll()
        for task in installTasks.values { task.cancel() }
        installTasks.removeAll()
        lastRefresh = nil
        lastAccountName = nil
        availableDLC.removeAll()
        installedDLC.removeAll()
        dlcMetadata.removeAll()
        games = []
        errorMessage = nil
        downloadErrors = [:]
        Task { await session.disconnectGracefully() }
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
