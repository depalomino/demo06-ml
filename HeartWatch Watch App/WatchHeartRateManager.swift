import Foundation
import HealthKit
import WatchConnectivity

enum AppCaptureMode {
    static let useDummyData = true
}

struct WatchHeartRateReading: Codable, Identifiable, Hashable {
    let id: Int64
    let bpm: Double
    let timestamp: String

    init(id: Int64, bpm: Double, date: Date) {
        self.id = id
        self.bpm = bpm
        timestamp = WatchReadingFormat.string(from: date)
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

private enum WatchReadingFormat {
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

final class WatchHeartRateManager: NSObject, ObservableObject {
    @Published private(set) var currentBPM: Double?
    @Published private(set) var isCapturing = false
    @Published private(set) var isReachable = false
    @Published private(set) var errorMessage: String?

    var connectionText: String {
        if AppCaptureMode.useDummyData { return "Modo dummy" }
        if isCapturing && !isReachable { return "Guardando; sincroniza luego" }
        return isReachable ? "iPhone conectado" : "Sin conexión directa"
    }

    private let healthStore = HKHealthStore()
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var readings: [WatchHeartRateReading] = []
    private var knownIDs = Set<Int64>()
    private var lastRecordedAt: Date?
    private var lastReadingID: Int64 = 0
    private var dummyHeartRateTimer: Timer?
    private var dummyTick: Double = 0
    private let recordingInterval: TimeInterval = 3
    private let fileURL: URL
    private let legacyJSONFileURL: URL

    override init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documentsURL.appendingPathComponent("heart-rate-readings.csv")
        legacyJSONFileURL = documentsURL.appendingPathComponent("heart-rate-readings.json")
        super.init()
        loadReadings()
        saveReadings()
        if AppCaptureMode.useDummyData {
            isReachable = true
            isCapturing = true
            startDummyCapture()
        } else {
            session?.delegate = self
            session?.activate()
        }
    }

    deinit {
        dummyHeartRateTimer?.invalidate()
    }

    private func startCapture() {
        if AppCaptureMode.useDummyData {
            isCapturing = true
            startDummyCapture()
            publishState()
            return
        }
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
        if AppCaptureMode.useDummyData {
            isCapturing = false
            stopDummyCapture()
            publishState()
            return
        }
        guard isCapturing || workoutSession != nil else { publishState(); return }
        workoutSession?.end()
        isCapturing = false
        publishState()
    }

    private func startDummyCapture() {
        guard dummyHeartRateTimer == nil else { return }
        recordDummyHeartRate()
        dummyHeartRateTimer = Timer.scheduledTimer(withTimeInterval: recordingInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.recordDummyHeartRate() }
        }
    }

    private func stopDummyCapture() {
        dummyHeartRateTimer?.invalidate()
        dummyHeartRateTimer = nil
    }

    private func recordDummyHeartRate() {
        guard isCapturing else { return }
        dummyTick += 1
        let bpm = 74 + 7 * sin(dummyTick / 3) + Double.random(in: -2...2)
        let reading = WatchHeartRateReading(id: nextReadingID(), bpm: bpm, date: Date())
        guard knownIDs.insert(reading.id).inserted else { return }
        readings.append(reading)
        currentBPM = bpm
        saveReadings()
    }

    private func record(bpm: Double, date: Date) {
        guard bpm > 0 else { return }
        if let lastRecordedAt, date.timeIntervalSince(lastRecordedAt) < recordingInterval { return }
        lastRecordedAt = date
        let reading = WatchHeartRateReading(id: nextReadingID(), bpm: bpm, date: date)
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
        knownIDs.removeAll()
        lastReadingID = 0
        currentBPM = nil
        deleteSavedFiles()
    }

    private func publishState() {
        guard !AppCaptureMode.useDummyData else { return }
        let state: [String: Any] = ["capturing": isCapturing]
        try? session?.updateApplicationContext(state)
        session?.transferUserInfo(state)
        if session?.isReachable == true { session?.sendMessage(state, replyHandler: nil, errorHandler: nil) }
    }

    private func showError(_ message: String) { errorMessage = message }

    private func loadReadings() {
        let stored: [WatchHeartRateReading]
        if let csvReadings = Self.loadHeartRateCSV(from: fileURL) {
            stored = csvReadings
        } else if let data = try? Data(contentsOf: legacyJSONFileURL),
                  let jsonReadings = try? JSONDecoder().decode([WatchHeartRateReading].self, from: data) {
            stored = jsonReadings
        } else {
            return
        }
        readings = Self.renumberHeartRate(stored)
        knownIDs = Set(readings.map(\.id))
        lastReadingID = readings.map(\.id).max() ?? 0
        currentBPM = readings.last?.bpm
    }

    private func saveReadings() {
        try? Self.heartRateCSV(from: readings).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func deleteSavedFiles() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: legacyJSONFileURL)
    }

    private func nextReadingID() -> Int64 {
        lastReadingID += 1
        return lastReadingID
    }

    private static func heartRateCSV(from readings: [WatchHeartRateReading]) -> String {
        let rows = readings.map { reading in
            [String(reading.id), String(reading.bpm), reading.timestamp].csvLine
        }
        return (["id,bpm,timestamp"] + rows).joined(separator: "\n")
    }

    private static func loadHeartRateCSV(from url: URL) -> [WatchHeartRateReading]? {
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return csv.csvRows.dropFirst().compactMap { (row: [String]) -> WatchHeartRateReading? in
            guard row.count >= 3,
                  let id = Int64(row[0]),
                  let bpm = Double(row[1]) else { return nil }
            return WatchHeartRateReading(id: id, bpm: bpm, timestamp: row[2])
        }
    }

    private static func renumberHeartRate(_ readings: [WatchHeartRateReading]) -> [WatchHeartRateReading] {
        readings
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { index, reading in
                WatchHeartRateReading(id: Int64(index + 1), bpm: reading.bpm, timestamp: reading.timestamp)
            }
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
