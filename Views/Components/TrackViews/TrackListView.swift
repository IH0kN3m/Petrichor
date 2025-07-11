import SwiftUI
import Combine

struct TrackListView: View {
    let tracks: [Track]
    let onPlayTrack: (Track) -> Void
    let contextMenuItems: (Track) -> [ContextMenuItem]
    let sortByDiscAndTrackNumber: Bool

    @EnvironmentObject var playbackManager: PlaybackManager
    // Hover tracking is now handled within each row itself to avoid triggering full list re-renders.

    // MARK: - Pre-computed section model

    // An album section contains all discs → tracks that belong to the same album.
    private struct DiscGroup: Identifiable {
        let id = UUID()
        let discNumber: Int
        let tracks: [Track]
    }

    private struct AlbumSection: Identifiable {
        let id = UUID()
        let albumName: String
        let discGroups: [DiscGroup]
    }

    @State private var sections: [AlbumSection] = []
    @State private var hasMultipleAlbums = false

    // Triggers async recomputation whenever the track list or sort flag changes.
    private var recomputeKey: String {
        "\(tracks.count)-\(sortByDiscAndTrackNumber)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(sections) { section in
                    // albumTracks flattened if needed in the future – not currently used

                    // Album header if multiple albums
                    if sortByDiscAndTrackNumber && hasMultipleAlbums {
                        HStack {
                            Text(section.albumName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.vertical, 6)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                    }

                    ForEach(section.discGroups) { discGroup in
                        // Disc header when needed
                        if sortByDiscAndTrackNumber && (section.discGroups.count > 1 || discGroup.discNumber > 1) {
                            HStack {
                                Text("Disc \(discGroup.discNumber)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 4)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                        }
                        ForEach(discGroup.tracks, id: \.id) { track in
                            TrackListRow(
                                track: track,
                                onPlay: {
                                let isCurrentTrack = playbackManager.currentTrack?.url.path == track.url.path
                                    if !isCurrentTrack {
                                        onPlayTrack(track)
                                    }
                                }
                            )
                            .equatable()
                            .contextMenu {
                                TrackContextMenuContent(items: contextMenuItems(track))
                            }
                            .id(track.id)
                        }
                    }
                }
            }
            .padding(5)
            .onAppear {
                ThumbnailPreheater.shared.preheat(tracks: tracks)
            }
        }
        // Recompute grouping & sorting *off-thread* whenever the key changes.
        .task(id: recomputeKey) {
            await computeSections()
        }
    }

    // MARK: - Async processing

    @MainActor
    private func apply(sections newSections: [AlbumSection], hasMultipleAlbums flag: Bool) {
        self.sections = newSections
        self.hasMultipleAlbums = flag
    }

    private func computeSections() async {
        // Perform heavy work on a background thread.
        let tracksCopy = tracks // Capture value outside MainActor
        let sortFlag = sortByDiscAndTrackNumber

        let result = await Task.detached(priority: .userInitiated) { () -> (Bool, [AlbumSection]) in
            // 1. Sorting
            let sortedTracks: [Track]

            if sortFlag {
                let multiAlbum = Set(tracksCopy.map { $0.album }).count > 1

                sortedTracks = tracksCopy.sorted { lhs, rhs in
                    if multiAlbum {
                        let albumCmp = lhs.album.localizedCaseInsensitiveCompare(rhs.album)
                        if albumCmp != .orderedSame { return albumCmp == .orderedAscending }
                    }

                    let disc1 = lhs.discNumber ?? 1
                    let disc2 = rhs.discNumber ?? 1
                    if disc1 != disc2 { return disc1 < disc2 }

                    let num1 = lhs.trackNumber ?? Int.max
                    let num2 = rhs.trackNumber ?? Int.max
                    return num1 < num2
                }
            } else {
                sortedTracks = tracksCopy
            }

            let hasMultiple = Set(sortedTracks.map { $0.album }).count > 1

            // 2. Grouping by album / disc
            var albumSections: [AlbumSection] = []
            var currentAlbum = ""
            var currentTracks: [Track] = []

            func flushAlbum() {
                guard !currentAlbum.isEmpty else { return }
                let discGrouped = Dictionary(grouping: currentTracks) { $0.discNumber ?? 1 }
                let discGroups = discGrouped.keys.sorted().map { DiscGroup(discNumber: $0, tracks: discGrouped[$0]!.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }) }
                albumSections.append(AlbumSection(albumName: currentAlbum, discGroups: discGroups))
                currentTracks.removeAll(keepingCapacity: true)
            }

            for track in sortedTracks {
                if track.album != currentAlbum {
                    flushAlbum()
                    currentAlbum = track.album
                }
                currentTracks.append(track)
            }
            flushAlbum()

            return (hasMultiple, albumSections)
        }.value

        await MainActor.run {
            apply(sections: result.1, hasMultipleAlbums: result.0)
        }
    }
}

// MARK: - Track List Row
private final class TrackRowViewModel: ObservableObject {
    @Published var title: String
    @Published var artist: String
    @Published var album: String
    @Published var year: String
    @Published var duration: Double
    @Published var isMetadataLoaded: Bool

    private var cancellables = Set<AnyCancellable>()

    init(track: Track) {
        // Seed initial values
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
        self.year = track.year
        self.duration = track.duration
        self.isMetadataLoaded = track.isMetadataLoaded

        // Subscribe only to the properties we actually display
        track.$title.receive(on: RunLoop.main).sink { [weak self] in self?.title = $0 }.store(in: &cancellables)
        track.$artist.receive(on: RunLoop.main).sink { [weak self] in self?.artist = $0 }.store(in: &cancellables)
        track.$album.receive(on: RunLoop.main).sink { [weak self] in self?.album = $0 }.store(in: &cancellables)
        track.$year.receive(on: RunLoop.main).sink { [weak self] in self?.year = $0 }.store(in: &cancellables)
        track.$duration.receive(on: RunLoop.main).sink { [weak self] in self?.duration = $0 }.store(in: &cancellables)
        track.$isMetadataLoaded.receive(on: RunLoop.main).sink { [weak self] in self?.isMetadataLoaded = $0 }.store(in: &cancellables)
    }
}

private struct TrackListRow: View, Equatable {
    let track: Track
    let onPlay: () -> Void

    @StateObject private var vm: TrackRowViewModel

    // Custom initialiser to seed the view model once.
    init(track: Track, onPlay: @escaping () -> Void) {
        self.track = track
        self.onPlay = onPlay
        _vm = StateObject(wrappedValue: TrackRowViewModel(track: track))
    }

    // Local hover state to avoid propagating changes to the parent list view.
    @State private var isHovered = false

    @EnvironmentObject var playbackManager: PlaybackManager
    @State private var artworkImage: NSImage?
    @State private var artworkLoadTask: Task<Void, Never>? // Task to manage async artwork loading and allow cancellation

    var body: some View {
        HStack(spacing: 0) {
            playButtonSection
            trackContent
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onPlay)
        }
        .frame(height: 60)
        .background(backgroundView)
        // Creating a separate CoreAnimation layer for the row dramatically reduces
        // the cost of blending text + thumbnail while scrolling.
        .compositingGroup()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Computed Properties

    private var isCurrentTrack: Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        return currentTrack.url.path == track.url.path
    }

    private var isPlaying: Bool {
        isCurrentTrack && playbackManager.isPlaying
    }

    // MARK: - View Components

    private var playButtonSection: some View {
        ZStack {
            if shouldShowPlayButton {
                Button(action: handlePlayButtonTap) {
                    Image(systemName: playButtonIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)  // Changed from playButtonColor
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else if isPlaying && !isHovered {
                PlayingIndicator()
                    .frame(width: 16)
                    .transition(.scale.combined(with: .opacity))
            } else {
                // Show track number when not showing play button or playing indicator
                Text(trackNumberText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 40, height: 40)
        .animation(.easeInOut(duration: AnimationDuration.standardDuration), value: shouldShowPlayButton)
        .animation(.easeInOut(duration: AnimationDuration.standardDuration), value: isPlaying)
    }

    private var trackContent: some View {
        HStack(spacing: 12) {
            albumArtwork
            trackInfo
            Spacer()
            durationLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var albumArtwork: some View {
        Group {
            if let artworkImage = artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if vm.isMetadataLoaded {
                placeholderArtwork
            } else {
                loadingArtwork
            }
        }
        // Perform artwork loading with Task for better cancellation and concurrency control
        .onAppear {
            loadArtworkAsync()
        }
        .onDisappear {
            // Cancel loading task and clear image to free memory
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkImage = nil
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: Icons.musicNote)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            )
    }

    private var loadingArtwork: some View {
        ProgressView()
            .scaleEffect(0.5)
            .frame(width: 40, height: 40)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(4)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleLabel
            detailsLabel
        }
    }

    private var titleLabel: some View {
        Text(vm.title)
            .font(.system(size: 14, weight: isCurrentTrack ? .medium : .regular))
            .foregroundColor(isCurrentTrack ? .accentColor : .primary)
            .lineLimit(1)
            .redacted(reason: vm.isMetadataLoaded ? [] : .placeholder)
    }

    private var detailsLabel: some View {
        HStack(spacing: 4) {
            Text(vm.artist)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .redacted(reason: vm.isMetadataLoaded ? [] : .placeholder)

            if shouldShowAlbum {
                Text("•")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text(vm.album)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .redacted(reason: vm.isMetadataLoaded ? [] : .placeholder)
            }

            if shouldShowYear {
                Text("•")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text(vm.year)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var durationLabel: some View {
        Text(formatDuration(vm.duration))
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .monospacedDigit()
            .redacted(reason: vm.isMetadataLoaded ? [] : .placeholder)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(backgroundColor)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
    }

    // MARK: - Helper Properties

    private var shouldShowPlayButton: Bool {
        // Show button if:
        // 1. Hovered (play or pause depending on state)
        // 2. Current track but paused (persistent play button)
        isHovered || (isCurrentTrack && !playbackManager.isPlaying)
    }

    private var playButtonIcon: String {
        if isCurrentTrack {
            return isPlaying ? Icons.pauseFill : Icons.playFill
        }
        return Icons.playFill
    }

    private var playButtonColor: Color {
        isCurrentTrack ? .accentColor : .primary
    }

    private var backgroundColor: Color {
        if isPlaying {
            return isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.08) : Color.clear
        } else if isHovered {
            return Color(NSColor.selectedContentBackgroundColor).opacity(0.15)
        } else {
            return Color.clear
        }
    }

    private var shouldShowAlbum: Bool {
        !vm.album.isEmpty && vm.album != "Unknown Album"
    }

    private var shouldShowYear: Bool {
        vm.isMetadataLoaded && !vm.year.isEmpty && vm.year != "Unknown Year"
    }

    // MARK: - Methods

    private func handlePlayButtonTap() {
        if isCurrentTrack {
            playbackManager.togglePlayPause()
        } else {
            onPlay()
        }
    }

    /// Optimized artwork loading with caching and limited concurrency thumbnail generation (similar to EntityListView)
    private func loadArtworkAsync() {
        // Prevent duplicate tasks
        guard artworkLoadTask == nil else { return }

        // Unified cache key – always use the larger grid thumbnail so we never decode twice.
        let cacheKey = "\(track.id.uuidString)-track-grid"
        if let cachedImage = ImageCache.shared.image(forKey: cacheKey) {
            self.artworkImage = cachedImage
            return
        }

        artworkLoadTask = Task {
            // Yield once to allow SwiftUI finish layout before heavy work
            await Task.yield()

            guard !Task.isCancelled else { return }

            if let data = track.artworkData {
                // Generate downsampled thumbnail with concurrency limit
                if let thumbnailImage = ThumbnailGenerator.makeThumbnailLimited(from: data, maxPixelSize: 320) { // Grid size — reuse for list
                    ImageCache.shared.insertImage(thumbnailImage, forKey: cacheKey)

                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.artworkImage = thumbnailImage
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(max(0, seconds))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: StringFormat.mmss, minutes, remainingSeconds)
    }

    private var trackNumberText: String {
        if let num = track.trackNumber {
            return String(num)
        }
        return ""
    }

    static func == (lhs: TrackListRow, rhs: TrackListRow) -> Bool {
        lhs.track.id == rhs.track.id && lhs.isHovered == rhs.isHovered
    }
}
