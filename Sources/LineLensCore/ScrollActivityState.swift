import Foundation

public enum ScrollInputPhase: Sendable {
    case wheel, gesture, gestureEnded, momentum, momentumEnded
}

/// Only activity deadlines are kept. No translated image, text rectangle or
/// displacement history survives a scroll.
public struct ScrollActivityState: Sendable {
    public private(set) var isScrolling = false
    private var lastInput: TimeInterval = 0
    private var lastMotion: TimeInterval = 0
    private var inputQuietPeriod: TimeInterval = 0.24

    public init() {}

    @discardableResult
    public mutating func note(_ phase: ScrollInputPhase, at time: TimeInterval) -> Bool {
        let started = !isScrolling
        isScrolling = true
        lastInput = time
        if started { lastMotion = time }
        // Finger-up is followed by momentum-began on a later event. Do not
        // refresh in that gap. Phase-less wheels use a short quiet timeout.
        switch phase {
        case .gesture, .momentum: inputQuietPeriod = 0.4
        case .wheel, .gestureEnded, .momentumEnded: inputQuietPeriod = 0.24
        }
        return started
    }

    public mutating func observeMotion(at time: TimeInterval) {
        if isScrolling { lastMotion = time }
    }

    public var deadline: TimeInterval? {
        guard isScrolling else { return nil }
        // Small animations are filtered by the caller. Bound the visual tail as
        // well so a video cannot withhold translation forever after input ends.
        return max(lastInput + inputQuietPeriod, min(lastMotion + 0.22, lastInput + 1))
    }

    @discardableResult
    public mutating func settle(at time: TimeInterval) -> Bool {
        guard let deadline, time >= deadline else { return false }
        isScrolling = false
        return true
    }
}
