import Foundation
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

@MainActor
final class PhoneHeartRateManager: NSObject, ObservableObject {
    @Published private(set) var readings: [HeartRateReading] = []
    @Published private(set) var currentBPM: Double?
    @Published private(set) var isCapturing = false
    @Published private(set) var isReachable = false

    var connectionText: String {
        guard WCSession.isSupported() else { return "No compatible" }
        return isReachable ? "Conectado" : "Sin conexión directa"
    }

    var exportFileURL: URL { fileURL }

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
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
        send(command: active ? "start" : "stop")
    }

    func clearReadings() {
        readings.removeAll()
        currentBPM = nil
        saveReadings()
        send(command: "clear")
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
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([HeartRateReading].self, from: data) else { return }
        readings = stored
        knownIDs = Set(stored.map(\.id))
        currentBPM = stored.last?.bpm
    }

    private func saveReadings() {
        guard let data = try? JSONEncoder().encode(readings) else { return }
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
        if let active = dictionary["capturing"] as? Bool { isCapturing = active }
    }
}
