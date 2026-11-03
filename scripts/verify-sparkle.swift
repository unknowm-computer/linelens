import CryptoKit
import Foundation

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "LineLens.Sparkle", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    try require(arguments.count == 1 || arguments.count == 4,
                "Usage: verify-sparkle.swift Info.plist [appcast.xml archive.zip DOWNLOAD_URL_PREFIX]")
    let infoData = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
    let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] ?? [:]
    let keyData = Data(base64Encoded: info["SUPublicEDKey"] as? String ?? "") ?? Data()
    try require(keyData.count == 32, "SUPublicEDKey가 유효한 Ed25519 공개 키가 아닙니다. setup-sparkle.sh를 확인하세요.")
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let feed = URL(string: info["SUFeedURL"] as? String ?? "")
    try require(feed?.scheme == "https" && feed?.host != nil && feed?.user == nil && feed?.password == nil,
                "SUFeedURL은 인증 정보가 없는 공개 HTTPS 주소여야 합니다.")
    try require(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true && info["SURequireSignedFeed"] as? Bool == true,
                "업데이트 ZIP과 appcast 서명 검증을 활성화해야 합니다.")
    if arguments.count == 4 {
        let prefix = arguments[3]
        let prefixURL = URL(string: prefix)
        try require(prefixURL?.scheme == "https" && prefixURL?.host != nil && prefix.hasSuffix("/")
                    && prefixURL?.query == nil && prefixURL?.fragment == nil
                    && prefixURL?.user == nil && prefixURL?.password == nil,
                    "다운로드 주소 접두사는 /로 끝나는 공개 HTTPS 주소여야 합니다.")
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[1]), options: [])
        let items = try document.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }
        try require(items.count == 1, "릴리스 appcast에는 현재 버전 항목 하나가 있어야 합니다.")
        let item = items[0]
        func value(_ name: String) -> String? { item.elements(forName: name).first?.stringValue }
        try require(value("sparkle:version") == info["CFBundleVersion"] as? String, "appcast의 빌드 번호가 앱과 다릅니다.")
        try require(value("sparkle:shortVersionString") == info["CFBundleShortVersionString"] as? String,
                    "appcast의 표시 버전이 앱과 다릅니다.")
        try require(value("sparkle:minimumSystemVersion") == info["LSMinimumSystemVersion"] as? String,
                    "appcast의 최소 macOS 버전이 앱과 다릅니다.")
        let enclosures = item.elements(forName: "enclosure")
        try require(enclosures.count == 1, "appcast에 ZIP enclosure가 하나 있어야 합니다.")
        let enclosure = enclosures[0]
        let archiveURL = URL(fileURLWithPath: arguments[2])
        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let expectedURL = prefix + archiveURL.lastPathComponent
        try require(enclosure.attribute(forName: "url")?.stringValue == expectedURL, "appcast의 다운로드 주소가 다릅니다.")
        try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "ZIP 파일 크기가 다릅니다.")
        let signature = Data(base64Encoded: enclosure.attribute(forName: "sparkle:edSignature")?.stringValue ?? "") ?? Data()
        try require(publicKey.isValidSignature(signature, for: archive), "앱의 고정 공개 키로 ZIP 서명을 검증하지 못했습니다.")
        print("Sparkle 메타데이터·ZIP EdDSA 서명 검증 성공")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
