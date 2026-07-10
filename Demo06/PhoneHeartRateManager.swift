import Foundation
import CoreMotion
import WatchConnectivity

struct HeartRateReading: Codable, Identifiable, Hashable {
    let id: Int64
    let bpm: Double
    let timestamp: String

    init(id: Int64? = nil, bpm: Double, date: Date = Date()) {
        self.id = id
            ?? ReadingFormat.numericID(from: date)
        self.bpm = bpm
        self.timestamp = ReadingFormat.string(from: date)
    }

    init(id: Int64, bpm: Double, timestamp: String) {
        self.id = id
        self.bpm = bpm
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id, bpm, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try container.decode(Double.self, forKey: .bpm)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        if let numericID = try? container.decode(Int64.self, forKey: .id) {
            id = numericID
        } else {
            id = ReadingFormat.numericID(fromTimestamp: timestamp)
        }
    }
}

struct MotionReading: Codable, Identifiable, Hashable {
    let id: Int64
    let timestamp: String
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let rotationX: Double
    let rotationY: Double
    let rotationZ: Double

    init(id: Int64, motion: CMDeviceMotion, date: Date = Date()) {
        self.id = id
        timestamp = ReadingFormat.string(from: date)
        accelerationX = motion.userAcceleration.x + motion.gravity.x
        accelerationY = motion.userAcceleration.y + motion.gravity.y
        accelerationZ = motion.userAcceleration.z + motion.gravity.z
        rotationX = motion.rotationRate.x
        rotationY = motion.rotationRate.y
        rotationZ = motion.rotationRate.z
    }

    init(id: Int64, timestamp: String, accelerationX: Double, accelerationY: Double, accelerationZ: Double,
         rotationX: Double, rotationY: Double, rotationZ: Double) {
        self.id = id
        self.timestamp = timestamp
        self.accelerationX = accelerationX
        self.accelerationY = accelerationY
        self.accelerationZ = accelerationZ
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, accelerationX, accelerationY, accelerationZ, rotationX, rotationY, rotationZ
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        accelerationX = try container.decode(Double.self, forKey: .accelerationX)
        accelerationY = try container.decode(Double.self, forKey: .accelerationY)
        accelerationZ = try container.decode(Double.self, forKey: .accelerationZ)
        rotationX = try container.decode(Double.self, forKey: .rotationX)
        rotationY = try container.decode(Double.self, forKey: .rotationY)
        rotationZ = try container.decode(Double.self, forKey: .rotationZ)
        if let numericID = try? container.decode(Int64.self, forKey: .id) {
            id = numericID
        } else {
            id = ReadingFormat.numericID(fromTimestamp: timestamp)
        }
    }
}

private struct StoredReadings: Codable {
    var heartRate: [HeartRateReading]
    var motion: [MotionReading]
}

private enum ReadingFormat {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func numericID(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func numericID(fromTimestamp timestamp: String) -> Int64 {
        if let date = dateFormatter.date(from: timestamp) {
            return numericID(from: date)
        }
        if let date = isoFormatter.date(from: timestamp) {
            return numericID(from: date)
        }
        return numericID(from: Date())
    }
}

private extension Array where Element == String {
    var csvLine: String {
        map { value in
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
                return "\"\(escaped)\""
            }
            return escaped
        }
        .joined(separator: ",")
    }
}

private extension String {
    var csvRows: [[String]] {
        split(whereSeparator: \.isNewline).map { line in
            var rows: [String] = []
            var current = ""
            var isInsideQuotes = false
            var iterator = Array(line).makeIterator()

            while let character = iterator.next() {
                if character == "\"" {
                    if isInsideQuotes, let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            isInsideQuotes = false
                            if next == "," {
                                rows.append(current)
                                current = ""
                            } else {
                                current.append(next)
                            }
                        }
                    } else {
                        isInsideQuotes.toggle()
                    }
                } else if character == "," && !isInsideQuotes {
                    rows.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }

            rows.append(current)
            return rows
        }
    }
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
        if isCapturing && !isReachable { return "Capturando; sincronización pendiente" }
        return isReachable ? "Conectado" : "Sin conexión directa"
    }

    var heartRateExportFileURL: URL { heartRateFileURL }
    var motionExportFileURL: URL { motionFileURL }

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private let motionManager = CMMotionManager()
    private let combinedCSVFileURL: URL
    private let heartRateFileURL: URL
    private let motionFileURL: URL
    private let legacyCombinedJSONFileURL: URL
    private let legacyHeartRateJSONFileURL: URL
    private let legacyMotionJSONFileURL: URL
    private var knownIDs = Set<Int64>()
    private var lastMotionID: Int64 = 0

    override init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        combinedCSVFileURL = documentsURL.appendingPathComponent("readings-combined.csv")
        heartRateFileURL = documentsURL.appendingPathComponent("heart-rate-readings.csv")
        motionFileURL = documentsURL.appendingPathComponent("motion-readings.csv")
        legacyCombinedJSONFileURL = documentsURL.appendingPathComponent("readings-combined.json")
        legacyHeartRateJSONFileURL = documentsURL.appendingPathComponent("heart-rate-readings.json")
        legacyMotionJSONFileURL = documentsURL.appendingPathComponent("motion-readings.json")
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
        knownIDs.removeAll()
        lastMotionID = 0
        currentBPM = nil
        currentMotion = nil
        deleteSavedFiles()
        send(command: "clear")
    }

    private func startMotionCapture() {
        guard motionManager.isDeviceMotionAvailable else {
            motionError = "Acelerómetro o giroscopio no disponible"
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }
        motionError = nil
        motionManager.deviceMotionUpdateInterval = 0.25
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.motionError = error.localizedDescription
                    return
                }
                guard self.isCapturing, let motion else { return }
                let now = Date()
                let reading = MotionReading(id: self.nextMotionID(for: now), motion: motion, date: now)
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
        session?.transferUserInfo(command)
        if session?.isReachable == true {
            session?.sendMessage(command, replyHandler: nil) { error in
                print("No se pudo enviar el comando: \(error.localizedDescription)")
            }
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
        if let storedHeartRate = Self.loadHeartRateCSV(from: heartRateFileURL) {
            readings = storedHeartRate
        }
        if let storedMotion = Self.loadMotionCSV(from: motionFileURL) {
            motionReadings = storedMotion
        }

        if readings.isEmpty && motionReadings.isEmpty,
           let data = try? Data(contentsOf: legacyCombinedJSONFileURL),
           let stored = try? JSONDecoder().decode(StoredReadings.self, from: data) {
            readings = stored.heartRate
            motionReadings = stored.motion
        }

        if readings.isEmpty,
           let heartRateData = try? Data(contentsOf: legacyHeartRateJSONFileURL),
           let legacyReadings = try? JSONDecoder().decode([HeartRateReading].self, from: heartRateData) {
            readings = legacyReadings
        }

        if motionReadings.isEmpty,
           let motionData = try? Data(contentsOf: legacyMotionJSONFileURL),
           let storedMotion = try? JSONDecoder().decode([MotionReading].self, from: motionData) {
            motionReadings = storedMotion
        }
        knownIDs = Set(readings.map(\.id))
        currentBPM = readings.last?.bpm
        currentMotion = motionReadings.last
        lastMotionID = motionReadings.map(\.id).max() ?? 0
    }

    private func saveReadings() {
        try? Self.heartRateCSV(from: readings).write(to: heartRateFileURL, atomically: true, encoding: .utf8)
        try? Self.motionCSV(from: motionReadings).write(to: motionFileURL, atomically: true, encoding: .utf8)
        try? Self.combinedCSV(heartRate: readings, motion: motionReadings)
            .write(to: combinedCSVFileURL, atomically: true, encoding: .utf8)
    }

    private func deleteSavedFiles() {
        let urls = [
            combinedCSVFileURL,
            heartRateFileURL,
            motionFileURL,
            legacyCombinedJSONFileURL,
            legacyHeartRateJSONFileURL,
            legacyMotionJSONFileURL
        ]
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func nextMotionID(for date: Date) -> Int64 {
        let candidate = ReadingFormat.numericID(from: date)
        lastMotionID = max(candidate, lastMotionID + 1)
        return lastMotionID
    }

    private static func heartRateCSV(from readings: [HeartRateReading]) -> String {
        let rows = readings.map { reading in
            [String(reading.id), String(reading.bpm), reading.timestamp].csvLine
        }
        return (["id,bpm,timestamp"] + rows).joined(separator: "\n")
    }

    private static func motionCSV(from readings: [MotionReading]) -> String {
        let rows = readings.map { reading in
            [
                String(reading.id),
                reading.timestamp,
                String(reading.accelerationX),
                String(reading.accelerationY),
                String(reading.accelerationZ),
                String(reading.rotationX),
                String(reading.rotationY),
                String(reading.rotationZ)
            ].csvLine
        }
        return (["id,timestamp,accelerationX,accelerationY,accelerationZ,rotationX,rotationY,rotationZ"] + rows)
            .joined(separator: "\n")
    }

    private static func combinedCSV(heartRate: [HeartRateReading], motion: [MotionReading]) -> String {
        let heartRows = heartRate.map { reading in
            ["heart_rate", String(reading.id), reading.timestamp, String(reading.bpm), "", "", "", "", "", ""].csvLine
        }
        let motionRows = motion.map { reading in
            [
                "motion",
                String(reading.id),
                reading.timestamp,
                "",
                String(reading.accelerationX),
                String(reading.accelerationY),
                String(reading.accelerationZ),
                String(reading.rotationX),
                String(reading.rotationY),
                String(reading.rotationZ)
            ].csvLine
        }
        return (["type,id,timestamp,bpm,accelerationX,accelerationY,accelerationZ,rotationX,rotationY,rotationZ"] + heartRows + motionRows)
            .joined(separator: "\n")
    }

    private static func loadHeartRateCSV(from url: URL) -> [HeartRateReading]? {
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return csv.csvRows.dropFirst().compactMap { row in
            guard row.count >= 3,
                  let id = Int64(row[0]),
                  let bpm = Double(row[1]) else { return nil }
            return HeartRateReading(id: id, bpm: bpm, timestamp: row[2])
        }
    }

    private static func loadMotionCSV(from url: URL) -> [MotionReading]? {
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return csv.csvRows.dropFirst().compactMap { row in
            guard row.count >= 8,
                  let id = Int64(row[0]),
                  let accelerationX = Double(row[2]),
                  let accelerationY = Double(row[3]),
                  let accelerationZ = Double(row[4]),
                  let rotationX = Double(row[5]),
                  let rotationY = Double(row[6]),
                  let rotationZ = Double(row[7]) else { return nil }
            return MotionReading(
                id: id,
                timestamp: row[1],
                accelerationX: accelerationX,
                accelerationY: accelerationY,
                accelerationZ: accelerationZ,
                rotationX: rotationX,
                rotationY: rotationY,
                rotationZ: rotationZ
            )
        }
    }
}

extension PhoneHeartRateManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.applyWatchState(session.receivedApplicationContext)
        }
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
        Task { @MainActor in
            self.decodeReading(from: applicationContext)
            self.applyWatchState(applicationContext)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    private func applyWatchState(_ dictionary: [String: Any]) {
        guard let active = dictionary["capturing"] as? Bool else { return }
        isCapturing = active
        active ? startMotionCapture() : stopMotionCapture()
    }
}
