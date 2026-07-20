import Vapor
import Fluent
import VaporAPNS
import APNSCore

// MARK: - PushService
//
// Best-effort direct APNs pushes. Callers fire this from a detached Task AFTER
// their DB write succeeds — nothing here ever throws back to a request handler,
// and if APNs isn't configured (local dev without the APNS_* env vars) every
// send is a logged no-op.
//
// Environment routing: each PushToken row remembers whether it came from the
// APNs sandbox (`is_sandbox`, debug builds run from Xcode) or production
// (TestFlight / App Store), and the send goes through the matching container
// configured in configure.swift. Tokens APNs reports as BadDeviceToken or
// Unregistered are deleted so we stop paying for dead sends.

enum PushService {

    /// The APNs topic — the app's bundle id. Mirrors the Sign in with Apple
    /// audience configured in configure.swift.
    static var topic: String {
        Environment.get("APPLE_APP_BUNDLE_ID") ?? "com.relentlessforgellc.mochi"
    }

    /// Custom keys delivered alongside the alert so the client can route taps
    /// (e.g. straight to the challenges sheet).
    private struct Payload: Codable, Sendable {
        let kind: String     // "challenge" | "friend_request" | "gift"
    }

    // MARK: - Send

    /// Sends an alert push to every registered token of an account. Best-effort:
    /// failures are logged, dead tokens are pruned, nothing is thrown.
    static func send(
        to accountID: UUID,
        title: String,
        body: String,
        badge: Int? = nil,
        kind: String,
        app: Application,
        db: any Database
    ) async {
        let tokens: [PushToken]
        do {
            tokens = try await PushToken.query(on: db)
                .filter(\.$account.$id == accountID)
                .all()
        } catch {
            app.logger.warning("📣 [push] Token lookup failed for \(accountID): \(error)")
            return
        }
        guard !tokens.isEmpty else { return }

        let notification = APNSAlertNotification(
            alert: .init(title: .raw(title), body: .raw(body)),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: Payload(kind: kind),
            badge: badge,
            sound: .default
        )

        for row in tokens {
            let containerID: APNSContainers.ID = row.isSandbox ? .development : .production
            guard let container = app.apns.containers.container(for: containerID) else {
                app.logger.debug("📣 [push] APNs not configured — skipping \(kind) push.")
                return
            }

            do {
                try await container.client.sendAlertNotification(notification, deviceToken: row.token)
                app.logger.info("📣 [push] Sent \(kind) push to account \(accountID) (\(row.isSandbox ? "sandbox" : "production"))")
            } catch let error as APNSError where error.reason == .badDeviceToken || error.reason == .unregistered {
                // The token is dead — prune it so we stop sending to it.
                do {
                    try await row.delete(on: db)
                    app.logger.info("📣 [push] Pruned dead token for account \(accountID) (\(error.reason?.reason ?? "?"))")
                } catch {
                    app.logger.warning("📣 [push] Failed to prune dead token: \(error)")
                }
            } catch {
                app.logger.warning("📣 [push] Send failed for account \(accountID): \(error)")
            }
        }
    }

    // MARK: - Badge math

    /// The recipient's app-icon badge: pending challenges addressed to them
    /// plus unclaimed gifts in their mailbox. Nil (leave the badge alone) if
    /// the counts can't be computed.
    static func badgeCount(for accountID: UUID, on db: any Database) async -> Int? {
        do {
            let challenges = try await FriendChallenge.query(on: db)
                .filter(\.$to.$id == accountID)
                .filter(\.$status == FriendChallengeStatus.pending.rawValue)
                .count()
            let gifts = try await CoinGift.query(on: db)
                .filter(\.$to.$id == accountID)
                .filter(\.$claimedAt == nil)
                .count()
            return challenges + gifts
        } catch {
            return nil
        }
    }
}
