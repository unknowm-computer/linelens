import Foundation
import Security

// Secrets are read from private files, never from command-line arguments.
// These legacy APIs are intentional: codesign uses a file-based keychain.
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        throw NSError(domain: "LineLens.Signing", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(operation): \(message) (\(status))"])
    }
}

do {
    guard CommandLine.arguments.count == 3,
          ["create", "unlock"].contains(CommandLine.arguments[1]) else {
        throw NSError(domain: "LineLens.Signing", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: signing-keychain create|unlock DIRECTORY"])
    }
    let command = CommandLine.arguments[1]
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let path = directory.appendingPathComponent("LineLens.keychain-db").path
    let password = try Data(contentsOf: directory.appendingPathComponent("password"))
    var keychain: SecKeychain?

    if command == "create" {
        // Creating a keychain can change the search list. Restore it; all later
        // operations explicitly name this keychain instead of changing defaults.
        var previousSearchList: CFArray?
        try check(SecKeychainCopySearchList(&previousSearchList), "Read keychain search list")
        defer {
            if let previousSearchList {
                let status = SecKeychainSetSearchList(previousSearchList)
                if status != errSecSuccess {
                    fputs("Could not restore keychain search list (\(status)).\n", stderr)
                }
            }
        }
        try password.withUnsafeBytes { bytes in
            try check(SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress,
                                        false, nil, &keychain), "Create dedicated keychain")
        }
        guard let keychain else { fatalError("Missing created keychain") }
        var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                           lockOnSleep: true, useLockInterval: true,
                                           lockInterval: 900)
        try check(SecKeychainSetSettings(keychain, &settings), "Set keychain locking")

        var codesign: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign),
                  "Identify codesign")
        var access: SecAccess?
        try check(SecAccessCreate("LineLens local code signing" as CFString,
                                  [codesign!] as CFArray, &access), "Create signing key ACL")
        let passphrase = String(decoding: password, as: UTF8.self) as CFString
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        parameters.passphrase = Unmanaged.passUnretained(passphrase)
        parameters.accessRef = access.map { Unmanaged.passUnretained($0) }
        let usage = [kSecAttrCanSign] as CFArray
        let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
        parameters.keyUsage = Unmanaged.passUnretained(usage)
        parameters.keyAttributes = Unmanaged.passUnretained(attributes)
        var format = SecExternalFormat.formatPKCS12
        var type = SecExternalItemType.itemTypeAggregate
        let bundle = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        try withExtendedLifetime((passphrase, access, usage, attributes)) {
            try check(SecItemImport(bundle as CFData, "p12" as CFString, &format, &type,
                                    [], &parameters, keychain, nil), "Import signing identity")
        }
    } else {
        try check(SecKeychainOpen(path, &keychain), "Open dedicated keychain")
        try password.withUnsafeBytes { bytes in
            try check(SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true),
                      "Unlock dedicated keychain")
        }
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
