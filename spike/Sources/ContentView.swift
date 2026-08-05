import SwiftUI
import WebKit

struct ContentView: View {
    @Bindable var controller: SpikeController

    var body: some View {
        VStack(spacing: 0) {
            WebViewContainer(webView: controller.webView)
                .frame(height: 220)
                .background(.black)

            controls
            Divider()
            logView
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Label(controller.currentTrack.title, systemImage: "music.note")
                    .font(.headline)
                Spacer()
                Text(controller.playerState)
                    .font(.caption.monospaced())
                    .foregroundStyle(controller.playerState == "playing" ? .green : .secondary)
            }

            HStack(spacing: 10) {
                Button("Play") { controller.play() }
                Button("Next") { controller.advance(reason: "manual next") }
                Button("Status") { controller.probe(label: "manual") }
                Spacer()
                Button("Clear") { controller.clearLog() }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)

            Text("Lock the phone, then press ▶▶ on the lock screen. That is criterion 1.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(colour(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: controller.log.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private func colour(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("FAILED") || line.contains("MISSING") { return .red }
        if line.contains("stripped") { return .green }
        if line.contains("──") { return .orange }
        return .primary
    }
}

/// Plain UIKit passthrough — the spike needs the web view visible so we can see
/// whether anything is actually playing.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
