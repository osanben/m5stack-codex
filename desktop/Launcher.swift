import Foundation
import SwiftUI

@main struct Launcher {
    static func main() throws {
        if CommandLine.arguments.contains("--self-test") { try NativeTests.run(); return }
        if CommandLine.arguments.contains("--snapshot") {
            let provider = NativeCodexProvider(persist: false)
            let data = try JSONSerialization.data(withJSONObject: provider.taskStatus(retention: 72 * 3600), options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return
        }
        AgentDisplayApp.main()
    }
}
