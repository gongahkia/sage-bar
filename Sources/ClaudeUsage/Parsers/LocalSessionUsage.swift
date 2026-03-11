import Foundation

struct LocalSessionUsage: Equatable {
    let sourcePath: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheTokens
    }
}
