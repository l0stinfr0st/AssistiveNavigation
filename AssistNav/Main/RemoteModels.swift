import Foundation
import SwiftUI
import UIKit

// MARK: - API rows (Postgres / PostgREST)

struct ProfileRow: Codable, Sendable {
    let id: UUID
    let username: String
    let email: String?
    let audioVolume: Double
    let speechRate: Double
    let voiceControlEnabled: Bool
    let spokenFeedbackEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, username, email
        case audioVolume = "audio_volume"
        case speechRate = "speech_rate"
        case voiceControlEnabled = "voice_control_enabled"
        case spokenFeedbackEnabled = "spoken_feedback_enabled"
    }
}

struct ProfileUpdate: Encodable, Sendable {
    let audioVolume: Double
    let speechRate: Double
    let voiceControlEnabled: Bool
    let spokenFeedbackEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case audioVolume = "audio_volume"
        case speechRate = "speech_rate"
        case voiceControlEnabled = "voice_control_enabled"
        case spokenFeedbackEnabled = "spoken_feedback_enabled"
    }
}

// MARK: - Local-only settings (not synced)

// Kept for backwards-compatibility if you later add more built-in profiles.
// The HRIR selection page uses the uploaded SOFA files (H5/H10/H20).
enum HRIRProfile: String, CaseIterable, Identifiable, Sendable {
    case natural = "Natural"
    case bright = "Bright"
    case warm = "Warm"
    case wide = "Wide"
    case focused = "Focused"

    var id: String { rawValue }
}

struct SpatialAudioTuning: Codable, Sendable, Equatable {
    var hrirProfileRaw: String
    var leftVolume: Double
    var rightVolume: Double
    var sweepDurationSeconds: Double
    var sensitivity: Double

    static let `default` = SpatialAudioTuning(
        hrirProfileRaw: "H5",
        leftVolume: 1.0,
        rightVolume: 1.0,
        sweepDurationSeconds: 0.8,
        sensitivity: 0.65
    )

    // When using uploaded HRIRs, this is expected to be "H5", "H10", or "H20".
}

struct HazardReportRow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let type: String
    let details: String
    let dangerLevel: String
    let persistenceLevel: String
    let photoJPEGBase64: String?
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    let expiresAt: Date?
    let acceptedAt: Date?
    let resolvedAt: Date?
    let confirmationCount: Int
    let resolveCount: Int
    let isAccepted: Bool
    let isResolved: Bool
    let reporterId: UUID?
    let reporterUsername: String
    let hasModernMetadata: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, details, latitude, longitude
        case dangerLevel = "danger_level"
        case persistenceLevel = "persistence_level"
        case photoJPEGBase64 = "photo_jpeg_base64"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case resolvedAt = "resolved_at"
        case confirmationCount = "confirmation_count"
        case resolveCount = "resolve_count"
        case isAccepted = "is_accepted"
        case isResolved = "is_resolved"
        case reporterId = "reporter_id"
        case reporterUsername = "reporter_username"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDangerLevel = try container.decodeIfPresent(String.self, forKey: .dangerLevel)
        let decodedPersistenceLevel = try container.decodeIfPresent(String.self, forKey: .persistenceLevel)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        dangerLevel = decodedDangerLevel ?? "Medium"
        persistenceLevel = decodedPersistenceLevel ?? "Medium"
        photoJPEGBase64 = try container.decodeIfPresent(String.self, forKey: .photoJPEGBase64)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        acceptedAt = try container.decodeIfPresent(Date.self, forKey: .acceptedAt)
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        confirmationCount = try container.decodeIfPresent(Int.self, forKey: .confirmationCount) ?? 0
        resolveCount = try container.decodeIfPresent(Int.self, forKey: .resolveCount) ?? 0
        isAccepted = try container.decodeIfPresent(Bool.self, forKey: .isAccepted) ?? false
        isResolved = try container.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
        reporterId = try container.decodeIfPresent(UUID.self, forKey: .reporterId)
        reporterUsername = try container.decodeIfPresent(String.self, forKey: .reporterUsername) ?? "Unknown"
        hasModernMetadata = decodedDangerLevel != nil || decodedPersistenceLevel != nil
    }
}

extension HazardReportRow {
    var statusLabel: String {
        if isResolved { return "Resolved" }
        if isAccepted { return "Accepted" }
        return "Pending"
    }

    var statusColor: Color {
        if isResolved { return .green }
        if isAccepted { return .orange }
        return .yellow
    }

    var previewImage: UIImage? {
        guard let photoJPEGBase64,
              let data = Data(base64Encoded: photoJPEGBase64) else { return nil }
        return UIImage(data: data)
    }
}

struct HazardInsert: Encodable, Sendable {
    let type: String
    let details: String
    let dangerLevel: String
    let persistenceLevel: String
    let photoJPEGBase64: String?
    let latitude: Double
    let longitude: Double
    let expiresAt: Date?
    let reporterId: UUID
    let reporterUsername: String

    enum CodingKeys: String, CodingKey {
        case type, details, latitude, longitude
        case dangerLevel = "danger_level"
        case persistenceLevel = "persistence_level"
        case photoJPEGBase64 = "photo_jpeg_base64"
        case expiresAt = "expires_at"
        case reporterId = "reporter_id"
        case reporterUsername = "reporter_username"
    }
}

struct HazardVoteInsert: Encodable, Sendable {
    let hazardId: UUID
    let userId: UUID
    let voteType: String

    enum CodingKeys: String, CodingKey {
        case hazardId = "hazard_id"
        case userId = "user_id"
        case voteType = "vote_type"
    }
}

struct HazardInsertLegacy: Encodable, Sendable {
    let type: String
    let details: String
    let latitude: Double
    let longitude: Double
    let reporterId: UUID
    let reporterUsername: String

    enum CodingKeys: String, CodingKey {
        case type, details, latitude, longitude
        case reporterId = "reporter_id"
        case reporterUsername = "reporter_username"
    }
}

struct NavigationSessionRow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let userId: UUID
    let startedAt: Date
    let endedAt: Date?
    let status: String
    let reportCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case status
        case reportCount = "report_count"
    }
}

struct NavigationSessionInsert: Encodable, Sendable {
    let userId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status
    }
}

struct NavigationSessionEndPatch: Encodable, Sendable {
    let endedAt: Date
    let status: String
    let reportCount: Int

    enum CodingKeys: String, CodingKey {
        case endedAt = "ended_at"
        case status
        case reportCount = "report_count"
    }
}

struct NavigationSessionReportPatch: Encodable, Sendable {
    let reportCount: Int

    enum CodingKeys: String, CodingKey {
        case reportCount = "report_count"
    }
}

// MARK: - Settings UI bindings

@MainActor
final class EditableProfile: ObservableObject {
    let id: UUID
    let username: String

    @Published var email: String?
    @Published var audioVolume: Double
    @Published var speechRate: Double
    @Published var voiceControlEnabled: Bool
    @Published var spokenFeedbackEnabled: Bool
    @Published var spatialAudio: SpatialAudioTuning

    init(row: ProfileRow) {
        self.id = row.id
        self.username = row.username
        self.email = row.email
        self.audioVolume = row.audioVolume
        self.speechRate = row.speechRate
        self.voiceControlEnabled = row.voiceControlEnabled
        self.spokenFeedbackEnabled = row.spokenFeedbackEnabled
        self.spatialAudio = Self.loadSpatialAudioTuning(userId: row.id)
    }

    func apply(row: ProfileRow) {
        email = row.email
        audioVolume = row.audioVolume
        speechRate = row.speechRate
        voiceControlEnabled = row.voiceControlEnabled
        spokenFeedbackEnabled = row.spokenFeedbackEnabled
        spatialAudio = Self.loadSpatialAudioTuning(userId: row.id)
    }

    func asUpdate() -> ProfileUpdate {
        ProfileUpdate(
            audioVolume: audioVolume,
            speechRate: speechRate,
            voiceControlEnabled: voiceControlEnabled,
            spokenFeedbackEnabled: spokenFeedbackEnabled
        )
    }

    func saveLocalSpatialAudioTuning() {
        Self.saveSpatialAudioTuning(spatialAudio, userId: id)
    }

    func reloadLocalSpatialAudioTuning() {
        spatialAudio = Self.loadSpatialAudioTuning(userId: id)
    }

    private static func tuningKey(userId: UUID) -> String {
        "spatial_audio_tuning.\(userId.uuidString.lowercased())"
    }

    private static func loadSpatialAudioTuning(userId: UUID) -> SpatialAudioTuning {
        let key = tuningKey(userId: userId)
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .default
        }
        return (try? JSONDecoder().decode(SpatialAudioTuning.self, from: data)) ?? .default
    }

    private static func saveSpatialAudioTuning(_ tuning: SpatialAudioTuning, userId: UUID) {
        let key = tuningKey(userId: userId)
        if let data = try? JSONEncoder().encode(tuning) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
