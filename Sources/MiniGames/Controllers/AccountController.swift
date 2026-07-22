import Vapor
import Fluent
import JWT

// MARK: - AccountController (S1 identity + S2 Sign in with Apple)
//
// Routes:
//   POST /account/bootstrap    — first-launch shadow-account creation / lookup (S1)
//   POST /account/apple-link   — link a Sign in with Apple identity to an account (S2)

struct AccountController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let account = routes.grouped("account")
        account.post("bootstrap",  use: bootstrap)
        account.post("apple-link", use: appleLink)
    }

    // MARK: - POST /account/bootstrap  (S1)
    //
    // Body: { "clientPlayerID": "<the client's local UUID>", "displayName": "<optional>" }
    //
    // Idempotent: same clientPlayerID always returns the same account. Creates a
    // new ANONYMOUS account + device the first time a clientPlayerID is seen.

    func bootstrap(req: Request) async throws -> AccountResponse {
        struct Body: Content {
            let clientPlayerID: String
            let displayName: String?
        }
        let body = try req.content.decode(Body.self)

        let trimmedID = body.clientPlayerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw Abort(.badRequest, reason: "clientPlayerID is required.")
        }

        // Existing device? → idempotent return of its account.
        if let device = try await Device.query(on: req.db)
            .filter(\.$clientPlayerID == trimmedID)
            .with(\.$account)
            .first()
        {
            let account = device.account
            device.lastSeenAt = Date()
            try await device.save(on: req.db)

            // Keep the account's name in sync with the client's profile on
            // EVERY launch (it used to only be written once, so leaderboards
            // and friend lists were stuck showing "Player 1234" forever).
            if let name = body.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty,
               account.displayName != String(name.prefix(30))
            {
                account.displayName = String(name.prefix(30))
                try await account.save(on: req.db)
            }

            req.logger.info("🪪 [bootstrap] Existing device \(trimmedID) → account \(account.id?.uuidString ?? "?")")
            return AccountResponse(from: account)
        }

        // No device yet → create a fresh anonymous account + device.
        let account = Account(
            status: .anonymous,
            displayName: body.displayName,
            sessionToken: Self.makeSessionToken()
        )
        try await account.save(on: req.db)

        guard let accountID = account.id else {
            throw Abort(.internalServerError, reason: "Failed to create account.")
        }

        let device = Device(accountID: accountID, clientPlayerID: trimmedID, lastSeenAt: Date())
        try await device.save(on: req.db)

        req.logger.info("🪪 [bootstrap] New anonymous account \(accountID) for device \(trimmedID)")
        return AccountResponse(from: account)
    }

    // MARK: - POST /account/apple-link  (S2)
    //
    // Body: { "clientPlayerID": "<local UUID>", "identityToken": "<Apple JWT>" }
    //
    // Verifies the Apple identity token (signature via Apple's JWKS, issuer,
    // audience = our bundle id, expiry — all handled by req.jwt.apple.verify),
    // then links the Apple identity to an account:
    //
    //   • If NO account has this Apple sub yet → take the account the device is
    //     currently on (its anonymous shadow account), stamp appleUserID/email,
    //     flip status to .linked. One update.
    //
    //   • If an account ALREADY has this Apple sub (user signed in on another
    //     device before) → reassign THIS device to that canonical account, and
    //     return it. The device's previous anonymous account becomes an orphan
    //     (merge-vs-discard deferred to S3).
    //
    // The device must already exist (client calls /bootstrap on first launch
    // before ever offering sign-in), so a missing device is a client-order bug.

    func appleLink(req: Request) async throws -> AccountResponse {
        struct Body: Content {
            let clientPlayerID: String
            let identityToken: String
        }
        let body = try req.content.decode(Body.self)

        let trimmedID = body.clientPlayerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw Abort(.badRequest, reason: "clientPlayerID is required.")
        }

        // 1. Verify the Apple identity token. This fetches Apple's public keys,
        //    checks the signature, issuer (appleid.apple.com), audience (our
        //    bundle id, set in configure.swift), and expiry. Throws on any
        //    failure — we never trust an unverified token.
        let appleIdentity: AppleIdentityToken
        do {
            appleIdentity = try await req.jwt.apple.verify(body.identityToken)
        } catch {
            req.logger.warning("🍎 [apple-link] Token verification failed: \(error)")
            throw Abort(.unauthorized, reason: "Invalid Apple identity token.")
        }

        let appleSub = appleIdentity.subject.value          // stable Apple user id
        let appleEmail = appleIdentity.email                 // present on first auth only

        // 2. The device must exist (bootstrap runs before sign-in is offered).
        guard let device = try await Device.query(on: req.db)
            .filter(\.$clientPlayerID == trimmedID)
            .with(\.$account)
            .first()
        else {
            throw Abort(.badRequest, reason: "Unknown device — call /account/bootstrap first.")
        }

        // 3. Is there already a canonical account for this Apple identity?
        if let existing = try await Account.query(on: req.db)
            .filter(\.$appleUserID == appleSub)
            .first()
        {
            guard let existingID = existing.id else {
                throw Abort(.internalServerError, reason: "Linked account missing id.")
            }

            // Already linked to the account this device is on → no-op, just return.
            if device.$account.id == existingID {
                req.logger.info("🍎 [apple-link] Device \(trimmedID) already on linked account \(existingID)")
                return AccountResponse(from: existing)
            }

            // Reassign this device to the canonical account. Its old anonymous
            // account is left as an orphan (S3 decides merge vs discard).
            let orphanID = device.$account.id
            device.$account.id = existingID
            device.lastSeenAt = Date()
            try await device.save(on: req.db)

            req.logger.info("🍎 [apple-link] Reassigned device \(trimmedID) from orphan \(orphanID) → canonical \(existingID)")
            return AccountResponse(from: existing)
        }

        // 4. First time this Apple identity is seen → link the device's current
        //    (anonymous) account in place.
        let account = device.account
        account.appleUserID = appleSub
        if let appleEmail, !appleEmail.isEmpty {
            account.appleEmail = appleEmail
        }
        account.statusValue = .linked
        try await account.save(on: req.db)

        device.lastSeenAt = Date()
        try await device.save(on: req.db)

        req.logger.info("🍎 [apple-link] Linked Apple identity to account \(account.id?.uuidString ?? "?")")
        return AccountResponse(from: account)
    }

    // MARK: - Helpers

    /// Opaque, URL-safe random token. Placeholder until full JWT sessions.
    static func makeSessionToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Response DTO

struct AccountResponse: Content {
    let accountID: UUID
    let status: String
    let displayName: String?
    let sessionToken: String

    init(accountID: UUID, status: String, displayName: String?, sessionToken: String) {
        self.accountID = accountID
        self.status = status
        self.displayName = displayName
        self.sessionToken = sessionToken
    }

    init(from account: Account) {
        self.accountID = account.id ?? UUID()
        self.status = account.status
        self.displayName = account.displayName
        self.sessionToken = account.sessionToken
    }
}
