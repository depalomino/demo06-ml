import Foundation
import CoreMotion
import WatchConnectivity

struct HeartRateReading: Codable, Identifiable, Hashable {
    let id: UUID
    let bpm: Double
    let timestamp: String

    init(id: UUID = UUID(), bpm: Double, date: Date = Date()) {
        self.id = id
        self.bpm = bpm
        self.timestamp = Self.formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct MotionReading: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: String
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let rotationX: Double
    let rotationY: Double
    let rotationZ: Double

    init(motion: CMDeviceMotion, date: Date = Date()) {
        id = UUID()
        timestamp = ISO8601DateFormatter.readingFormatter.string(from: date)
        accelerationX = motion.userAcceleration.x + motion.gravity.x
        accelerationY = motion.userAcceleration.y + motion.gravity.y
        accelerationZ = motion.userAcceleration.z + motion.gravity.z
        rotationX = motion.rotationRate.x
        rotationY = motion.rotationRate.y
        rotationZ = motion.rotationRate.z
    }
}

private struct StoredReadings: Codable {
    var heartRate: [HeartRateReading]
    var motion: [MotionReading]
}

private extension ISO8601DateFormatter {
    static let readingFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

@MainActor
final class PhoneHeartRateManager: NSObject, ObservableObject {
    @Published private(set) var readings: [HeartRateReading] = []
    @Published private(set) var motionReadings: [MotionReading] = []
    @Published private(set) var currentBPM: Double?
    @Published private(set) var currentMotion: MotionReading?
    @Published private(set) var isCapturing = false
    @Published private(set) var isReachable = false
    @Published private(set) var motionError: String?

    var connectionText: String {
        guard WCSession.isSupported() else { return "No compatible" }
        return isReachable ? "Conectado" : "Sin conexión directa"
    }

    var exportFileURL: URL { fileURL }

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private let motionManager = CMMotionManager()
    private let fileURL: URL
    private var knownIDs = Set<UUID>()

    override init() {
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heart-rate-readings.json")
        super.init()
        loadReadings()
        saveReadings()
        session?.delegate = self
        session?.activate()
    }

    func setCapture(active: Bool) {
        isCapturing = active
        active ? startMotionCapture() : stopMotionCapture()
        send(command: active ? "start" : "stop")
    }

    func clearReadings() {
        readings.removeAll()
        motionReadings.removeAll()
        currentBPM = nil
        currentMotion = nil
        saveReadings()
        send(command: "clear")
    }

    private func startMotionCapture() {
        guard motionManager.isDeviceMotionAvailable else {
            motionError = "Acelerómetro o giroscopio no disponible"
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }
        motionError = nil
        motionManager.deviceMotionUpdateInterval = 1
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.motionError = error.localizedDescription
                    return
                }
                guard self.isCapturing, let motion else { return }
                let reading = MotionReading(motion: motion)
                self.currentMotion = reading
                self.motionReadings.append(reading)
                self.saveReadings()
            }
        }
    }

    private func stopMotionCapture() {
        motionManager.stopDeviceMotionUpdates()
    }

    private func send(command commandName: String) {
        let command: [String: Any] = ["command": commandName]
        try? session?.updateApplicationContext(command)
        if session?.isReachable == true {
            session?.sendMessage(command, replyHandler: nil) { error in
                print("No se pudo enviar el comando: \(error.localizedDescription)")
            }
        } else {
            session?.transferUserInfo(command)
        }
    }

    private func accept(_ reading: HeartRateReading) {
        guard knownIDs.insert(reading.id).inserted else { return }
        readings.append(reading)
        readings.sort { $0.timestamp < $1.timestamp }
        currentBPM = reading.bpm
        saveReadings()
    }

    private func decodeReading(from dictionary: [String: Any]) {
        guard let data = dictionary["reading"] as? Data,
              let reading = try? JSONDecoder().decode(HeartRateReading.self, from: data) else { return }
        accept(reading)
    }

    private func loadReadings() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let stored = try? JSONDecoder().decode(StoredReadings.self, from: data) {
            readings = stored.heartRate
            motionReadings = stored.motion
        } else if let legacyReadings = try? JSONDecoder().decode([HeartRateReading].self, from: data) {
            readings = legacyReadings
        }
        knownIDs = Set(readings.map(\.id))
        currentBPM = readings.last?.bpm
        currentMotion = motionReadings.last
    }

    private func saveReadings() {
        let stored = StoredReadings(heartRate: readings, motion: motionReadings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension PhoneHeartRateManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.decodeReading(from: message)
            self.applyWatchState(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            self.decodeReading(from: userInfo)
            self.applyWatchState(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.applyWatchState(applicationContext) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    private func applyWatchState(_ dictionary: [String: Any]) {
        guard let active = dictionary["capturing"] as? Bool else { return }
        isCapturing = active
        active ? startMotionCapture() : stopMotionCapture()
    }
}
