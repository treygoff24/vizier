import Foundation
import Glibc
import VizierCLI
import CCosmicFocus

@main
struct VizierMain {
    static func main() async {
        // Isolate Wayland reads and their timeout from the running take engine.
        if Array(CommandLine.arguments.dropFirst()) == ["--cosmic-focused-app"] {
            exit(vizier_cosmic_focused_app())
        }
        exit(await CLI.run(Array(CommandLine.arguments.dropFirst())))
    }
}
