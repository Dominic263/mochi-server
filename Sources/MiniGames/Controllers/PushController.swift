import Vapor
import Fluent

// MARK: - PushController
//
// APNs device-token registration.
//
//   POST /push/register — upsert this install's APNs token onto its account
//
// Deliberately NOT behind AccountAuthMiddleware: the client registers its
// token right after the system permission prompt, which can happen before it
// holds a session token. Identity is resolved the same way the game endpoints
// do it — via the install's Device.clientPlayerID (the client's local UUID).

struct PushController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let push = routes.grouped("push")
        push.post("register", use: register)
    }

    // MARK: - POST /push/register
    //
    // Body: { "playerID": "<local UUID>", "token": "<hex APNs token>", "sandbox": false }
    //
    // Upserts by token: a token already on file is moved/refreshed onto the
    // calling install's account (covers account reassignment after Apple
    // sign-in). 404 if the install never bootstrapped a device.

    func register(req: Request) async throws -> HTTPStatus {
        struct Body: Content {
            let playerID: String
            let token: String
            let sandbox: Bool
        }
        let body = try req.content.decode(Body.self)

        let playerID = body.playerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = body.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !playerID.isEmpty, !token.isEmpty else {
            throw Abort(.badRequest, reason: "playerID and token are required.")
        }

        // Resolve the account through the install's device row (same pattern
        // as the game endpoints).
        guard let device = try await Device.query(on: req.db)
            .filter(\.$clientPlayerID == playerID)
            .first()
        else {
            throw Abort(.notFound, reason: "Unknown device — call /account/bootstrap first.")
        }
        let accountID = device.$account.id

        if let existing = try await PushToken.query(on: req.db)
            .filter(\.$token == token)
            .first()
        {
            existing.$account.id = accountID
            existing.isSandbox = body.sandbox
            try await existing.save(on: req.db)
        } else {
            let row = PushToken(accountID: accountID, token: token, isSandbox: body.sandbox)
            try await row.save(on: req.db)
        }

        req.logger.info("📣 [push] Registered \(body.sandbox ? "sandbox" : "production") token for account \(accountID)")
        return .noContent
    }
}
