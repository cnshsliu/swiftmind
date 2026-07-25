import SwiftUI

@main
struct SwiftMindMacApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: SwiftMindFileDocument()) { file in
            ContentView(document: file.$document)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) { } // wire later via environment
        }
    }
}
