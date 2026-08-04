import ShirKit
import SwiftUI

struct QueueView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if playback.queue.isEmpty {
                    EmptyStateView(
                        icon: "list.bullet",
                        title: "Queue is empty",
                        message: "Play a playlist or a search result to fill this up."
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(playback.queue.items.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isCurrent: index == playback.queue.currentIndex)
                            .onTapGesture { playback.playItem(at: index) }
                            .listRowBackground(Theme.surface)
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) {
                            playback.removeFromQueue(at: index)
                        }
                    }
                    .onMove { offsets, destination in
                        playback.moveInQueue(fromOffsets: offsets, toOffset: destination)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
