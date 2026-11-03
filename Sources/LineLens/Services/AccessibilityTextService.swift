import AppKit
@preconcurrency import ApplicationServices
import LineLensCore
import Observation

@MainActor @Observable
final class AccessibilityAccess {
    private(set) var isTrusted = AXIsProcessTrusted()

    func refresh() { isTrusted = AXIsProcessTrusted() }

    /// Called only by the user's permission button; never prompts during capture.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }
}

struct AccessibleTextCandidate: Sendable {
    let text: String
    let rect: CGRect
    let isControl: Bool
    var isSecure = false
}

enum AccessibilityTextExtractor {
    static func blocks(from candidates: [AccessibleTextCandidate], captureRect: CGRect) -> [TextBlock] {
        guard captureRect.width > 0, captureRect.height > 0 else { return [] }
        var selected: [AccessibleTextCandidate] = []
        // Child text boxes are more precise than their enclosing button/link boxes.
        for candidate in candidates.sorted(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isSecure, !text.isEmpty, text.count <= 10_000,
                  candidate.rect.intersects(captureRect), candidate.rect.width > 1, candidate.rect.height > 1 else { continue }
            let duplicate = selected.contains { item in
                guard item.text.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return false }
                let intersection = item.rect.intersection(candidate.rect)
                return !intersection.isNull && intersection.width * intersection.height >= min(item.rect.width * item.rect.height,
                    candidate.rect.width * candidate.rect.height) * 0.7
            }
            if !duplicate { selected.append(candidate) }
        }
        return selected.compactMap { candidate in
            let box = (candidate.isControl ? candidate.rect.insetBy(dx: 3, dy: 3) : candidate.rect).intersection(captureRect)
            guard !box.isNull, box.width > 1, box.height > 1 else { return nil }
            let rect = CGRect(x: (box.minX - captureRect.minX) / captureRect.width,
                              y: (box.minY - captureRect.minY) / captureRect.height,
                              width: box.width / captureRect.width, height: box.height / captureRect.height)
            let lines = max(1, candidate.text.components(separatedBy: .newlines).count)
            let fontSize: CGFloat = candidate.isControl ? min(13, box.height * 0.8) : min(48, max(10, box.height / CGFloat(lines) * 0.85))
            var block = TextBlock(source: candidate.text.trimmingCharacters(in: .whitespacesAndNewlines), rect: rect, confidence: 1)
            block.fontSizeHint = fontSize
            return block
        }.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }
}

/// AX messages can block when another app is busy; all traversal happens off the
/// main actor, with a per-message timeout, node limit and overall time budget.
actor AccessibilityTextService {
    private struct UnsupportedWindow {
        let processID: pid_t
        let rect: CGRect
        let until: ContinuousClock.Instant
    }
    private var unsupported: UnsupportedWindow?
    private var captureRect: CGRect?

    func read(processID: pid_t, windowRect: CGRect, captureRect: CGRect) throws -> [TextBlock]? {
        guard AXIsProcessTrusted() else { return nil }
        if self.captureRect != captureRect { unsupported = nil; self.captureRect = captureRect }
        if let unsupported, unsupported.processID == processID, unsupported.rect == windowRect,
           ContinuousClock.now < unsupported.until { return nil }
        let result = try readWindow(processID: processID, windowRect: windowRect, captureRect: captureRect)
        if result == nil {
            // Do not repeatedly spend the AX timeout budget on a game/canvas.
            unsupported = UnsupportedWindow(processID: processID, rect: windowRect,
                until: ContinuousClock.now.advanced(by: .seconds(5)))
        } else { unsupported = nil }
        return result
    }

    private func readWindow(processID: pid_t, windowRect: CGRect, captureRect: CGRect) throws -> [TextBlock]? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.06)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { return nil }
        let matches = windows.compactMap { window -> (AXUIElement, CGFloat)? in
            guard ContinuousClock.now < deadline else { return nil }
            guard let rect = rectangle(attributes(window)) else { return nil }
            let overlap = rect.intersection(windowRect)
            guard !overlap.isNull else { return nil }
            return (window, overlap.width * overlap.height / max(rect.union(windowRect).width * rect.union(windowRect).height, 1))
        }
        let ranked = matches.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 > 0.8 else { return nil }
        // Identical overlapping windows cannot be safely identified through AX bounds.
        if ranked.count > 1, abs(best.1 - ranked[1].1) < 0.01 { return nil }
        var stack: [(AXUIElement, Int)] = [(best.0, 0)]
        var visited = 0
        var candidates: [AccessibleTextCandidate] = []
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, kAXButtonRole,
            kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, "AXLink", "AXHeading", kAXComboBoxRole]
        while let (element, depth) = stack.popLast() {
            try Task.checkCancellation()
            guard visited < 1500, ContinuousClock.now < deadline else { return nil }
            visited += 1
            let values = attributes(element)
            let role = values[0] as? String ?? ""
            let subrole = values[1] as? String ?? ""
            if subrole == kAXSecureTextFieldSubrole { continue }
            let children = values[7] as? [AXUIElement] ?? []
            let rect = rectangle(values)
            if let rect, rect.intersects(captureRect) {
                if children.isEmpty, ["AXImage", "AXUnknown", "AXWebArea"].contains(role),
                   rect.width * rect.height > captureRect.width * captureRect.height * 0.08 {
                    // Large image/canvas content cannot be read as accessible text.
                    return nil
                }
                if textRoles.contains(role) {
                    let isValue = [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole].contains(role)
                    // Descriptions can name icon-only controls with no visible text.
                    // Translate only visible value/title strings.
                    let text = (isValue ? values[3] as? String : nil) ?? values[2] as? String ?? ""
                    if !text.isEmpty {
                        candidates.append(AccessibleTextCandidate(text: text, rect: rect,
                            isControl: ![kAXStaticTextRole, kAXTextAreaRole, "AXHeading"].contains(role)))
                    }
                }
            }
            if depth < 30 { stack.append(contentsOf: children.reversed().map { ($0, depth + 1) }) }
        }
        let blocks = AccessibilityTextExtractor.blocks(from: candidates, captureRect: captureRect)
        return blocks.isEmpty ? nil : blocks
    }

    private func attributes(_ element: AXUIElement) -> [Any] {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                     kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let result = values as? [Any], result.count == 8 else { return Array(repeating: NSNull(), count: 8) }
        return result
    }

    private func rectangle(_ values: [Any]) -> CGRect? {
        guard CFGetTypeID(values[5] as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(values[6] as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[5] as! AXValue, .cgPoint, &point),
              AXValueGetValue(values[6] as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
}
