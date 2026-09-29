import ActivityKit
import Foundation
import GlassRailKit
import os
import UIKit

/// Starts, updates and ends the Live Activity for a pinned ride.
///
/// There is no push server, so the activity can only change while the app
/// runs. The rules that keep it honest anyway:
/// - While the app is in the foreground the activity is live: it follows the
///   board's true times, track and position, and its stale date is the end of
///   the current phase, so the system redraws it (pickup, then drop-off) even
///   between updates.
/// - When the app goes to the background the activity is ended with its
///   latest content and a dismissal date of 3 minutes after arrival
///   (`RidePlan.dismissal`). The system enforces that date, so the activity
///   leaves the Lock Screen on time even if the app never runs again. The
///   Lock Screen layout draws every time-dependent part itself, so the ended
///   activity keeps reading right until then.
/// - Back in the foreground, a ride that is still on gets a fresh live
///   activity in place of the ended one.
/// - An activity whose ride is over, or that no longer matches the pin, is
///   ended right away, whichever direction the board is showing.
@MainActor
final class RideActivityController {
    private static let log = Logger(subsystem: "com.lasmith1689.GlassRail", category: "LiveActivity")

    private var lastContent: RideActivityAttributes.ContentState?
    private var lastKey: String?
    /// True between going to the background and becoming active again: no
    /// activity is requested or updated then (the system would refuse a
    /// request, and the ended one must stay as it is).
    private var suspended = false

    func sync(pin: Pin?, state: BoardState?, updatedAt: Date?, now: Date) {
        guard !suspended else { return }

        var kept: [Activity<RideActivityAttributes>] = []
        for activity in Activity<RideActivityAttributes>.activities where activity.activityState != .dismissed {
            let plan = activity.content.state.plan
            if RideActivityRules.shouldKeep(activityKey: activity.attributes.key, pinKey: pin?.key, plan: plan, now: now) {
                kept.append(activity)
            } else {
                end(activity, reason: plan.isOver(at: now) ? "ride over" : "pin released or changed")
            }
        }
        if kept.isEmpty { forget() }

        guard let pin, let state, pin.dirKey == state.dirKey else {
            // The board is showing the other direction (a ride that crossed
            // 2 PM or midnight): there is nothing fresher to show, and what is
            // there already ends on time by the rules above.
            return
        }
        guard state.isPinned, let hero = state.hero, hero.key == pin.key, let trainId = hero.trip.trainId else {
            // The board no longer features the pinned ride.
            for activity in kept { end(activity, reason: "pinned ride no longer featured") }
            forget()
            return
        }

        let content = RideActivityAttributes.ContentState(view: hero, state: state, updatedAt: updatedAt ?? now, now: now)
        let staleDate = content.plan.phaseEnds(at: now)
        let running = kept.first { $0.activityState == .active || $0.activityState == .stale }
        // Copies ended when the app was last suspended make way for a live one.
        for activity in kept where activity.id != running?.id {
            end(activity, reason: "replaced by a live activity")
        }

        if let running {
            guard content != lastContent || lastKey != pin.key else { return }
            lastContent = content
            lastKey = pin.key
            Task { await running.update(ActivityContent(state: content, staleDate: staleDate)) }
            Self.log.notice("Live Activity updated: \(pin.key, privacy: .public) phase \(content.phase.rawValue, privacy: .public)")
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.notice("Live Activities are turned off; not starting one")
            return
        }
        let attributes = RideActivityAttributes(
            key: pin.key,
            trainId: trainId,
            fromLabel: state.from.shortLabel,
            toLabel: state.to.shortLabel
        )
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: staleDate),
                pushType: nil
            )
            lastContent = content
            lastKey = pin.key
            Self.log.notice("Live Activity started: \(pin.key, privacy: .public) phase \(content.phase.rawValue, privacy: .public)")
        } catch {
            // Live Activities turned off, or too many running: the board still works.
            Self.log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The app is going to the background and may not run again before the
    /// ride is over: end each live activity now, with its latest content and
    /// a dismissal date the system enforces on its own.
    func suspend(now: Date) {
        suspended = true
        forget()
        let running = Activity<RideActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        guard !running.isEmpty else { return }

        let application = UIApplication.shared
        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = application.beginBackgroundTask(withName: "End ride Live Activity") {
            application.endBackgroundTask(taskId)
            taskId = .invalid
        }
        let jobs: [(Activity<RideActivityAttributes>, ActivityContent<RideActivityAttributes.ContentState>, ActivityUIDismissalPolicy)] = running.map { activity in
            let state = activity.content.state
            let plan = state.plan
            let policy: ActivityUIDismissalPolicy
            switch plan.dismissal(now: now) {
            case .immediate:
                policy = .immediate
                Self.log.notice("Live Activity ended on suspend: \(activity.attributes.key, privacy: .public), ride over, dismissed now")
            case .after(let date):
                policy = .after(date)
                Self.log.notice("Live Activity ended on suspend: \(activity.attributes.key, privacy: .public), dismissal at \(ISOTime.string(from: date), privacy: .public)")
            }
            return (activity, ActivityContent(state: state, staleDate: plan.endsAt), policy)
        }
        Task {
            for (activity, content, policy) in jobs {
                await activity.end(content, dismissalPolicy: policy)
            }
            if taskId != .invalid {
                application.endBackgroundTask(taskId)
                taskId = .invalid
            }
        }
    }

    /// Back in the foreground: the next sync starts a fresh live activity if
    /// the ride is still on.
    func resume() {
        suspended = false
        forget()
    }

    private func end(_ activity: Activity<RideActivityAttributes>, reason: String) {
        Self.log.notice("Live Activity ended: \(activity.attributes.key, privacy: .public) (\(reason, privacy: .public))")
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func forget() {
        lastContent = nil
        lastKey = nil
    }
}
