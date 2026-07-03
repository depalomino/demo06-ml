import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var heartRate: PhoneHeartRateManager
    @State private var showsDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)

                VStack(spacing: 4) {
                    Text(heartRate.currentBPM.map { String(Int($0.rounded())) } ?? "--")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("BPM")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    StatusRow(title: "Apple Watch", value: heartRate.connectionText,
                              color: heartRate.isReachable ? .green : .orange)
                    StatusRow(title: "Captura", value: heartRate.isCapturing ? "Activa" : "Detenida",
                              color: heartRate.isCapturing ? .green : .secondary)
                    StatusRow(title: "Lecturas guardadas", value: "\(heartRate.readings.count)", color: .blue)
                    StatusRow(title: "Muestras de movimiento", value: "\(heartRate.motionReadings.count)", color: .blue)
                }

                MotionCard(title: "Acelerómetro", unit: "g", values: heartRate.currentMotion.map {
                    ($0.accelerationX, $0.accelerationY, $0.accelerationZ)
                })

                MotionCard(title: "Giroscopio", unit: "rad/s", values: heartRate.currentMotion.map {
                    ($0.rotationX, $0.rotationY, $0.rotationZ)
                })

                if let error = heartRate.motionError {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button {
                    heartRate.setCapture(active: !heartRate.isCapturing)
                } label: {
                    Label(heartRate.isCapturing ? "Detener captura" : "Iniciar captura",
                          systemImage: heartRate.isCapturing ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(heartRate.isCapturing ? .red : .green)

                HStack(spacing: 12) {
                    ShareLink(item: heartRate.exportFileURL) {
                        Label("Exportar", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("Borrar", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(heartRate.readings.isEmpty && heartRate.motionReadings.isEmpty)
                }
                }
                .padding(24)
            }
            .navigationTitle("Frecuencia cardiaca")
            .confirmationDialog(
                "¿Borrar todas las lecturas?",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Borrar definitivamente", role: .destructive) {
                    heartRate.clearReadings()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borrarán las copias guardadas en el iPhone y el Apple Watch.")
            }
        }
    }
}

private struct MotionCard: View {
    let title: String
    let unit: String
    let values: (Double, Double, Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                AxisValue(axis: "X", value: values?.0)
                AxisValue(axis: "Y", value: values?.1)
                AxisValue(axis: "Z", value: values?.2)
            }
        }
        .padding()
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AxisValue: View {
    let axis: String
    let value: Double?

    var body: some View {
        VStack(spacing: 2) {
            Text(axis).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.3f", $0) } ?? "--")
                .font(.system(.body, design: .monospaced))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Circle().fill(color).frame(width: 9, height: 9)
            Text(value).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView().environmentObject(PhoneHeartRateManager())
}
