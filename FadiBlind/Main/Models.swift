import Foundation
import SwiftData
import CryptoKit

@Model
final class AppUser {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var username: String
    @Attribute(.unique) var email: String
    var passwordSalt: String
    var passwordHash: String

    var audioVolume: Double
    var speechRate: Double
    var voiceControlEnabled: Bool
    var spokenFeedbackEnabled: Bool

    init(username: String, email: String, plainPassword: String) {
        self.id = UUID()
        self.username = username
        self.email = email.lowercased()
        self.passwordSalt = ""
        self.passwordHash = ""
        self.audioVolume = 1.0
        self.speechRate = 0.5
        self.voiceControlEnabled = true
        self.spokenFeedbackEnabled = true
        applyPassword(plainPassword)
    }

    func applyPassword(_ plain: String) {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        passwordSalt = salt.base64EncodedString()
        passwordHash = Self.hashPassword(plain, salt: salt)
    }

    func matchesPassword(_ plain: String) -> Bool {
        guard let salt = Data(base64Encoded: passwordSalt) else { return false }
        return Self.hashPassword(plain, salt: salt) == passwordHash
    }

    private static func hashPassword(_ plain: String, salt: Data) -> String {
        let combined = salt + Data(plain.utf8)
        let digest = SHA256.hash(data: combined)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@Model
final class HazardReport {
    var id: UUID
    var type: String
    var details: String
    var latitude: Double
    var longitude: Double
    var createdAt: Date

    var reportingUserID: UUID
    var reportingUsername: String

    init(
        type: String,
        details: String,
        latitude: Double,
        longitude: Double,
        reportingUserID: UUID,
        reportingUsername: String
    ) {
        self.id = UUID()
        self.type = type
        self.details = details
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = Date()
        self.reportingUserID = reportingUserID
        self.reportingUsername = reportingUsername
    }
}

@Model
final class NavigationSession {
    var id: UUID
    var userID: UUID
    var startedAt: Date
    var endedAt: Date?
    var status: String
    var reportCount: Int

    init(userID: UUID) {
        self.id = UUID()
        self.userID = userID
        self.startedAt = Date()
        self.endedAt = nil
        self.status = "Active"
        self.reportCount = 0
    }
}
