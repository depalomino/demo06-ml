import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var heartRate: PhoneHeartRateManager
    @State private var showsDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
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
                    .disabled(heartRate.readings.isEmpty)
                }
            }
            .padding(24)
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
