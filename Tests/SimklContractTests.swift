import XCTest
@testable import Nuvio

final class SimklContractTests: XCTestCase {
    func testLibrarySnapshotAcceptsMixedIdsAndProjectsAndroidStatuses() throws {
        let data = Data(#"""
        {
          "shows": [
            {
              "status": "watching",
              "added_to_watchlist_at": "2026-08-20T10:00:00Z",
              "show": {"title":"Severance","poster":"aa/bb","year":2022,"ids":{"imdb":"tt11280740","simkl":123}}
            }
          ],
          "movies": [
            {
              "status": "plantowatch",
              "movie": {"title":"Arrival","year":2016,"ids":{"tmdb":329865}}
            }
          ],
          "anime": [
            {
              "status": "completed",
              "anime_type": "movie",
              "show": {"title":"Perfect Blue","year":1997,"ids":{"mal":437}}
            }
          ]
        }
        """#.utf8)

        let lists = try SimklClient.decodeLibrarySnapshot(data)

        XCTAssertEqual(lists.map(\.id), ["watching", "plantowatch", "completed"])
        XCTAssertEqual(lists[0].items.first?.id, "tt11280740")
        XCTAssertEqual(lists[1].items.first?.id, "tmdb:329865")
        XCTAssertEqual(lists[2].items.first?.id, "mal:437")
        XCTAssertEqual(lists[2].items.first?.type, .movie)
    }

    func testLibrarySnapshotAcceptsSimklEmptyArray() throws {
        XCTAssertTrue(try SimklClient.decodeLibrarySnapshot(Data("[]".utf8)).isEmpty)
    }

    func testLibraryProjectionDeduplicatesTheSameTitleWithinAStatus() throws {
        let data = Data(#"""
        {"shows":[
          {"status":"watching","show":{"title":"Lost","ids":{"imdb":"tt0411008"}}},
          {"status":"watching","show":{"title":"Lost duplicate","ids":{"imdb":"tt0411008"}}}
        ]}
        """#.utf8)

        let lists = try SimklClient.decodeLibrarySnapshot(data)
        XCTAssertEqual(lists.first?.items.count, 1)
    }
}
