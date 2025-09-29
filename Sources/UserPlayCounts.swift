import ArgumentParser
import Foundation
import Supabase

struct UserCountsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upc",
        abstract: "Update user play counts"
    )
    @Option(help: "API access key")
    var apikey: String

    func run() async throws {
        let client = try SupabaseClientFactory.createClient()

        print("Updating user play counts...")
        let artistCount = try await Database.updateUserPlayCounts(client: client)
        print("Updated \(artistCount) artist play count records")

        print("Updating user track counts...")
        let trackCount = try await Database.updateUserTrackCounts(client: client)
        print("Updated \(trackCount) track count records")

        print("Updating user weekly plays...")
        let weeklyCount = try await Database.updateUserWeeklyPlays(client: client)
        print("Updated \(weeklyCount) weekly play records")

        print("Stats update completed successfully!")
    }
}
