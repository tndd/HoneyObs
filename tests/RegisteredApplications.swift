// 登録済みURLだけを読む。登録・起動・解除は行わない。
import CoreServices
import Foundation

guard CommandLine.arguments.count == 3, CommandLine.arguments[2].hasPrefix("/") else { exit(2) }
let identifier = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
var problem: Unmanaged<CFError>?
let result = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, &problem)
let absent: Bool
if let result {
    guard problem == nil, let urls = result.takeRetainedValue() as? [URL], urls.allSatisfy(\.isFileURL) else { exit(1) }
    absent = !urls.contains { $0.resolvingSymlinksInPath() == target }
} else if let problem {
    let error = problem.takeRetainedValue()
    guard CFErrorGetCode(error) == -10814, CFErrorGetDomain(error) as String == NSOSStatusErrorDomain else { exit(1) }
    absent = true
} else {
    exit(1) // 不明な応答を「未登録」と解釈しない。
}
let data = try JSONSerialization.data(withJSONObject: ["identifier": identifier, "path": path, "absent": absent])
print(String(data: data, encoding: .utf8)!)
