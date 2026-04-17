import SwiftUI
import CoreLocation
import Supabase

enum AuthMode {
    case login
    case register
}

enum AppScreen {
    case main
    case navigation
    case report
    case map
}

enum MainTab: Hashable {
    case home
    case reports
    case history
    case settings
}

enum ReportFlowSource {
    case home
    case navigation
}

@MainActor
final class AppViewModel: ObservableObject {

    let client: SupabaseClient
    let location = LocationService()
    @Published var profile: EditableProfile?
    @Published var authMode: AuthMode = .login
    @Published var currentScreen: AppScreen = .main
    @Published var mainTab: MainTab = .home

    @Published var usernameOrEmail = ""
    @Published var password = ""
    @Published var registerUsername = ""
    @Published var registerEmail = ""
    @Published var registerPassword = ""
    @Published var registerConfirmPassword = ""

    @Published var bannerMessage: String?

    @Published var isNavigating = false
    @Published var navigationPausedForReport = false
    @Published var liveNavigationStatusLine = ""
    @Published var simulatedAheadDistanceMeters: Double = 1.8

    @Published var reportFlowSource: ReportFlowSource = .home

    /// All hazards (public read) for map and Reports tab.
    @Published var hazardReports: [HazardReportRow] = []
    /// Current user’s reports for History.
    @Published var myHazardReports: [HazardReportRow] = []
    @Published var myNavigationSessions: [NavigationSessionRow] = []

    private var activeRemoteSessionId: UUID?
    private var activeSessionReportCount: Int = 0
    private var liveNavigationTask: Task<Void, Never>?

    private let briefingRadiusMeters: CLLocationDistance = 800

    init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
    }

    func bootstrap() async {
        location.requestWhenInUse()
        location.startUpdatingIfAllowed()

        await refreshPublicHazards()

        do {
            _ = try await client.auth.session
            try await reloadSessionProfile()
        } catch {
            profile = nil
        }
    }

    private func reloadSessionProfile() async throws {
        let session = try await client.auth.session
        let row = try await fetchProfile(userId: session.user.id)
        profile = EditableProfile(row: row)
    }

    private func fetchProfile(userId: UUID) async throws -> ProfileRow {
        try await client
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
    }

    func refreshPublicHazards() async {
        do {
            let rows: [HazardReportRow] = try await client
                .from("hazard_reports")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            let now = Date()
            hazardReports = rows.filter { report in
                report.hasModernMetadata &&
                !report.isResolved &&
                (report.expiresAt == nil || report.expiresAt! > now)
            }
        } catch {
            hazardReports = []
        }
    }

    func refreshMyHistory() async {
        guard let uid = profile?.id else {
            myHazardReports = []
            myNavigationSessions = []
            return
        }
        do {
            let hazards: [HazardReportRow] = try await client
                .from("hazard_reports")
                .select()
                .eq("reporter_id", value: uid.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
            myHazardReports = hazards

            let sessions: [NavigationSessionRow] = try await client
                .from("navigation_sessions")
                .select()
                .eq("user_id", value: uid.uuidString.lowercased())
                .order("started_at", ascending: false)
                .execute()
                .value
            myNavigationSessions = sessions
        } catch {
            myHazardReports = []
            myNavigationSessions = []
        }
    }

    // MARK: - Spoken UI feedback

    func announceToUser(_ message: String) {}

    // MARK: - Auth

    func switchToRegister() {
        authMode = .register
        bannerMessage = nil
    }

    func switchToLogin() {
        authMode = .login
        bannerMessage = nil
    }

    /// No email/password: Supabase anonymous user (enable Anonymous in Dashboard → Authentication → Providers).
    func continueAsGuest() {
        Task { await continueAsGuestAsync() }
    }

    private func continueAsGuestAsync() async {
        bannerMessage = nil
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let guestUsername = "guest_\(suffix)"
        do {
            _ = try await client.auth.signInAnonymously(
                data: ["username": .string(String(guestUsername))]
            )
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                do {
                    try await reloadSessionProfile()
                    await refreshPublicHazards()
                    await refreshMyHistory()
                    announceToUser("Continuing as guest.")
                    return
                } catch {
                    continue
                }
            }
            bannerMessage = "Guest session started but profile is still loading. Wait a moment or restart the app."
            announceToUser(bannerMessage!)
        } catch {
            let msg: String
            if let auth = error as? AuthError,
               case let .api(_, code, _, _) = auth,
               code == .anonymousProviderDisabled
            {
                msg = "Guest sign-in is off in your project. Supabase → Authentication → Providers → turn on Anonymous sign-ins."
            } else if let auth = error as? AuthError {
                msg = auth.message
            } else {
                msg = "Could not start a guest session. Check your network."
            }
            bannerMessage = msg
            announceToUser(msg)
        }
    }

    func login() {
        Task { await loginAsync() }
    }

    private func loginAsync() async {
        bannerMessage = nil
        let email = usernameOrEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pw = password
        guard !email.isEmpty, !pw.isEmpty else {
            bannerMessage = "Enter your email and password."
            announceToUser(bannerMessage!)
            return
        }

        do {
            try await client.auth.signIn(email: email, password: pw)
            try await reloadSessionProfile()
            password = ""
            await refreshPublicHazards()
            await refreshMyHistory()
            announceToUser("Signed in as \(profile?.username ?? "account").")
        } catch {
            bannerMessage = "Could not sign in. Confirm your email link if you just registered, then try again."
            announceToUser(bannerMessage!)
        }
    }

    func register() {
        Task { await registerAsync() }
    }

    private func registerAsync() async {
        bannerMessage = nil
        let u = registerUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let e = registerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let p1 = registerPassword
        let p2 = registerConfirmPassword

        guard !u.isEmpty, !e.isEmpty, !p1.isEmpty else {
            bannerMessage = "Fill in all registration fields."
            announceToUser(bannerMessage!)
            return
        }

        guard p1 == p2 else {
            bannerMessage = "Passwords do not match."
            announceToUser(bannerMessage!)
            return
        }

        guard p1.count >= 8 else {
            bannerMessage = "Password must be at least eight characters."
            announceToUser(bannerMessage!)
            return
        }

        // Best-effort duplicate check only. If anon users cannot SELECT profiles (RLS), we still sign up;
        // the DB trigger + unique constraint enforce username rules.
        var usernameTaken = false
        do {
            let taken: [ProfileRow] = try await client
                .from("profiles")
                .select()
                .eq("username", value: u)
                .limit(1)
                .execute()
                .value
            usernameTaken = !taken.isEmpty
        } catch {
            usernameTaken = false
        }
        if usernameTaken {
            bannerMessage = "That username is already taken."
            announceToUser(bannerMessage!)
            return
        }

        do {
            let response = try await client.auth.signUp(
                email: e,
                password: p1,
                data: ["username": .string(u)]
            )

            let hasSession = response.session != nil

            if hasSession {
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    do {
                        let session = try await client.auth.session
                        let row = try await fetchProfile(userId: session.user.id)
                        profile = EditableProfile(row: row)
                        registerPassword = ""
                        registerConfirmPassword = ""
                        await refreshPublicHazards()
                        await refreshMyHistory()
                        announceToUser("Welcome, \(row.username).")
                        return
                    } catch {
                        continue
                    }
                }
                bannerMessage = "Account created. Open Settings after a moment, or sign out and sign in if your profile is still loading."
                announceToUser(bannerMessage!)
            } else {
                profile = nil
                registerPassword = ""
                registerConfirmPassword = ""
                bannerMessage = "Check your email and confirm your address, then sign in here."
                announceToUser("Confirmation email sent. Open the link, then sign in.")
            }
        } catch {
            let msg = Self.registerFailureMessage(for: error)
            bannerMessage = msg
            announceToUser(msg)
        }
    }

    private static func registerFailureMessage(for error: Error) -> String {
        guard let auth = error as? AuthError else {
            return "Could not register. Check your network and try again."
        }
        switch auth {
        case let .weakPassword(message, _):
            return message
        case let .api(_, code, _, _):
            if code == .emailExists || code == .userAlreadyExists {
                return "That email is already registered. Try signing in instead."
            }
            if code == .signupDisabled {
                return "New sign-ups are disabled on the server."
            }
            if code == .weakPassword {
                return auth.message
            }
            return auth.message
        default:
            return auth.message
        }
    }

    func logout() {
        Task {
            stopNavigationInternal()
            try? await client.auth.signOut()
            profile = nil
            currentScreen = .main
            mainTab = .home
            authMode = .login
            activeRemoteSessionId = nil
            myHazardReports = []
            myNavigationSessions = []
            await refreshPublicHazards()
        }
    }

    // MARK: - Navigation flow

    func startNavigation() {
        Task { await beginNavigationWithBriefing() }
    }

    private func beginNavigationWithBriefing() async {
        guard let user = profile else { return }

        if !location.servicesEnabled {
            bannerMessage = "Location services are off on this device."
            announceToUser(bannerMessage!)
            return
        }

        switch location.authorizationStatus {
        case .denied, .restricted:
            bannerMessage = "Location permission is required for navigation and hazard reporting. Enable it in Settings."
            announceToUser(bannerMessage!)
            return
        case .notDetermined:
            location.requestWhenInUse()
            bannerMessage = "Please allow location access, then try starting navigation again."
            announceToUser(bannerMessage!)
            return
        default:
            break
        }

        location.startUpdatingIfAllowed()
        try? await Task.sleep(nanoseconds: 400_000_000)

        guard let coord = location.lastLocation?.coordinate else {
            bannerMessage = "GPS position not available yet. Move to an open area and try again."
            announceToUser(bannerMessage!)
            return
        }

        let briefing = buildBriefingNearUser(coordinate: coord)
        _ = briefing

        do {
            let inserted: NavigationSessionRow = try await client
                .from("navigation_sessions")
                .insert(NavigationSessionInsert(userId: user.id, status: "Active"))
                .select()
                .single()
                .execute()
                .value
            activeRemoteSessionId = inserted.id
            activeSessionReportCount = inserted.reportCount
        } catch {
            bannerMessage = "Could not start a navigation session online."
            announceToUser(bannerMessage!)
            return
        }

        isNavigating = true
        navigationPausedForReport = false
        currentScreen = .navigation
        startLiveNavigationLoop()
        announceToUser("Navigation started.")
        await refreshMyHistory()
    }

    private func buildBriefingNearUser(coordinate: CLLocationCoordinate2D) -> String {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let nearby = hazardReports.filter {
            let there = CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            return there.distance(from: here) <= briefingRadiusMeters
        }

        if nearby.isEmpty {
            return "Route briefing. No reported hazards are on file within roughly \(Int(briefingRadiusMeters)) meters of your position. Live obstacle guidance will continue during your walk."
        }

        var counts: [String: Int] = [:]
        for r in nearby {
            counts[r.type, default: 0] += 1
        }
        let parts = counts.map { "\($0.value) \($0.key.lowercased())" }.sorted()
        let summary = parts.joined(separator: ", ")
        return "Route briefing. Ahead on community reports near you: \(summary). Live navigation will now focus on real-time obstacles only."
    }

    private func startLiveNavigationLoop() {
        liveNavigationTask?.cancel()
        liveNavigationTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    guard self.isNavigating, !self.navigationPausedForReport else { return }
                    tick += 1
                    let cues = [
                        "Path clear. Continue forward.",
                        "Slight adjustment to the right.",
                        "Obstacle passing on the left.",
                    ]
                    let line = cues[tick % cues.count]
                    self.liveNavigationStatusLine = line
                    self.simulatedAheadDistanceMeters = tick % 3 == 0 ? 2.1 : 1.8
                }
            }
        }
    }

    func stopNavigation() {
        stopNavigationInternal()
        currentScreen = .main
        announceToUser("Navigation stopped.")
        Task { await refreshMyHistory() }
    }

    private func stopNavigationInternal() {
        liveNavigationTask?.cancel()
        liveNavigationTask = nil
        isNavigating = false
        navigationPausedForReport = false

        if let sid = activeRemoteSessionId {
            let count = activeSessionReportCount
            Task {
                try? await client
                    .from("navigation_sessions")
                    .update(
                        NavigationSessionEndPatch(
                            endedAt: Date(),
                            status: "Completed",
                            reportCount: count
                        )
                    )
                    .eq("id", value: sid.uuidString.lowercased())
                    .execute()
            }
        }
        activeRemoteSessionId = nil
        activeSessionReportCount = 0
        liveNavigationStatusLine = ""
    }

    func openMap() {
        bannerMessage = nil
        currentScreen = .map
        Task { await refreshPublicHazards() }
    }

    func openReportFromHome() {
        reportFlowSource = .home
        presentReport()
    }

    func openReportFromNavigation() {
        reportFlowSource = .navigation
        navigationPausedForReport = true
        presentReport()
    }

    private func presentReport() {
        bannerMessage = nil
        primeLocationForReport()
        currentScreen = .report
    }

    func primeLocationForReport() {
        location.requestWhenInUse()
        location.startUpdatingIfAllowed()
    }

    func cancelReportFlow() {
        resumeNavigationIfNeeded()
        announceToUser("Report canceled.")
    }

    func submitReport(
        type: String,
        details: String,
        dangerLevel: String,
        persistenceLevel: String,
        photoJPEGBase64: String?
    ) async {
        guard let user = profile else { return }

        if !location.servicesEnabled {
            bannerMessage = "Location services are turned off. Turn them on to save where the hazard is."
            announceToUser(bannerMessage!)
            return
        }

        location.requestWhenInUse()

        if location.authorizationStatus == .notDetermined {
            let authDeadline = Date().addingTimeInterval(45)
            while location.authorizationStatus == .notDetermined, Date() < authDeadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        switch location.authorizationStatus {
        case .denied, .restricted:
            bannerMessage = "Location permission is needed to attach GPS to your report. Enable it in Settings."
            announceToUser(bannerMessage!)
            return
        default:
            break
        }

        guard let loc = await location.acquireBestEffortLocation() else {
            bannerMessage = "Could not get your GPS position yet. Step outside or wait a few seconds and try again."
            announceToUser(bannerMessage!)
            return
        }

        let insertResult: (report: HazardReportRow?, usedLegacySchema: Bool)

        do {
            let expiresAt = Self.expiryDate(for: persistenceLevel)
            insertResult = try await insertHazardReport(
                type: type,
                details: details,
                dangerLevel: dangerLevel,
                persistenceLevel: persistenceLevel,
                photoJPEGBase64: photoJPEGBase64,
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                expiresAt: expiresAt,
                userId: user.id,
                username: user.username
            )

            if let inserted = insertResult.report {
                _ = try? await client
                    .from("hazard_report_votes")
                    .insert(
                        HazardVoteInsert(
                            hazardId: inserted.id,
                            userId: user.id,
                            voteType: "confirm"
                        )
                    )
                    .execute()
            }

            if activeRemoteSessionId != nil {
                activeSessionReportCount += 1
                let c = activeSessionReportCount
                if let sid = activeRemoteSessionId {
                    _ = try? await client
                        .from("navigation_sessions")
                        .update(NavigationSessionReportPatch(reportCount: c))
                        .eq("id", value: sid.uuidString.lowercased())
                        .execute()
                }
            }
        } catch {
            bannerMessage = Self.hazardSubmissionMessage(for: error)
            announceToUser(bannerMessage!)
            return
        }

        bannerMessage = insertResult.usedLegacySchema
            ? "Hazard report saved, but the database is still using the older schema. Run the latest Supabase SQL to enable danger, persistence, photos, and voting."
            : "Hazard report saved using your current location."
        announceToUser("Hazard report saved for \(type) at your current GPS position.")
        await refreshPublicHazards()
        await refreshMyHistory()
        resumeNavigationIfNeeded()
    }

    func confirmHazard(_ report: HazardReportRow) {
        Task { await voteOnHazard(report, voteType: "confirm") }
    }

    func resolveHazard(_ report: HazardReportRow) {
        Task { await voteOnHazard(report, voteType: "resolve") }
    }

    private func voteOnHazard(_ report: HazardReportRow, voteType: String) async {
        guard let user = profile else { return }

        do {
            try await client
                .from("hazard_report_votes")
                .insert(
                    HazardVoteInsert(
                        hazardId: report.id,
                        userId: user.id,
                        voteType: voteType
                    )
                )
                .execute()

            bannerMessage = voteType == "resolve"
                ? "Resolve vote submitted."
                : "Confirmation vote submitted."
            await refreshPublicHazards()
            await refreshMyHistory()
        } catch {
            bannerMessage = Self.hazardVoteMessage(for: error, voteType: voteType)
        }
    }

    private func resumeNavigationIfNeeded() {
        if reportFlowSource == .navigation, isNavigating {
            currentScreen = .navigation
            navigationPausedForReport = false
            announceToUser("Resuming navigation.")
        } else {
            currentScreen = .main
        }
    }

    func closeMap() {
        bannerMessage = nil
        currentScreen = .main
    }

    func selectSettingsTab() {
        currentScreen = .main
        mainTab = .settings
    }

    func savePreferencesFromSettings() {
        guard let p = profile else { return }
        Task {
            do {
                try await client
                    .from("profiles")
                    .update(p.asUpdate())
                    .eq("id", value: p.id.uuidString.lowercased())
                    .execute()
                if let row = try? await fetchProfile(userId: p.id) {
                    p.apply(row: row)
                }
                p.saveLocalSpatialAudioTuning()
                announceToUser("Preferences saved.")
            } catch {
                bannerMessage = "Could not save preferences online."
                announceToUser(bannerMessage!)
            }
        }
    }

    func cancelSettingsEdits() {
        guard let p = profile else { return }
        Task {
            do {
                let row = try await fetchProfile(userId: p.id)
                p.apply(row: row)
                p.reloadLocalSpatialAudioTuning()
                announceToUser("Changes discarded.")
            } catch {
                announceToUser("Could not reload settings.")
            }
        }
    }

    private static func expiryDate(for persistenceLevel: String) -> Date? {
        switch persistenceLevel.lowercased() {
        case "temporary":
            return Date().addingTimeInterval(4 * 60 * 60)
        case "short":
            return Date().addingTimeInterval(24 * 60 * 60)
        case "medium":
            return Date().addingTimeInterval(7 * 24 * 60 * 60)
        case "long":
            return Date().addingTimeInterval(30 * 24 * 60 * 60)
        default:
            return nil
        }
    }

    private func insertHazardReport(
        type: String,
        details: String,
        dangerLevel: String,
        persistenceLevel: String,
        photoJPEGBase64: String?,
        latitude: Double,
        longitude: Double,
        expiresAt: Date?,
        userId: UUID,
        username: String
    ) async throws -> (report: HazardReportRow?, usedLegacySchema: Bool) {
        do {
            let inserted: HazardReportRow = try await client
                .from("hazard_reports")
                .insert(
                    HazardInsert(
                        type: type,
                        details: details,
                        dangerLevel: dangerLevel,
                        persistenceLevel: persistenceLevel,
                        photoJPEGBase64: photoJPEGBase64,
                        latitude: latitude,
                        longitude: longitude,
                        expiresAt: expiresAt,
                        reporterId: userId,
                        reporterUsername: username
                    )
                )
                .select()
                .single()
                .execute()
                .value
            return (inserted, false)
        } catch {
            let legacyInserted: HazardReportRow = try await client
                .from("hazard_reports")
                .insert(
                    HazardInsertLegacy(
                        type: type,
                        details: details,
                        latitude: latitude,
                        longitude: longitude,
                        reporterId: userId,
                        reporterUsername: username
                    )
                )
                .select()
                .single()
                .execute()
                .value
            return (legacyInserted, true)
        }
    }

    private static func hazardSubmissionMessage(for error: Error) -> String {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("row-level security") {
            return "Could not save the hazard report because the database rejected your session. Try signing out and back in."
        }
        if text.localizedCaseInsensitiveContains("column") || text.localizedCaseInsensitiveContains("schema") {
            return "The app expects the updated hazard schema. Run the latest Supabase SQL migration, then try again."
        }
        return "Could not save the hazard report. \(text)"
    }

    private static func hazardVoteMessage(for error: Error, voteType: String) -> String {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("relation") || text.localizedCaseInsensitiveContains("schema") {
            return "Voting needs the updated Supabase schema. Run the latest SQL migration first."
        }
        if text.localizedCaseInsensitiveContains("duplicate") || text.localizedCaseInsensitiveContains("unique") {
            return voteType == "resolve"
                ? "You already submitted a resolve vote for this hazard."
                : "You already confirmed this hazard."
        }
        return voteType == "resolve"
            ? "Could not submit resolve vote."
            : "Could not submit confirmation vote."
    }
}
