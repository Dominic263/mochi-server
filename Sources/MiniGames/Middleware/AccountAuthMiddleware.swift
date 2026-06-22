import Vapor
import Fluent

// MARK: - AccountAuthMiddleware  (S3)
//
// Minimal bearer-token auth. Reads `Authorization: Bearer <sessionToken>`,
// looks up the Account that owns that opaque token, and stashes it on the
// request so downstream handlers can read `req.account`. Rejects with 401 if
// the header is missing or the token doesn't match an account.
//
// This is intentionally simple — the opaque session token is a placeholder that
// a later version will replace/augment with a proper signed (JWT) session. For
// now it's enough to authenticate S3's read endpoints (your stats / history).

struct AccountAuthMiddleware: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token,
              !token.isEmpty
        else {
            throw Abort(.unauthorized, reason: "Missing bearer token.")
        }

        guard let account = try await Account.query(on: request.db)
            .filter(\.$sessionToken == token)
            .first()
        else {
            throw Abort(.unauthorized, reason: "Invalid session token.")
        }

        request.storage[AccountKey.self] = account
        return try await next.respond(to: request)
    }
}

// MARK: - Request.account accessor

private struct AccountKey: StorageKey {
    typealias Value = Account
}

extension Request {
    /// The authenticated account, set by AccountAuthMiddleware. Force-access
    /// only inside routes guarded by that middleware.
    var account: Account {
        guard let account = storage[AccountKey.self] else {
            fatalError("Request.account accessed without AccountAuthMiddleware in the route group.")
        }
        return account
    }

    /// Safe optional variant.
    var accountIfPresent: Account? {
        storage[AccountKey.self]
    }
}
