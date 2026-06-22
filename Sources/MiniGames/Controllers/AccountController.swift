import Vapor
import Fluent

// MARK: - AccountController (S1 — identity foundation)
//
// Routes:
//   POST /account/bootstrap   — first-launch shadow-account creation / lookup
//
// The bootstrap endpoint is idempotent: calling it repeatedly with the same
// clientPlayerID always returns the same account. The client calls it once on
// first launch (and may safely call it again — it won't create duplicates).

struct AccountController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let account = routes.grouped("account")
        account.post("bootstrap", use: bootstrap)
    }

    // MARK: - POST /account/bootstrap
    //
    // Body: { "clientPlayerID": "<the client's local UUID>", "displayName": "<optional>" }
    //
    // Behavior:
    //  • If a Device already exists for this clientPlayerID → return its account
    //    (idempotent; refresh last_seen_at and displayName if provided).
    //  • Otherwise → create a new ANONYMOUS Account + a Device mapping this
    //    clientPlayerID to it, and return that.
    //
    // Returns the canonical account id, status, and the opaque session token the
    // client should send on subsequent authenticated calls (S3). No real auth in
    // S1 — the token is a placeholder replaced by JWT in S2.

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

            // Refresh last-seen, and adopt a display name if one was provided
            // and we don't have one yet (cheap convenience; never overwrites).
            device.lastSeenAt = Date()
            try await device.save(on: req.db)

            if let name = body.displayName,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (account.displayName ?? "").isEmpty
            {
                account.displayName = name
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

        let device = Device(
            accountID: accountID,
            clientPlayerID: trimmedID,
            lastSeenAt: Date()
        )
        try await device.save(on: req.db)

        req.logger.info("🪪 [bootstrap] New anonymous account \(accountID) for device \(trimmedID)")
        return AccountResponse(from: account)
    }

    // MARK: - Helpers

    /// Opaque, URL-safe random token. Placeholder until JWT in S2.
    static func makeSessionToken() -> String {
        // 32 random bytes, base64url — plenty of entropy, no separators.
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