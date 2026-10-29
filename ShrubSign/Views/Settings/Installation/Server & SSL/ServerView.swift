//  PersonalSSL is intentionally local-only. Each device receives unique
//  credentials; no shared private key or retired backloop endpoint is used.
import SwiftUI
import Security
import Foundation

struct ServerView: View {
    @AppStorage("Feather.ipFix") private var ipFix = false
    @AppStorage("Feather.serverMethod") private var method = 1
    @State private var generating = false
    @State private var setupMessage = ""
    @State private var trustProfile: URL?
    @State private var sslReady = PersonalSSL.hasCredentials

    var body: some View {
        Group {
            Section {
                Picker("Installation mode", systemImage: "server.rack", selection: $method) {
                    Text("Semi Local — Recommended").tag(1)
                    Text("Fully Local — Custom SSL").tag(0)
                }
                Toggle("Use localhost only", systemImage: "network", isOn: $ipFix)
                    .disabled(method != 1)
            } footer: {
                Text(method == 1
                    ? "Default: the IPA stays on this device. The installation manifest uses an external HTTPS service. No local certificate setup is needed."
                    : "Fully Local serves the IPA and manifest through HTTPS on this device. Set up and explicitly trust a personal certificate first. iOS may impose additional installation restrictions.")
            }

            if method == 0 {
                Section {
                    Label(sslReady ? "Local certificate generated" : "Setup required", systemImage: sslReady ? "checkmark.shield" : "lock.shield")
                        .foregroundStyle(sslReady ? .green : .orange)
                    Button {
                        generating = true
                        setupMessage = ""
                        Task {
                            let result = await Task.detached(priority: .userInitiated) {
                                Result { try PersonalSSL.generate() }
                            }.value
                            switch result {
                            case .success(let url):
                                trustProfile = url
                                sslReady = true
                                setupMessage = "Certificate created. Share the trust profile to Files, open it, then approve it in iOS Settings."
                            case .failure(let error):
                                setupMessage = "SSL setup failed: \(error.localizedDescription)"
                            }
                            generating = false
                        }
                    } label: {
                        Label(sslReady ? "Regenerate SSL (requires new trust)" : "Generate my private SSL", systemImage: "lock.shield")
                    }
                    .disabled(generating)

                    if generating {
                        HStack { ProgressView(); Text("Creating device certificates…") }
                    }
                    if let url = trustProfile ?? PersonalSSL.existingProfile {
                        ShareLink(item: url) {
                            Label("Share SSL trust profile", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !setupMessage.isEmpty {
                        Text(setupMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Fully Local SSL")
                } footer: {
                    Text("1. Generate and share the profile to Files. 2. Open the profile and install it in Settings → General → VPN & Device Management. 3. Enable full trust under Settings → General → About → Certificate Trust Settings. 4. Return here and restart ShrubSign. Never share private key files. If you regenerate, trust the new profile again.")
                }
            }
        }
        .onChange(of: method) { _ in
            if method == 0 && !PersonalSSL.hasCredentials {
                setupMessage = "Generate SSL, install the trust profile, then restart ShrubSign."
                return
            }
            UIAlertController.showAlertWithRestart(
                title: .localized("Restart Required"),
                message: .localized("These changes require a restart of the app")
            )
        }
        .onAppear { sslReady = PersonalSSL.hasCredentials }
    }
}

private enum PersonalSSL {
    static let directory = URL.documentsDirectory.appendingPathComponent("App/Server", isDirectory: true)
    static var existingProfile: URL? {
        let url = directory.appendingPathComponent("ShrubSign-Local-Trust.mobileconfig")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static var hasCredentials: Bool {
        ["server.crt", "server.pem", "commonName.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func generate() throws -> URL {
        let rootKey = try makeRSAKey()
        let leafKey = try makeRSAKey()
        guard let rootPublic = SecKeyCopyPublicKey(rootKey),
              let leafPublic = SecKeyCopyPublicKey(leafKey) else {
            throw failure("Could not read generated public key")
        }
        let rootSubject = name("ShrubSign Personal Local CA")
        let leafSubject = name("ShrubSign Local Installer")
        let root = try certificate(subject: rootSubject, issuer: rootSubject,
                                   publicKey: rootPublic, signingKey: rootKey, ca: true)
        let leaf = try certificate(subject: leafSubject, issuer: rootSubject,
                                   publicKey: leafPublic, signingKey: rootKey, ca: false)
        let leafPrivate = try export(leafKey)

        let rootPEM = pem("CERTIFICATE", root)
        let leafPEM = pem("CERTIFICATE", leaf)
        let keyPEM = pem("RSA PRIVATE KEY", leafPrivate)
        let profileURL = directory.appendingPathComponent("ShrubSign-Local-Trust.mobileconfig")
        let rootPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "dev.shrubsign.local.ssl.root",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "ShrubSign Personal Local CA",
            "PayloadCertificateFileName": "ShrubSign-Local-CA.crt",
            "PayloadContent": root
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "dev.shrubsign.local.ssl.\(UUID().uuidString.lowercased())",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "ShrubSign Personal Local SSL",
            "PayloadOrganization": "ShrubSign (device-local)",
            "PayloadDescription": "Trust only this device's ShrubSign localhost HTTPS certificate authority.",
            "PayloadContent": [rootPayload]
        ]
        let profileData = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (leafPEM + rootPEM).write(to: directory.appendingPathComponent("server.crt"), atomically: true, encoding: .utf8)
        try keyPEM.write(to: directory.appendingPathComponent("server.pem"), atomically: true, encoding: .utf8)
        try "127.0.0.1\n".write(to: directory.appendingPathComponent("commonName.txt"), atomically: true, encoding: .utf8)
        try profileData.write(to: profileURL, options: .atomic)
        // The CA private key is intentionally never persisted or shared.
        return profileURL
    }

    private static func failure(_ message: String) -> Error {
        NSError(domain: "ShrubSign.PersonalSSL", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func makeRSAKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw failure("RSA key generation failed")
        }
        return key
    }
    private static func export(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw failure("Cannot export private SSL key")
        }
        return data
    }
    private static func certificate(subject: Data, issuer: Data, publicKey: SecKey,
                                    signingKey: SecKey, ca: Bool) throws -> Data {
        let publicDER = try export(publicKey) // RSA PKCS#1 public key
        let rsaOID = oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
        let signatureAlgorithm = sequence(oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]) + Data([0x05, 0x00]))
        let publicInfo = sequence(sequence(rsaOID + Data([0x05, 0x00])) + bitString(publicDER))
        let now = Date()
        let validity = sequence(asnDate(now.addingTimeInterval(-86_400)) +
                               asnDate(now.addingTimeInterval(ca ? 5 * 365 * 86_400 : 350 * 86_400)))
        var serial = Data(repeating: 0, count: 16)
        guard serial.withUnsafeMutableBytes({ buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }) == errSecSuccess else { throw failure("Cannot generate certificate serial") }
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
            // SAN: 127.0.0.1 as an IP address, and localhost as DNS.
            extensions += ext([0x55, 0x1d, 0x11], false,
                              sequence(der(0x87, Data([127, 0, 0, 1])) + der(0x82, Data("localhost".utf8))))
        }
        let tbs = sequence(der(0xa0, der(0x02, Data([0x02]))) + serialNumber +
                           signatureAlgorithm + issuer + validity + subject + publicInfo +
                           der(0xa3, sequence(extensions)))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(signingKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    tbs as CFData, &error) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw failure("Certificate signing failed")
        }
        return sequence(tbs + signatureAlgorithm + bitString(signature))
    }
    private static func name(_ name: String) -> Data {
        sequence(der(0x31, sequence(oid([0x55, 0x04, 0x03]) + der(0x0c, Data(name.utf8)))))
    }
    private static func asnDate(_ date: Date) -> Data {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return der(0x17, Data(f.string(from: date).utf8))
    }
    private static func oid(_ bytes: [UInt8]) -> Data { der(0x06, Data(bytes)) }
    private static func sequence(_ data: Data) -> Data { der(0x30, data) }
    private static func bitString(_ data: Data) -> Data { der(0x03, Data([0]) + data) }
    private static func ext(_ identifier: [UInt8], _ critical: Bool, _ value: Data) -> Data {
        sequence(oid(identifier) + (critical ? Data([0x01, 0x01, 0xff]) : Data()) + der(0x04, value))
    }
    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        let count = bytes.count
        if count < 128 { return Data([tag, UInt8(count)]) + bytes }
        var n = count
        var lengthBytes = [UInt8]()
        while n > 0 { lengthBytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
        return Data([tag, 0x80 | UInt8(lengthBytes.count)] + lengthBytes) + bytes
    }
    private static func pem(_ label: String, _ data: Data) -> String {
        let b64 = data.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 64).map { start -> String in
            let lower = b64.index(b64.startIndex, offsetBy: start)
            let upper = b64.index(lower, offsetBy: min(64, b64.count - start))
            return String(b64[lower..<upper])
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }
}
