import Foundation
import WebInspectorProxyKit

/// Records which CSS style sheets are present and how often each one was
/// replaced or edited, so a CSS mutation can tell whether the sheet it is
/// about to change is still the one it read.
struct CSSStyleSheetLifetimes {
    private struct Lifetime {
        var frameID: FrameID?
        var revision: UInt64
        var contentRevision: UInt64
        var isPresent: Bool
    }

    private var lifetimesByID: [CSS.StyleSheet.ID: Lifetime] = [:]

    /// Advances when the sheet is removed, or added again for another frame.
    func revision(of id: CSS.StyleSheet.ID) -> UInt64 {
        lifetimesByID[id]?.revision ?? 0
    }

    /// Advances when the sheet's text changes.
    func contentRevision(of id: CSS.StyleSheet.ID) -> UInt64 {
        lifetimesByID[id]?.contentRevision ?? 0
    }

    mutating func record(_ header: CSS.StyleSheetHeader) {
        let id = header.styleSheetID
        guard let lifetime = lifetimesByID[id] else {
            lifetimesByID[id] = Lifetime(
                frameID: header.frameID,
                revision: 0,
                contentRevision: 0,
                isPresent: true
            )
            return
        }
        guard lifetime.isPresent == false || lifetime.frameID != header.frameID else {
            return
        }
        lifetimesByID[id] = Lifetime(
            frameID: header.frameID,
            revision: lifetime.revision + 1,
            contentRevision: lifetime.contentRevision,
            isPresent: true
        )
    }

    mutating func invalidate(_ id: CSS.StyleSheet.ID) {
        let lifetime = lifetimesByID[id]
        lifetimesByID[id] = Lifetime(
            frameID: lifetime?.frameID,
            revision: (lifetime?.revision ?? 0) + 1,
            contentRevision: lifetime?.contentRevision ?? 0,
            isPresent: false
        )
    }

    mutating func advanceContentRevision(_ id: CSS.StyleSheet.ID) {
        guard var lifetime = lifetimesByID[id] else {
            lifetimesByID[id] = Lifetime(
                frameID: nil,
                revision: 0,
                contentRevision: 1,
                isPresent: false
            )
            return
        }
        lifetime.contentRevision += 1
        lifetimesByID[id] = lifetime
    }

    mutating func invalidate(frameID: FrameID) {
        let ids = lifetimesByID.compactMap { id, lifetime in
            lifetime.frameID == frameID ? id : nil
        }
        for id in ids {
            invalidate(id)
        }
    }

    mutating func invalidate(targetID: WebInspectorTarget.ID) {
        let ids = lifetimesByID.keys.filter {
            $0.targetScopeRawValue == targetID.rawValue
        }
        for id in ids {
            invalidate(id)
        }
    }

    mutating func invalidateAll() {
        for id in Array(lifetimesByID.keys) {
            invalidate(id)
        }
    }

    mutating func removeAll() {
        lifetimesByID = [:]
    }
}
