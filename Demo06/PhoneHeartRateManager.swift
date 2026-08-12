import Foundation
import CoreMotion
import WatchConnectivity

enum AppCaptureMode {
    static let useDummyData = true
}

struct HeartRateReading: Codable, Identifiable, Hashable {
    let id: Int64
    let bpm: Double
    let timestamp: String

    init(id: Int64? = nil, bpm: Double, date: Date = Date()) {
        self.id = id ?? 0
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
            id = 0
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
        let gravity = 9.80665
        let degreesPerRadian = 180.0 / Double.pi
        self.id = id
        timestamp = ReadingFormat.string(from: date)
        accelerationX = (motion.userAcceleration.x + motion.gravity.x) * gravity
        accelerationY = (motion.userAcceleration.y + motion.gravity.y) * gravity
        accelerationZ = (motion.userAcceleration.z + motion.gravity.z) * gravity
        rotationX = motion.rotationRate.x * degreesPerRadian
        rotationY = motion.rotationRate.y * degreesPerRadian
        rotationZ = motion.rotationRate.z * degreesPerRadian
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
            id = 0
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

    static func string(from date: Date) -> String {
        dateFormatter.string(from: date)
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
        if AppCaptureMode.useDummyData { return "Modo dummy" }
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
    private var lastHeartRateID: Int64 = 0
    private var dummyHeartRateTimer: Timer?
    private var dummyMotionTimer: Timer?
    private var dummyTick: Double = 0

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
        if AppCaptureMode.useDummyData {
            isReachable = true
        } else {
            session?.delegate = self
            session?.activate()
        }
    }

    deinit {
        dummyHeartRateTimer?.invalidate()
        dummyMotionTimer?.invalidate()
    }

    func setCapture(active: Bool) {
        isCapturing = active
        if AppCaptureMode.useDummyData {
            active ? startDummyCapture() : stopDummyCapture()
        } else {
            active ? startMotionCapture() : stopMotionCapture()
            send(command: active ? "start" : "stop")
        }
    }

    func clearReadings() {
        readings.removeAll()
        motionReadings.removeAll()
        knownIDs.removeAll()
        lastMotionID = 0
        lastHeartRateID = 0
        currentBPM = nil
        currentMotion = nil
        deleteSavedFiles()
        if !AppCaptureMode.useDummyData {
            send(command: "clear")
        }
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
                let reading = MotionReading(id: self.nextMotionID(), motion: motion, date: now)
                self.currentMotion = reading
                self.motionReadings.append(reading)
                self.saveReadings()
            }
        }
    }

    private func stopMotionCapture() {
        motionManager.stopDeviceMotionUpdates()
    }

    private func startDummyCapture() {
        guard dummyHeartRateTimer == nil && dummyMotionTimer == nil else { return }
        motionError = nil
        isReachable = true
        recordDummyHeartRate()
        recordDummyMotion()

        dummyHeartRateTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordDummyHeartRate() }
        }

        dummyMotionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordDummyMotion() }
        }
    }

    private func stopDummyCapture() {
        dummyHeartRateTimer?.invalidate()
        dummyHeartRateTimer = nil
        dummyMotionTimer?.invalidate()
        dummyMotionTimer = nil
    }

    private func recordDummyHeartRate() {
        guard isCapturing else { return }
        let bpm = 76 + 8 * sin(dummyTick / 7) + Double.random(in: -2...2)
        accept(HeartRateReading(id: nextHeartRateID(), bpm: bpm, date: Date()))
    }

    private func recordDummyMotion() {
        guard isCapturing else { return }
        dummyTick += 1
        let timestamp = ReadingFormat.string(from: Date())
        let reading = MotionReading(
            id: nextMotionID(),
            timestamp: timestamp,
            accelerationX: 0.8 * sin(dummyTick / 5),
            accelerationY: 0.6 * cos(dummyTick / 6),
            accelerationZ: 9.80665 + 0.4 * sin(dummyTick / 8),
            rotationX: 12 * sin(dummyTick / 4),
            rotationY: 8 * cos(dummyTick / 5),
            rotationZ: 18 * sin(dummyTick / 7)
        )
        currentMotion = reading
        motionReadings.append(reading)
        saveReadings()
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
        let acceptedReading: HeartRateReading
        if reading.id <= 0 || knownIDs.contains(reading.id) {
            acceptedReading = HeartRateReading(id: nextHeartRateID(), bpm: reading.bpm, timestamp: reading.timestamp)
        } else {
            acceptedReading = reading
            lastHeartRateID = max(lastHeartRateID, reading.id)
        }
        guard knownIDs.insert(acceptedReading.id).inserted else { return }
        readings.append(acceptedReading)
        readings.sort { $0.timestamp < $1.timestamp }
        currentBPM = acceptedReading.bpm
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
            motionReadings = Self.convertLegacyMotionUnits(stored.motion)
        }

        if readings.isEmpty,
           let heartRateData = try? Data(contentsOf: legacyHeartRateJSONFileURL),
           let legacyReadings = try? JSONDecoder().decode([HeartRateReading].self, from: heartRateData) {
            readings = legacyReadings
        }

        if motionReadings.isEmpty,
           let motionData = try? Data(contentsOf: legacyMotionJSONFileURL),
           let storedMotion = try? JSONDecoder().decode([MotionReading].self, from: motionData) {
            motionReadings = Self.convertLegacyMotionUnits(storedMotion)
        }
        readings = Self.renumberHeartRate(readings)
        motionReadings = Self.renumberMotion(motionReadings)
        knownIDs = Set(readings.map(\.id))
        currentBPM = readings.last?.bpm
        currentMotion = motionReadings.last
        lastHeartRateID = readings.map(\.id).max() ?? 0
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

    private func nextHeartRateID() -> Int64 {
        lastHeartRateID += 1
        return lastHeartRateID
    }

    private func nextMotionID() -> Int64 {
        lastMotionID += 1
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
        return (["id,timestamp,accelerationX_mps2,accelerationY_mps2,accelerationZ_mps2,rotationX_deg_s,rotationY_deg_s,rotationZ_deg_s"] + rows)
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
        return (["type,id,timestamp,bpm,accelerationX_mps2,accelerationY_mps2,accelerationZ_mps2,rotationX_deg_s,rotationY_deg_s,rotationZ_deg_s"] + heartRows + motionRows)
            .joined(separator: "\n")
    }

    private static func loadHeartRateCSV(from url: URL) -> [HeartRateReading]? {
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return csv.csvRows.dropFirst().compactMap { (row: [String]) -> HeartRateReading? in
            guard row.count >= 3,
                  let id = Int64(row[0]),
                  let bpm = Double(row[1]) else { return nil }
            return HeartRateReading(id: id, bpm: bpm, timestamp: row[2])
        }
    }

    private static func loadMotionCSV(from url: URL) -> [MotionReading]? {
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let rows = csv.csvRows
        let header = rows.first ?? []
        let usesLegacyUnits = header.contains("accelerationX") || header.contains("rotationX")
        let parsed: [MotionReading] = rows.dropFirst().compactMap { (row: [String]) -> MotionReading? in
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
        return usesLegacyUnits ? convertLegacyMotionUnits(parsed) : parsed
    }

    private static func convertLegacyMotionUnits(_ readings: [MotionReading]) -> [MotionReading] {
        let gravity = 9.80665
        let degreesPerRadian = 180.0 / Double.pi
        return readings.map { reading in
            MotionReading(
                id: reading.id,
                timestamp: reading.timestamp,
                accelerationX: reading.accelerationX * gravity,
                accelerationY: reading.accelerationY * gravity,
                accelerationZ: reading.accelerationZ * gravity,
                rotationX: reading.rotationX * degreesPerRadian,
                rotationY: reading.rotationY * degreesPerRadian,
                rotationZ: reading.rotationZ * degreesPerRadian
            )
        }
    }

    private static func renumberHeartRate(_ readings: [HeartRateReading]) -> [HeartRateReading] {
        readings
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { index, reading in
                HeartRateReading(id: Int64(index + 1), bpm: reading.bpm, timestamp: reading.timestamp)
            }
    }

    private static func renumberMotion(_ readings: [MotionReading]) -> [MotionReading] {
        readings
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { index, reading in
                MotionReading(
                    id: Int64(index + 1),
                    timestamp: reading.timestamp,
                    accelerationX: reading.accelerationX,
                    accelerationY: reading.accelerationY,
                    accelerationZ: reading.accelerationZ,
                    rotationX: reading.rotationX,
                    rotationY: reading.rotationY,
                    rotationZ: reading.rotationZ
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
