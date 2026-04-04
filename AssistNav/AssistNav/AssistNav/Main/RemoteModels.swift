import Foundation

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

struct HazardReportRow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let type: String
    let details: String
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    let reporterId: UUID?
    let reporterUsername: String

    enum CodingKeys: String, CodingKey {
        case id, type, details, latitude, longitude
        case createdAt = "created_at"
        case reporterId = "reporter_id"
        case reporterUsername = "reporter_username"
    }
}

struct HazardInsert: Encodable, Sendable {
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

    init(row: ProfileRow) {
        self.id = row.id
        self.username = row.username
        self.email = row.email
        self.audioVolume = row.audioVolume
        self.speechRate = row.speechRate
        self.voiceControlEnabled = row.voiceControlEnabled
        self.spokenFeedbackEnabled = row.spokenFeedbackEnabled
    }

    func apply(row: ProfileRow) {
        email = row.email
        audioVolume = row.audioVolume
        speechRate = row.speechRate
        voiceControlEnabled = row.voiceControlEnabled
        spokenFeedbackEnabled = row.spokenFeedbackEnabled
    }

    func asUpdate() -> ProfileUpdate {
        ProfileUpdate(
            audioVolume: audioVolume,
            speechRate: speechRate,
            voiceControlEnabled: voiceControlEnabled,
            spokenFeedbackEnabled: spokenFeedbackEnabled
        )
    }
}
