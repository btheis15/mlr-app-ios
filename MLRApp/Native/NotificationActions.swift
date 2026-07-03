import UserNotifications
import UIKit

// MARK: - Notification Actions & Categories
//
// Actionable push notifications — the family can respond from the notification
// itself without opening the app:
//   • Event reminder → "Going" / "Maybe" RSVP buttons.
//   • Help request → "On my way" button.
//   • Chat mention / committee message → inline text "Reply" field.
//   • Birthday → "Send wishes" (opens a prefilled text) / "Send a gift".
//
// The APNs payload from the Mac mini sender sets `"category"` to one of these
// identifiers and includes the relevant id in its `userInfo` so the handler knows
// what to act on. Register the categories at launch (see AppDelegate.registerNotificationCategories()).

enum NotifCategory: String {
    case eventReminder = "EVENT_REMINDER"
    case helpRequest   = "HELP_REQUEST"
    case chatMention   = "CHAT_MENTION"
    case birthday      = "BIRTHDAY"
    case workFollowup  = "WORK_FOLLOWUP"
    case committeeJoinRequest = "COMMITTEE_JOIN_REQUEST"
}

enum NotifAction: String {
    case rsvpGoing   = "RSVP_GOING"
    case rsvpMaybe   = "RSVP_MAYBE"
    case onMyWay     = "ON_MY_WAY"
    case reply       = "REPLY"
    case birthdayText = "BIRTHDAY_TEXT"
    case birthdayGift = "BIRTHDAY_GIFT"
    case workDone     = "WORK_DONE"
    case workNotYet   = "WORK_NOT_YET"
    case approveJoin  = "APPROVE_JOIN"
    case declineJoin  = "DECLINE_JOIN"
}

extension UNUserNotificationCenter {
    /// Call once at launch (AppDelegate.didFinishLaunching).
    func registerMLRCategories() {
        let going = UNNotificationAction(identifier: NotifAction.rsvpGoing.rawValue,
                                         title: "✅ Going", options: [])
        let maybe = UNNotificationAction(identifier: NotifAction.rsvpMaybe.rawValue,
                                         title: "🤔 Maybe", options: [])
        let eventReminder = UNNotificationCategory(
            identifier: NotifCategory.eventReminder.rawValue,
            actions: [going, maybe], intentIdentifiers: [], options: [])

        let onMyWay = UNNotificationAction(identifier: NotifAction.onMyWay.rawValue,
                                           title: "🙋 On my way", options: [.foreground])
        let helpRequest = UNNotificationCategory(
            identifier: NotifCategory.helpRequest.rawValue,
            actions: [onMyWay], intentIdentifiers: [], options: [])

        let reply = UNTextInputNotificationAction(
            identifier: NotifAction.reply.rawValue,
            title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let chatMention = UNNotificationCategory(
            identifier: NotifCategory.chatMention.rawValue,
            actions: [reply], intentIdentifiers: [], options: [])

        let wishes = UNNotificationAction(identifier: NotifAction.birthdayText.rawValue,
                                          title: "🎂 Send wishes", options: [.foreground])
        let gift = UNNotificationAction(identifier: NotifAction.birthdayGift.rawValue,
                                        title: "🎁 Send a gift", options: [.foreground])
        let birthday = UNNotificationCategory(
            identifier: NotifCategory.birthday.rawValue,
            actions: [wishes, gift], intentIdentifiers: [], options: [])

        let workDone = UNNotificationAction(identifier: NotifAction.workDone.rawValue,
                                            title: "✅ Yes, it's done", options: [])
        let workNotYet = UNNotificationAction(identifier: NotifAction.workNotYet.rawValue,
                                              title: "Not yet", options: [])
        let workFollowup = UNNotificationCategory(
            identifier: NotifCategory.workFollowup.rawValue,
            actions: [workDone, workNotYet], intentIdentifiers: [], options: [])

        // Approve acts in place (one tap from the lock screen); Decline opens the
        // app to the request so a mis-tap can't silently reject someone.
        let approveJoin = UNNotificationAction(identifier: NotifAction.approveJoin.rawValue,
                                               title: "✅ Approve", options: [])
        let declineJoin = UNNotificationAction(identifier: NotifAction.declineJoin.rawValue,
                                               title: "Decline", options: [.foreground])
        let committeeJoin = UNNotificationCategory(
            identifier: NotifCategory.committeeJoinRequest.rawValue,
            actions: [approveJoin, declineJoin], intentIdentifiers: [], options: [])

        setNotificationCategories([eventReminder, helpRequest, chatMention, birthday, workFollowup, committeeJoin])
    }
}

// MARK: - Action handling
//
// Called from NotificationDelegate.didReceive. Background actions (RSVP, reply)
// post to Supabase directly; foreground actions (on my way, birthday) route into
// the app via IntentRouter / a pending-action queue.

@MainActor
enum NotificationActionHandler {
    static func handle(actionId: String, userInfo: [AnyHashable: Any]) async {
        guard let action = NotifAction(rawValue: actionId) else { return }
        switch action {
        case .rsvpGoing, .rsvpMaybe:
            if let eventId = userInfo["event_id"] as? String {
                let status: AttendanceStatus = action == .rsvpGoing ? .going : .maybe
                try? await AppEnvironment.activeEventsService?.upsertAttendance(
                    eventId: eventId, status: status, days: nil)
            }
        case .onMyWay:
            if let requestId = userInfo["request_id"] as? String,
               let uuid = UUID(uuidString: requestId) {
                try? await AppEnvironment.activeHelpService?.respondToHelp(requestId: uuid)
            }
        case .reply:
            // The typed text arrives as UNTextInputNotificationResponse.userText,
            // captured by the delegate and placed in userInfo["reply_text"].
            if let text = userInfo["reply_text"] as? String,
               let committeeId = userInfo["committee_id"] as? String,
               let uuid = UUID(uuidString: committeeId), !text.isEmpty,
               let authorId = supabase.auth.currentUser?.id {
                try? await AppEnvironment.activeCommitteeService?.sendMessage(
                    committeeId: uuid, text: text, authorId: authorId)
            }
        case .workDone:
            // "Yes, it's done" → check the linked Work Checklist task off.
            if let workItemId = userInfo["work_item_id"] as? String,
               let uuid = UUID(uuidString: workItemId) {
                try? await AppEnvironment.activeWorkItemsService?.markDone(id: uuid)
                await AppEnvironment.activeWorkItemsService?.fetchItems()
            }
        case .workNotYet:
            // Nothing to do — the task stays open; a later cron run won't re-nudge
            // because followup_sent is already set server-side.
            break
        case .birthdayText, .birthdayGift:
            // Foreground actions — hand to the app to present the message composer
            // / Apple Cash handoff for the birthday person.
            if let memberId = userInfo["member_id"] as? String {
                BirthdayActionQueue.shared.pending = .init(
                    memberId: memberId, gift: action == .birthdayGift)
            }
        case .approveJoin:
            // One-tap approve — applies the requester's chosen areas server-side.
            if let requestId = userInfo["request_id"] as? String,
               let uuid = UUID(uuidString: requestId) {
                try? await AppEnvironment.activeCommitteeService?.approveJoin(requestId: uuid)
            }
        case .declineJoin:
            // Foreground — open the app to the committee so the admin reviews first.
            NotificationCenter.default.post(
                name: .notificationTapped, object: nil,
                userInfo: [
                    "target_type": "committee_join_request",
                    "target_id": (userInfo["request_id"] as? String) ?? "",
                    "committee_id": (userInfo["committee_id"] as? String) ?? ""
                ])
        }
    }
}

/// A tiny queue the app drains on next foreground to present the birthday composer.
@MainActor
@Observable
final class BirthdayActionQueue {
    static let shared = BirthdayActionQueue()
    struct Pending { let memberId: String; let gift: Bool }
    var pending: Pending?
}
