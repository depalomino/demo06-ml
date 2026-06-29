import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var heartRate: WatchHeartRateManager

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.red)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(heartRate.currentBPM.map { String(Int($0.rounded())) } ?? "--")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                Text("BPM").font(.caption).foregroundStyle(.secondary)
            }

            Label(heartRate.isCapturing ? "Capturando" : "En espera",
                  systemImage: heartRate.isCapturing ? "waveform.path.ecg" : "pause.circle")
                .font(.caption)
                .foregroundStyle(heartRate.isCapturing ? .green : .secondary)

            Label(heartRate.connectionText,
                  systemImage: heartRate.isReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let error = heartRate.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    ContentView().environmentObject(WatchHeartRateManager())
}
