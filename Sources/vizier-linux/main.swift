import Foundation
import Glibc
import VizierCLI

@main
struct VizierMain {
    static func main() async {
        exit(await CLI.run(Array(CommandLine.arguments.dropFirst())))
    }
}
