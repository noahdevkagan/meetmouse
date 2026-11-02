import SwiftUI

enum ModelCatalogWindow {
    static let id = "model-catalog"
}

struct ModelCatalogScene<Content: View>: Scene {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some Scene {
        Window("Download Models", id: ModelCatalogWindow.id) {
            content
        }
        .windowResizability(.contentSize)
    }
}
