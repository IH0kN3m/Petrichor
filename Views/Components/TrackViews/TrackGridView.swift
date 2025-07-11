import SwiftUI

struct TrackGridView: View {
    let tracks: [Track]
    let onPlayTrack: (Track) -> Void
    let contextMenuItems: (Track) -> [ContextMenuItem]

    @EnvironmentObject var playbackManager: PlaybackManager
    @State private var gridWidth: CGFloat = 0
    @State private var visibleRange: Range<Int> = 0..<0

    private let itemWidth: CGFloat = 180
    private let itemHeight: CGFloat = 240
    private let spacing: CGFloat = 16

    private var columns: Int {
        max(1, Int((gridWidth + spacing) / (itemWidth + spacing)))
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: columns)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { _ in
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: spacing) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackGridItem(
                                track: track
                            ) {
                                    let isCurrentTrack = playbackManager.currentTrack?.url.path == track.url.path
                                    if !isCurrentTrack {
                                        onPlayTrack(track)
                                    }
                            }
                            .frame(width: itemWidth, height: itemHeight)
                            .contextMenu {
                                TrackContextMenuContent(items: contextMenuItems(track))
                            }
                            .id(track.id)
                            .onAppear {
                                updateVisibleRange(index: index)
                            }
                        }
                    }
                    .padding()
                    .onAppear {
                        // Preheat grid thumbnails when the grid becomes visible. This mirrors TrackListView’s logic so
                        // scrolling is already buttery-smooth when the cells appear.
                        ThumbnailPreheater.shared.preheat(tracks: tracks)
                    }
                }
                .background(Color.clear)
                .onAppear {
                    gridWidth = geometry.size.width - 32
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    gridWidth = newWidth - 32
                }
            }
        }
    }

    private func updateVisibleRange(index: Int) {
        // Track visible range for potential future optimizations
        if visibleRange.isEmpty {
            visibleRange = index..<(index + 1)
        } else {
            visibleRange = min(visibleRange.lowerBound, index)..<max(visibleRange.upperBound, index + 1)
        }
    }
}

// MARK: - Track Grid Item (Optimized)
private struct TrackGridItem: View {
    @ObservedObject var track: Track
    let onPlay: () -> Void

    @EnvironmentObject var playbackManager: PlaybackManager
    @State private var isHovered = false
    @State private var artworkImage: NSImage?
    @State private var artworkLoadTask: Task<Void, Never>?

    private var isCurrentTrack: Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        return currentTrack.url.path == track.url.path
    }

    private var isPlaying: Bool {
        isCurrentTrack && playbackManager.isPlaying
    }

    var body: some View {
        VStack(spacing: 8) {
            artworkSection
            trackInfoSection
        }
        .padding(8)
        .background(backgroundView)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) {
            onPlay()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onAppear {
            loadArtworkIfNeeded()
        }
        .onDisappear {
            // Cancel artwork loading if view disappears
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            // Clear artwork to free memory when off-screen
            artworkImage = nil
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var artworkSection: some View {
        ZStack {
            artworkView

            if isHovered || isCurrentTrack {
                playOverlay
                    .transition(.opacity)
            }

            if isCurrentTrack && isPlaying {
                playingIndicatorOverlay
            }
        }
        .frame(width: 160, height: 160)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage = artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .overlay(
                    Image(systemName: Icons.musicNote)
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                )
        }
    }

    private var playOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.4))
            .overlay(
                Button(action: {
                    if isCurrentTrack {
                        playbackManager.togglePlayPause()
                    } else {
                        onPlay()
                    }
                }) {
                    Image(systemName: isPlaying ? Icons.pauseFill : Icons.playFill)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.borderless)
            )
    }

    private var playingIndicatorOverlay: some View {
        VStack {
            HStack {
                Spacer()
                PlayingIndicator()
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
            Spacer()
        }
    }

    private var trackInfoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title)
                .font(.system(size: 14, weight: isCurrentTrack ? .medium : .regular))
                .foregroundColor(isCurrentTrack ? .accentColor : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(track.artist)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if !track.album.isEmpty && track.album != "Unknown Album" {
                Text(track.album)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 160, alignment: .leading)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                isPlaying ?
                (isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.08) : Color.clear) :
                (isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.1), value: isHovered)
    }

    // MARK: - Artwork Loading

    private func loadArtworkIfNeeded() {
        guard artworkImage == nil, artworkLoadTask == nil else { return }

        // Attempt cache first – extremely fast on the main thread.
        let cacheKey = "\(track.id.uuidString)-track-grid"
        if let cached = ImageCache.shared.image(forKey: cacheKey) {
            artworkImage = cached
            return
        }

        artworkLoadTask = Task {
            // Yield once so layout finishes before we tackle decoding.
            await Task.yield()

            guard !Task.isCancelled else { return }

            if let data = track.artworkData,
               let thumbnail = ThumbnailGenerator.makeThumbnailLimited(from: data, maxPixelSize: 320) { // 160pt * 2
                ImageCache.shared.insertImage(thumbnail, forKey: cacheKey)

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.artworkImage = thumbnail
                }
            }

            await MainActor.run { self.artworkLoadTask = nil }
        }
    }
}
