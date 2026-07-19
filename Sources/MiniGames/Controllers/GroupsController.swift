import Vapor
import Fluent

// MARK: - GroupsController
//
// Friend groups: private leaderboards joined via a shareable 6-character
// invite code. All routes sit behind AccountAuthMiddleware (so `req.account`
// is available).
//
//   POST /groups                       — create a group (creator auto-joins; max 10 owned)
//   GET  /groups                       — groups I'm a member of
//   POST /groups/join                  — join by invite code (409 already member / full at 50)
//   POST /groups/:groupID/leave        — leave; the owner leaving deletes the group
//   GET  /groups/:groupID/leaderboard  — members-only group leaderboard
//
// Leaderboard stats use the shared LeaderboardStats aggregation (same win
// convention + streak rules as the public /leaderboard).

struct GroupsController: RouteCollection {

    /// Most groups a single account may OWN.
    static let maxOwnedGroups = 10

    /// Most members a group may hold.
    static let maxGroupSize = 50

    func boot(routes: any RoutesBuilder) throws {
        let groups = routes
            .grouped("groups")
            .grouped(AccountAuthMiddleware())
        groups.post(use: create)
        groups.get(use: index)
        groups.post("join", use: join)
        groups.post(":groupID", "leave", use: leave)
        groups.get(":groupID", "leaderboard", use: leaderboard)
    }

    // MARK: - POST /groups
    //
    // Body: { "name": "Word Warriors", "icon": "crown", "color": "#FFD700" }
    // The creator becomes the owner and auto-joins as the first member.

    func create(req: Request) async throws -> Response {
        struct Body: Content {
            let name: String
            let icon: String
            let color: String
        }
        let body = try req.content.decode(Body.self)
        let accountID = try req.account.requireID()

        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Group name is required.")
        }
        guard name.count <= 30 else {
            throw Abort(.badRequest, reason: "Group name must be 30 characters or fewer.")
        }

        let ownedCount = try await FriendGroup.query(on: req.db)
            .filter(\.$owner.$id == accountID)
            .count()
        guard ownedCount < Self.maxOwnedGroups else {
            throw Abort(.conflict, reason: "You can own at most \(Self.maxOwnedGroups) groups.")
        }

        let inviteCode = try await Self.generateUniqueInviteCode(on: req.db)

        let group = FriendGroup(
            name: name,
            icon: body.icon,
            color: body.color,
            inviteCode: inviteCode,
            ownerID: accountID
        )
        try await group.save(on: req.db)

        // Creator auto-joins.
        let membership = FriendGroupMember(
            groupID: try group.requireID(),
            accountID: accountID
        )
        try await membership.save(on: req.db)

        let dto = groupDTO(group, memberCount: 1, viewerID: accountID)
        let response = Response(status: .created)
        try response.content.encode(dto)
        return response
    }

    // MARK: - GET /groups
    //
    // Every group I'm a member of, oldest-created first.

    func index(req: Request) async throws -> [GroupDTO] {
        let accountID = try req.account.requireID()

        let memberships = try await FriendGroupMember.query(on: req.db)
            .filter(\.$account.$id == accountID)
            .all()
        let groupIDs = memberships.map { $0.$group.id }
        guard !groupIDs.isEmpty else { return [] }

        let groups = try await FriendGroup.query(on: req.db)
            .filter(\.$id ~~ groupIDs)
            .all()
        let counts = try await memberCounts(for: groupIDs, on: req.db)

        return groups
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            .compactMap { group in
                guard let groupID = group.id else { return nil }
                return groupDTO(
                    group,
                    memberCount: counts[groupID] ?? 0,
                    viewerID: accountID
                )
            }
    }

    // MARK: - POST /groups/join
    //
    // Body: { "inviteCode": "K7PM3X" }

    func join(req: Request) async throws -> GroupDTO {
        struct Body: Content {
            let inviteCode: String
        }
        let body = try req.content.decode(Body.self)
        let accountID = try req.account.requireID()

        let code = body.inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !code.isEmpty else {
            throw Abort(.badRequest, reason: "inviteCode is required.")
        }

        guard let group = try await FriendGroup.query(on: req.db)
            .filter(\.$inviteCode == code)
            .first()
        else {
            throw Abort(.notFound, reason: "No group with that invite code.")
        }
        let groupID = try group.requireID()

        let existing = try await FriendGroupMember.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$account.$id == accountID)
            .first()
        guard existing == nil else {
            throw Abort(.conflict, reason: "You're already a member of this group.")
        }

        let memberCount = try await FriendGroupMember.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .count()
        guard memberCount < Self.maxGroupSize else {
            throw Abort(.conflict, reason: "This group is full.")
        }

        let membership = FriendGroupMember(groupID: groupID, accountID: accountID)
        try await membership.save(on: req.db)

        return groupDTO(group, memberCount: memberCount + 1, viewerID: accountID)
    }

    // MARK: - POST /groups/:groupID/leave
    //
    // A regular member leaving deletes their membership row. The OWNER leaving
    // deletes the whole group (memberships cascade away with it).

    func leave(req: Request) async throws -> HTTPStatus {
        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group id.")
        }
        let accountID = try req.account.requireID()

        guard let group = try await FriendGroup.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found.")
        }

        if group.$owner.id == accountID {
            // Owner leaving dissolves the group; the FK cascade removes members.
            try await group.delete(on: req.db)
            return .noContent
        }

        guard let membership = try await FriendGroupMember.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$account.$id == accountID)
            .first()
        else {
            throw Abort(.forbidden, reason: "You are not a member of this group.")
        }

        try await membership.delete(on: req.db)
        return .noContent
    }

    // MARK: - GET /groups/:groupID/leaderboard
    //
    // Members only. One entry per member (zeros for members with no games),
    // ranked by wins desc with the same tie-breaks as /leaderboard.

    func leaderboard(req: Request) async throws -> GroupLeaderboardResponse {
        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group id.")
        }
        let accountID = try req.account.requireID()

        guard let group = try await FriendGroup.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found.")
        }

        let memberships = try await FriendGroupMember.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .all()
        let memberIDs = memberships.map { $0.$account.id }
        guard memberIDs.contains(accountID) else {
            throw Abort(.forbidden, reason: "You are not a member of this group.")
        }

        let accountsByID = try await accountsKeyedByID(memberIDs, on: req.db)
        let lines = try await LeaderboardStats.lines(for: memberIDs, on: req.db)

        let entries = memberIDs
            .map { memberID -> LeaderboardEntry in
                let line = lines[memberID] ?? LeaderboardStats.AccountLine()
                return LeaderboardEntry(
                    displayName: displayNameOrFallback(accountsByID[memberID]?.displayName),
                    wins: line.won,
                    gamesPlayed: line.played,
                    streak: line.streak
                )
            }
            .sorted {
                if $0.wins != $1.wins { return $0.wins > $1.wins }
                if $0.gamesPlayed != $1.gamesPlayed { return $0.gamesPlayed > $1.gamesPlayed }
                return $0.displayName < $1.displayName
            }

        return GroupLeaderboardResponse(
            group: groupDTO(group, memberCount: memberships.count, viewerID: accountID),
            entries: entries
        )
    }

    // MARK: - Invite-code generation

    /// Generates an invite code that isn't already taken. Retries on collision
    /// (the unique index on friend_groups.invite_code is the backstop for
    /// concurrent races).
    static func generateUniqueInviteCode(on db: any Database) async throws -> String {
        for _ in 0..<8 {
            let candidate = FriendCodeGenerator.generate()
            let clash = try await FriendGroup.query(on: db)
                .filter(\.$inviteCode == candidate)
                .first()
            if clash == nil { return candidate }
        }
        throw Abort(.internalServerError, reason: "Could not generate a unique invite code.")
    }

    // MARK: - Helpers

    private func groupDTO(_ group: FriendGroup, memberCount: Int, viewerID: UUID) -> GroupDTO {
        GroupDTO(
            groupID: group.id ?? UUID(),
            name: group.name,
            icon: group.icon,
            color: group.color,
            inviteCode: group.inviteCode,
            memberCount: memberCount,
            isOwner: group.$owner.id == viewerID
        )
    }

    /// Member counts per group id.
    private func memberCounts(for groupIDs: [UUID], on db: any Database) async throws -> [UUID: Int] {
        guard !groupIDs.isEmpty else { return [:] }
        let rows = try await FriendGroupMember.query(on: db)
            .filter(\.$group.$id ~~ Array(Set(groupIDs)))
            .all()
        var counts: [UUID: Int] = [:]
        for row in rows {
            counts[row.$group.id, default: 0] += 1
        }
        return counts
    }

    /// Batch-load accounts and key them by id.
    private func accountsKeyedByID(_ ids: [UUID], on db: any Database) async throws -> [UUID: Account] {
        guard !ids.isEmpty else { return [:] }
        let accounts = try await Account.query(on: db)
            .filter(\.$id ~~ Array(Set(ids)))
            .all()
        var byID: [UUID: Account] = [:]
        for account in accounts {
            if let id = account.id { byID[id] = account }
        }
        return byID
    }

    private func displayNameOrFallback(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player" : trimmed
    }
}

// MARK: - Response DTOs

struct GroupDTO: Content {
    let groupID: UUID
    let name: String
    let icon: String
    let color: String
    let inviteCode: String
    let memberCount: Int
    let isOwner: Bool
}

struct GroupLeaderboardResponse: Content {
    let group: GroupDTO
    let entries: [LeaderboardEntry]
}
