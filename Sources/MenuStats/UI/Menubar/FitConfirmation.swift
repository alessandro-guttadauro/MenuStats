import Foundation

/// Decides whether a status item that looks hidden really has no room, and when to try a wider bar again.
///
/// macOS takes a moment, sometimes seconds (for instance while a menu is open), to lay out a status item after it was
/// created or resized, and in the meantime it reports the item as hidden. Shrinking on that reading recreates the items,
/// which look hidden again, and the bar collapses down to its first module. So:
/// - readings are ignored while the items settle;
/// - after a change the bar is not shrunk again until the items' position actually moved (or a timeout passes);
/// - an item must look hidden for a while before the bar is shrunk;
/// - only a couple of shrinks happen in a row (then one more every so often), so a reading that stays "hidden" whatever
///   the width, because something else is going on, costs at most a few modules and not the whole bar;
/// - a shrunk bar tries one step wider after a while; if that does not fit it stops trying until the room may have
///   changed (an app launched or quit, a new Space, a screen change), so the bar does not flicker.
struct FitConfirmation {
    enum Verdict: Equatable {
        /// Visible, or not yet to be trusted: nothing to do.
        case fine
        /// Look again after this many seconds.
        case wait(TimeInterval)
        /// Hidden for long enough: shrink.
        case shrink
    }

    /// Seconds to ignore readings after the items were created or resized.
    static let settle: TimeInterval = 1.0
    /// Seconds an item must keep looking hidden.
    static let confirm: TimeInterval = 0.8
    /// Seconds to wait for the layout to move after a change before trusting a hidden reading anyway.
    static let layoutLag: TimeInterval = 5.0
    /// Shrinks allowed in a row before they are spaced out, and the seconds it takes to earn another.
    static let shrinkBudget = 2
    static let shrinkRefill: TimeInterval = 20
    static let firstRestoreDelay: TimeInterval = 10
    /// After a wider bar did not fit, the next try waits this long, doubling each time up to `longestRestoreDelay`:
    /// nothing announces when a microphone or camera indicator goes away.
    static let failedRestoreDelay: TimeInterval = 60
    static let longestRestoreDelay: TimeInterval = 600
    /// Seconds a wider bar must stay visible to count as fitting: macOS may hide it a few seconds after showing it.
    static let restoreProof: TimeInterval = 30

    private var settledAt = Date.distantPast
    private var changedAt = Date.distantPast
    private var signatureAtChange: Double?
    private var hiddenSince: Date?
    private var budget = FitConfirmation.shrinkBudget
    private var budgetCountedAt = Date.distantPast
    /// Seconds before trying a wider bar; longer after each try that did not fit, until `roomMayHaveChanged()`.
    private(set) var restoreDelay: TimeInterval? = FitConfirmation.firstRestoreDelay
    private var nextFailedDelay = FitConfirmation.failedRestoreDelay
    private var restoring = false
    private var restoreBeganAt = Date.distantPast

    /// A wider bar was tried and hasn't stayed visible long enough yet to count as fitting.
    var confirmingRestore: Bool { restoring }

    /// The items were created, resized or reshaped. `signature` summarizes where macOS put them (for example the sum of
    /// their frames' edges), so a later reading can tell whether the layout has moved since.
    mutating func layoutChanged(at now: Date, signature: Double? = nil) {
        settledAt = now.addingTimeInterval(Self.settle)
        changedAt = now
        signatureAtChange = signature
        hiddenSince = nil
    }

    mutating func observe(hidden: Bool, signature: Double? = nil, at now: Date) -> Verdict {
        if now < settledAt { return .wait(settledAt.timeIntervalSince(now) + 0.1) }
        guard hidden else {
            hiddenSince = nil
            budget = Self.shrinkBudget
            if restoring, now.timeIntervalSince(restoreBeganAt) >= Self.restoreProof {
                restoring = false
                restoreDelay = Self.firstRestoreDelay // the wider bar fits: next step soon
                nextFailedDelay = Self.failedRestoreDelay
            }
            return .fine
        }
        // Still where it was before the change: macOS has not laid the new items out yet.
        if let signature, signature == signatureAtChange, now.timeIntervalSince(changedAt) < Self.layoutLag { return .wait(0.5) }
        let since = hiddenSince ?? now
        hiddenSince = since
        if now.timeIntervalSince(since) >= Self.confirm {
            // Earn back shrinks with time.
            if budget < Self.shrinkBudget, now.timeIntervalSince(budgetCountedAt) >= Self.shrinkRefill {
                budget += 1
                budgetCountedAt = now
            }
            guard budget > 0 else { return .wait(5) }
            budget -= 1
            if budget == Self.shrinkBudget - 1 { budgetCountedAt = now }
            hiddenSince = nil
            if restoring {
                restoring = false
                // That step did not fit: try again later, waiting longer each time so the bar doesn't flicker.
                restoreDelay = nextFailedDelay
                nextFailedDelay = min(nextFailedDelay * 2, Self.longestRestoreDelay)
            }
            return .shrink
        }
        return .wait(0.5)
    }

    /// A step wider was just tried; if it does not fit, the next try waits longer.
    mutating func beganRestore(at now: Date) {
        restoring = true
        restoreBeganAt = now
    }

    /// Something that changes the room in the menu bar happened: wider bars are worth trying again.
    mutating func roomMayHaveChanged() {
        restoreDelay = Self.firstRestoreDelay
        nextFailedDelay = Self.failedRestoreDelay
    }
}
