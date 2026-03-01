import Foundation

public enum CLIArgumentUtils {
    public static func removingWatchFlag(arguments: [String]) -> [String] {
        var result: [String] = []
        var idx = 0
        while idx < arguments.count {
            if arguments[idx] == "--watch" {
                idx += 1
                if idx < arguments.count {
                    idx += 1
                }
                continue
            }
            result.append(arguments[idx])
            idx += 1
        }
        return result
    }
}
