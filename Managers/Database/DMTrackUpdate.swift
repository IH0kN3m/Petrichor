import Foundation
import GRDB

extension DatabaseManager {
    // Updates a track's favorite status
    func updateTrackFavoriteStatus(trackId: Int64, isFavorite: Bool) async throws {
        _ = try await dbQueue.write { db in
            try Track
                .filter(Track.Columns.trackId == trackId)
                .updateAll(db, Track.Columns.isFavorite.set(to: isFavorite))
        }
    }

    // Updates a track's play count and last played date
    func updateTrackPlayInfo(trackId: Int64, playCount: Int, lastPlayedDate: Date) async throws {
        _ = try await dbQueue.write { db in
            try Track
                .filter(Track.Columns.trackId == trackId)
                .updateAll(
                    db,
                    Track.Columns.playCount.set(to: playCount),
                    Track.Columns.lastPlayedDate.set(to: lastPlayedDate)
                )
        }
    }

    // Batch update for track properties (more efficient for multiple updates)
    func updateTrack(_ track: Track) async throws {
        guard track.trackId != nil else {
            throw DatabaseError.invalidTrackId
        }

        try await dbQueue.write { db in
            try track.update(db)
        }
    }
}
