import Foundation
import HealthKit
import WatchConnectivity

struct WatchHeartRateReading: Codable, Identifiable, Hashable {
    let id: UUID
    let bpm: Double
    let timestamp: String

    init(bpm: Double, date: Date) {
        id = UUID()
        self.bpm = bpm
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = formatter.string(from: date)
    }
}

final class WatchHeartRateManager: NSObject, ObservableObject {
    @Published private(set) var currentBPM: Double?
    @Published private(set) var isCapturing = false
    @Published private(set) var isReachable = false
    @Published private(set) var errorMessage: String?

    var connectionText: String {
        if isCapturing && !isReachable { return "Guardando; sincroniza luego" }
        return isReachable ? "iPhone conectado" : "Sin conexión directa"
    }

    private let healthStore = HKHealthStore()
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var readings: [WatchHeartRateReading] = []
    private var knownIDs = Set<UUID>()
    private var lastRecordedAt: Date?
    private let recordingInterval: TimeInterval = 3
    private let fileURL: URL

    override init() {
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heart-rate-readings.json")
        super.init()
        loadReadings()
        session?.delegate = self
        session?.activate()
    }

    private func startCapture() {
        guard !isCapturing else { return }
        guard HKHealthStore.isHealthDataAvailable(),
              let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            showError("HealthKit no está disponible")
            return
        }
        let workoutType = HKObjectType.workoutType()

        healthStore.requestAuthorization(toShare: [workoutType], read: [heartRateType]) { [weak self] allowed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    self.showError(error?.localizedDescription ?? "Autoriza el acceso a Frecuencia cardiaca")
                    self.publishState()
                    return
                }
                self.beginWorkout()
            }
        }
    }

    private func beginWorkout() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        do {
            let workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = workoutSession.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            workoutSession.delegate = self
            builder.delegate = self
            self.workoutSession = workoutSession
            self.workoutBuilder = builder
            lastRecordedAt = nil
            errorMessage = nil
            workoutSession.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isCapturing = success
                    if !success { self.showError(error?.localizedDescription ?? "No se pudo iniciar el entrenamiento") }
                    self.publishState()
                }
            }
        } catch {
            showError(error.localizedDescription)
            publishState()
        }
    }

    private func stopCapture() {
        guard isCapturing || workoutSession != nil else { publishState(); return }
        workoutSession?.end()
        isCapturing = false
        publishState()
    }

    private func record(bpm: Double, date: Date) {
        guard bpm > 0 else { return }
        if let lastRecordedAt, date.timeIntervalSince(lastRecordedAt) < recordingInterval { return }
        lastRecordedAt = date
        let reading = WatchHeartRateReading(bpm: bpm, date: date)
        guard knownIDs.insert(reading.id).inserted else { return }
        readings.append(reading)
        currentBPM = bpm
        saveReadings()

        guard let data = try? JSONEncoder().encode(reading) else { return }
        let payload: [String: Any] = ["reading": data, "capturing": isCapturing]
        try? session?.updateApplicationContext(payload)
        session?.transferUserInfo(payload)
        if session?.isReachable == true {
            session?.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    private func handle(_ dictionary: [String: Any]) {
        guard let command = dictionary["command"] as? String else { return }
        switch command {
        case "start": startCapture()
        case "stop": stopCapture()
        case "clear": clearReadings()
        default: break
        }
    }

    private func clearReadings() {
        readings.removeAll()
        currentBPM = nil
        saveReadings()
    }

    private func publishState() {
        let state: [String: Any] = ["capturing": isCapturing]
        try? session?.updateApplicationContext(state)
        session?.transferUserInfo(state)
        if session?.isReachable == true { session?.sendMessage(state, replyHandler: nil, errorHandler: nil) }
    }

    private func showError(_ message: String) { errorMessage = message }

    private func loadReadings() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([WatchHeartRateReading].self, from: data) else { return }
        readings = stored
        knownIDs = Set(stored.map(\.id))
        currentBPM = stored.last?.bpm
    }

    private func saveReadings() {
        guard let data = try? JSONEncoder().encode(readings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension WatchHeartRateManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.handle(session.receivedApplicationContext)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { self.handle(message) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async { self.handle(userInfo) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.handle(applicationContext) }
    }
}

extension WatchHeartRateManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            if toState == .ended {
                self.workoutBuilder?.endCollection(withEnd: date) { _, _ in }
                self.workoutBuilder = nil
                self.workoutSession = nil
                self.isCapturing = false
                self.publishState()
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.showError(error.localizedDescription)
            self.isCapturing = false
            self.publishState()
        }
    }
}

extension WatchHeartRateManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let date = statistics.endDate
        DispatchQueue.main.async { self.record(bpm: bpm, date: date) }
    }
}
