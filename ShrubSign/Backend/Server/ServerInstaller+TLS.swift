//
//  ServerInstaller+TLS.swift
//  ShrubSign
//
//  Originally created by samara on 22.08.2024 for feather.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR SHRUBSIGN
//
//  Device-local TLS. ShrubSign generates its own certificate authority and a
//  server certificate for 127.0.0.1, writes a trust profile, and verifies with
//  the system trust store that the pair is actually trusted before an offline
//  install is attempted.
//

import Foundation
import Security
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - TLS/Setup
extension ServerInstaller {
    private static let env: Environment = {
        var env = try! Environment.detect()
        try! LoggingSystem.bootstrap(from: &env)
        return env
    }()

    static func setupApp(port: Int, secure: Bool) throws -> Application {
        let app = Application(env)
        app.threadPool = .init(numberOfThreads: 1)

        if secure {
            // Do not silently launch a plain HTTP server whose manifest claims
            // to use HTTPS. Surface the incomplete Fully Local setup instead.
            guard let tls = try Self.tls() else {
                throw ShrubInstallError.secureServerUnavailable
            }
            app.http.server.configuration.tlsConfiguration = tls
        }

        // Both listeners are reachable by this device. The plain HTTP listener
        // also serves the install page and the payload, so it binds broadly;
        // the payload path contains a random UUID and lives only while the
        // installation sheet is open.
        let bindingAddress = "0.0.0.0"
        app.http.server.configuration.hostname = bindingAddress
        app.http.server.configuration.tcpNoDelay = true
        app.http.server.configuration.address = .hostname(bindingAddress, port: port)
        app.http.server.configuration.port = port
        app.routes.defaultMaxBodySize = "128mb"
        app.routes.caseInsensitive = false

        return app
    }

    // MARK: - Hosts
    /// Live value: users can switch methods without reinstalling the app.
    static var localHost: String {
        if allowLocalNetworkInstall(), let address = getLocalAddress() {
            return address
        }
        return "127.0.0.1"
    }

    /// Host name used by the HTTPS manifest. Device-generated certificates are
    /// always issued for 127.0.0.1; imported certificate packs keep their own
    /// common name so older setups keep working.
    static var sni: String {
        if PersonalSSL.hasDeviceLocalIdentity { return PersonalSSL.host }
        if let commonName = readCommonName(), !commonName.isEmpty { return commonName }
        return PersonalSSL.host
    }

    static func tls() throws -> TLSConfiguration? {
        guard
            let crt = getUrl("server", ext: "crt"),
            let pem = getUrl("server", ext: "pem")
        else {
            return nil
        }

        let certificates = try NIOSSLCertificate.fromPEMFile(crt.path)
        guard !certificates.isEmpty else { return nil }

        return try TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { NIOSSLCertificateSource.certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: pem.path, format: .pem))
        )
    }

    static func readCommonName() -> String? {
        guard let url = getUrl("commonName", ext: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - File locations
extension ServerInstaller {
    static func getUrl(_ name: String, ext: String) -> URL? {
        let fileManager = FileManager.default

        let serverURL = PersonalSSL.directory.appendingPathComponent("\(name).\(ext)")
        if fileManager.fileExists(atPath: serverURL.path) {
            return serverURL
        }

        let documentsURL = URL.documentsDirectory.appendingPathComponent("\(name).\(ext)")
        if fileManager.fileExists(atPath: documentsURL.path) {
            return documentsURL
        }

        let oldServerURL = URL.documentsDirectory.appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
        if fileManager.fileExists(atPath: oldServerURL.path) {
            return oldServerURL
        }

        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    static func getLocalAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        if getifaddrs(&ifaddr) == 0 {
            var pointer = ifaddr
            while pointer != nil {
                let interface = pointer!.pointee
                let addrFamily = interface.ifa_addr.pointee.sa_family

                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "pdp_ip0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            interface.ifa_addr,
                            socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            socklen_t(0),
                            NI_NUMERICHOST
                        ) == 0 {
                            address = String(cString: hostname)
                        }
                    }
                }
                pointer = pointer!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }

        return address
    }
}

// MARK: - Personal SSL
/// The device-local certificate authority and server certificate used by Fully
/// Local installation. Kept intentionally small: one RSA key pair, one
/// certificate for 127.0.0.1, and one trust profile the user installs once.
enum PersonalSSL {
    static let host = "127.0.0.1"
    static let directory = URL.documentsDirectory.appendingPathComponent("App/Server", isDirectory: true)
    static let profileName = "ShrubSign-Local-Trust.mobileconfig"

    static var profileURL: URL? {
        let url = directory.appendingPathComponent(profileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var existingProfile: URL? { profileURL }

    static var hasCredentials: Bool {
        ["server.crt", "server.pem", "commonName.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// True only when the credentials were generated on this device, because
    /// only those are issued for 127.0.0.1.
    static var hasDeviceLocalIdentity: Bool {
        hasCredentials && profileURL != nil
    }

    /// Generates credentials the first time they are needed. Safe to call often.
    @discardableResult
    static func ensureCredentials() -> Bool {
        if hasCredentials { return true }
        return (try? generate()) != nil
    }

    /// Evaluates the server certificate against the system trust store,
    /// including roots the user installed and explicitly trusted.
    static func isTrusted() -> Bool {
        let certificates = loadCertificates()
        guard !certificates.isEmpty else { return false }
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func loadCertificates() -> [SecCertificate] {
        guard let pem = try? String(
            contentsOf: directory.appendingPathComponent("server.crt"),
            encoding: .utf8
        ) else {
            return []
        }
        return certificates(fromPEM: pem)
    }

    static func certificates(fromPEM pem: String) -> [SecCertificate] {
        var results: [SecCertificate] = []
        for block in pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
            guard let end = block.range(of: "-----END CERTIFICATE-----") else { continue }
            let base64 = block[..<end.lowerBound]
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard
                let data = Data(base64Encoded: base64),
                let certificate = SecCertificateCreateWithData(nil, data as CFData)
            else { continue }
            results.append(certificate)
        }
        return results
    }

    // MARK: - Generate
    @discardableResult
    static func generate() throws -> URL {
        let rootKey = try makeRSAKey()
        let leafKey = try makeRSAKey()
        guard let rootPublic = SecKeyCopyPublicKey(rootKey),
              let leafPublic = SecKeyCopyPublicKey(leafKey) else {
            throw failure("Could not read the generated public key.")
        }
        let rootSubject = name("ShrubSign Personal Local CA")
        let leafSubject = name("ShrubSign Local Installer")
        let root = try certificate(
            subject: rootSubject,
            issuer: rootSubject,
            publicKey: rootPublic,
            signingKey: rootKey,
            ca: true
        )
        let leaf = try certificate(
            subject: leafSubject,
            issuer: rootSubject,
            publicKey: leafPublic,
            signingKey: rootKey,
            ca: false
        )
        let leafPrivate = try export(leafKey)

        let rootPEM = pem("CERTIFICATE", root)
        let leafPEM = pem("CERTIFICATE", leaf)
        let keyPEM = pem("RSA PRIVATE KEY", leafPrivate)
        let profileURL = directory.appendingPathComponent(profileName)

        let rootPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "dev.shrubsign.local.ssl.root",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "ShrubSign Personal Local CA",
            "PayloadDescription": "Certificate authority used by this device to install apps through ShrubSign.",
            "PayloadCertificateFileName": "ShrubSign-Local-CA.cer",
            "PayloadContent": root
        ]

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "dev.shrubsign.local.ssl",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "ShrubSign Local Installation",
            "PayloadOrganization": "ShrubSign (this device only)",
            "PayloadDescription": "Lets ShrubSign install apps without an internet connection. Trust it in Settings → General → About → Certificate Trust Settings.",
            "PayloadContent": [rootPayload]
        ]

        let profileData = try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .xml,
            options: 0
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (leafPEM + rootPEM).write(
            to: directory.appendingPathComponent("server.crt"),
            atomically: true,
            encoding: .utf8
        )
        try keyPEM.write(
            to: directory.appendingPathComponent("server.pem"),
            atomically: true,
            encoding: .utf8
        )
        try "\(host)\n".write(
            to: directory.appendingPathComponent("commonName.txt"),
            atomically: true,
            encoding: .utf8
        )
        try profileData.write(to: profileURL, options: .atomic)
        // The CA private key is intentionally never persisted or shared.
        return profileURL
    }

    // MARK: - Helpers
    private static func failure(_ message: String) -> Error {
        NSError(
            domain: "ShrubSign.PersonalSSL",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func makeRSAKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw failure("RSA key generation failed.")
        }
        return key
    }

    private static func export(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw failure("Cannot export the private SSL key.")
        }
        return data
    }

    private static func certificate(
        subject: Data,
        issuer: Data,
        publicKey: SecKey,
        signingKey: SecKey,
        ca: Bool
    ) throws -> Data {
        let publicDER = try export(publicKey) // RSA PKCS#1 public key
        let rsaOID = oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
        let signatureAlgorithm = sequence(
            oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]) + Data([0x05, 0x00])
        )
        let publicInfo = sequence(sequence(rsaOID + Data([0x05, 0x00])) + bitString(publicDER))
        let now = Date()
        let validity = sequence(
            asnDate(now.addingTimeInterval(-86_400))
            + asnDate(now.addingTimeInterval(ca ? 5 * 365 * 86_400 : 350 * 86_400))
        )

        var serial = Data(repeating: 0, count: 16)
        guard serial.withUnsafeMutableBytes({ buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }) == errSecSuccess else {
            throw failure("Cannot generate a certificate serial.")
        }
        serial[0] &= 0x7f
        let serialNumber = der(0x02, serial)

        let basicConstraints = ext([0x55, 0x1d, 0x13], true,
                                   sequence(ca ? Data([0x01, 0x01, 0xff]) : Data()))
        let keyUsage = ext([0x55, 0x1d, 0x0f], true,
                           der(0x03, ca ? Data([0x01, 0x06]) : Data([0x05, 0xa0])))
        var extensions = basicConstraints + keyUsage
        if !ca {
            extensions += ext([0x55, 0x1d, 0x25], false,
                              sequence(oid([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])))
            // Subject alternative names: 127.0.0.1 as an IP and localhost as DNS.
            extensions += ext([0x55, 0x1d, 0x11], false,
                              sequence(der(0x87, Data([127, 0, 0, 1]))
                                       + der(0x82, Data("localhost".utf8))))
        }

        let tbs = sequence(
            der(0xa0, der(0x02, Data([0x02])))
            + serialNumber
            + signatureAlgorithm
            + issuer
            + validity
            + subject
            + publicInfo
            + der(0xa3, sequence(extensions))
        )

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signingKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &error
        ) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw failure("Certificate signing failed.")
        }

        return sequence(tbs + signatureAlgorithm + bitString(signature))
    }

    private static func name(_ name: String) -> Data {
        sequence(der(0x31, sequence(oid([0x55, 0x04, 0x03]) + der(0x0c, Data(name.utf8)))))
    }

    private static func asnDate(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return der(0x17, Data(formatter.string(from: date).utf8))
    }

    private static func oid(_ bytes: [UInt8]) -> Data { der(0x06, Data(bytes)) }
    private static func sequence(_ data: Data) -> Data { der(0x30, data) }
    private static func bitString(_ data: Data) -> Data { der(0x03, Data([0]) + data) }

    private static func ext(_ identifier: [UInt8], _ critical: Bool, _ value: Data) -> Data {
        sequence(
            oid(identifier)
            + (critical ? Data([0x01, 0x01, 0xff]) : Data())
            + der(0x04, value)
        )
    }

    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        let count = bytes.count
        if count < 128 { return Data([tag, UInt8(count)]) + bytes }
        var length = count
        var lengthBytes = [UInt8]()
        while length > 0 {
            lengthBytes.insert(UInt8(length & 0xff), at: 0)
            length >>= 8
        }
        return Data([tag, 0x80 | UInt8(lengthBytes.count)] + lengthBytes) + bytes
    }

    private static func pem(_ label: String, _ data: Data) -> String {
        let base64 = data.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { start -> String in
            let lower = base64.index(base64.startIndex, offsetBy: start)
            let upper = base64.index(lower, offsetBy: min(64, base64.count - start))
            return String(base64[lower..<upper])
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n")
            + "\n-----END \(label)-----\n"
    }
}
