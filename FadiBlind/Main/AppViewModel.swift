import SwiftUI
import SwiftData
import CoreLocation

enum AuthMode {
    case login
    case register
}

enum AppScreen {
    case main
    case navigation
    case report
    case map
    case settings
}

enum MainTab: Hashable {
    case home
    case reports
    case history
}

enum ReportFlowSource {
    case home
    case navigation
}

@MainActor
final class AppViewModel: ObservableObject {

    let container: ModelContainer
    private var modelContext: ModelContext { container.mainContext }

    let location = LocationService()
    let voice = SpokenFeedbackService()

    @Published var activeUser: AppUser?
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

    private var activeNavigationSession: NavigationSession?
    private var liveNavigationTask: Task<Void, Never>?

    private let briefingRadiusMeters: CLLocationDistance = 800

    init(container: ModelContainer) {
        self.container = container
    }

    func bootstrap() async {
        location.requestWhenInUse()
        location.startUpdatingIfAllowed()

        let idKey = "activeUserId"
        guard let raw = UserDefaults.standard.string(forKey: idKey),
              let id = UUID(uuidString: raw) else { return }

        let predicate = #Predicate<AppUser> { $0.id == id }
        var d = FetchDescriptor<AppUser>(predicate: predicate)
        d.fetchLimit = 1
        if let u = try? modelContext.fetch(d).first {
            activeUser = u
        } else {
            UserDefaults.standard.removeObject(forKey: idKey)
        }
    }

    // MARK: - Spoken UI feedback (separate from live navigation loop)

    func announceToUser(_ message: String) {
        guard let u = activeUser, u.spokenFeedbackEnabled else { return }
        voice.speak(message, volume: u.audioVolume, rateMultiplier: max(0.35, min(1.2, u.speechRate)))
    }

    // MARK: - Auth

    func switchToRegister() {
        authMode = .register
        bannerMessage = nil
    }

    func switchToLogin() {
        authMode = .login
        bannerMessage = nil
    }

    func login() {
        bannerMessage = nil
        let key = usernameOrEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = password
        guard !key.isEmpty, !pw.isEmpty else {
            bannerMessage = "Enter your username or email and password."
            announceToUser(bannerMessage!)
            return
        }

        let descriptor = FetchDescriptor<AppUser>()
        let users = (try? modelContext.fetch(descriptor)) ?? []
        let user = users.first {
            $0.username.lowercased() == key.lowercased()
                || $0.email.lowercased() == key.lowercased()
        }

        guard let user, user.matchesPassword(pw) else {
            bannerMessage = "Invalid username or password."
            announceToUser(bannerMessage!)
            return
        }

        activeUser = user
        UserDefaults.standard.set(user.id.uuidString, forKey: "activeUserId")
        password = ""
        announceToUser("Signed in as \(user.username).")
    }

    func register() {
        bannerMessage = nil
        let u = registerUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = registerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let p1 = registerPassword
        let p2 = registerConfirmPassword

        guard !u.isEmpty, !e.isEmpty, !p1.isEmpty else {
            bannerMessage = "Fill in all registration fields."
            announceToUser(bannerMessage!)
            return
        }

        guard e.contains("@") else {
            bannerMessage = "Enter a valid email address."
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

        let existing = FetchDescriptor<AppUser>()
        let all = (try? modelContext.fetch(existing)) ?? []
        if all.contains(where: { $0.username.lowercased() == u.lowercased() }) {
            bannerMessage = "That username is already registered."
            announceToUser(bannerMessage!)
            return
        }
        if all.contains(where: { $0.email.lowercased() == e.lowercased() }) {
            bannerMessage = "That email is already registered."
            announceToUser(bannerMessage!)
            return
        }

        let user = AppUser(username: u, email: e, plainPassword: p1)
        modelContext.insert(user)
        do {
            try modelContext.save()
        } catch {
            bannerMessage = "Could not save your account. Try again."
            announceToUser(bannerMessage!)
            modelContext.delete(user)
            return
        }

        activeUser = user
        UserDefaults.standard.set(user.id.uuidString, forKey: "activeUserId")
        registerPassword = ""
        registerConfirmPassword = ""
        announceToUser("Registration complete. Welcome, \(user.username).")
    }

    func logout() {
        stopNavigationInternal()
        voice.stopImmediately()
        activeUser = nil
        UserDefaults.standard.removeObject(forKey: "activeUserId")
        currentScreen = .main
        mainTab = .home
        authMode = .login
    }

    // MARK: - Navigation flow

    func startNavigation() {
        Task { await beginNavigationWithBriefing() }
    }

    private func beginNavigationWithBriefing() async {
        guard let user = activeUser else { return }

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

        /// Pre-navigation route briefing only: summarizes stored community hazards. Live sensor navigation audio stays separate once moving.
        let briefing = await buildBriefingNearUser(coordinate: coord)
        if user.spokenFeedbackEnabled {
            await voice.speakAndWait(
                briefing,
                volume: user.audioVolume,
                rateMultiplier: max(0.35, min(1.2, user.speechRate))
            )
        }

        let session = NavigationSession(userID: user.id)
        modelContext.insert(session)
        try? modelContext.save()
        activeNavigationSession = session

        isNavigating = true
        navigationPausedForReport = false
        currentScreen = .navigation
        startLiveNavigationLoop()
        announceToUser("Navigation started.")
    }

    private func buildBriefingNearUser(coordinate: CLLocationCoordinate2D) async -> String {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let descriptor = FetchDescriptor<HazardReport>()
        let reports = (try? modelContext.fetch(descriptor)) ?? []
        let nearby = reports.filter {
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

    /// Simulated live navigation cues — replace with your LiDAR pipeline hooks without changing hazard-announcement behavior.
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
                    if let u = self.activeUser, u.spokenFeedbackEnabled {
                        /// Intentionally only sensor-style guidance — no database hazard announcements while navigating.
                        self.voice.speak(
                            line,
                            volume: u.audioVolume,
                            rateMultiplier: max(0.35, min(1.2, u.speechRate))
                        )
                    }
                }
            }
        }
    }

    func stopNavigation() {
        stopNavigationInternal()
        currentScreen = .main
        announceToUser("Navigation stopped.")
    }

    private func stopNavigationInternal() {
        liveNavigationTask?.cancel()
        liveNavigationTask = nil
        isNavigating = false
        navigationPausedForReport = false
        voice.stopImmediately()

        if let s = activeNavigationSession {
            s.endedAt = Date()
            s.status = "Completed"
            try? modelContext.save()
        }
        activeNavigationSession = nil
        liveNavigationStatusLine = ""
    }

    func openMap() {
        currentScreen = .map
    }

    func openReportFromHome() {
        reportFlowSource = .home
        presentReport()
    }

    func openReportFromNavigation() {
        reportFlowSource = .navigation
        navigationPausedForReport = true
        voice.stopImmediately()
        presentReport()
    }

    private func presentReport() {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            location.startUpdatingIfAllowed()
        default:
            break
        }
        currentScreen = .report
    }

    func cancelReportFlow() {
        resumeNavigationIfNeeded()
        bannerMessage = "Report canceled."
        announceToUser("Report canceled.")
    }

    func submitReport(type: String, details: String) {
        guard let user = activeUser else { return }

        location.startUpdatingIfAllowed()
        guard let loc = location.lastLocation else {
            bannerMessage = "Could not read GPS for this report. Try again outdoors."
            announceToUser(bannerMessage!)
            return
        }

        let report = HazardReport(
            type: type,
            details: details,
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            reportingUserID: user.id,
            reportingUsername: user.username
        )
        modelContext.insert(report)

        if let s = activeNavigationSession {
            s.reportCount += 1
        }

        do {
            try modelContext.save()
        } catch {
            bannerMessage = "Could not save the hazard report."
            announceToUser(bannerMessage!)
            modelContext.delete(report)
            return
        }

        bannerMessage = "Hazard report saved."
        announceToUser("Hazard report saved for \(type).")
        resumeNavigationIfNeeded()
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
        currentScreen = .main
    }

    func openSettings() {
        currentScreen = .settings
    }

    func closeSettings() {
        currentScreen = .main
    }

    func savePreferencesFromSettings() {
        try? modelContext.save()
        if activeUser != nil {
            announceToUser("Preferences saved.")
        }
    }

    func cancelSettingsEdits() {
        try? modelContext.rollback()
        announceToUser("Changes discarded.")
        currentScreen = .main
    }

}
