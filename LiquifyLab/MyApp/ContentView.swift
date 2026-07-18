import SwiftUI
import UIKit

@main
struct LiquifyLabApp: App {
    var body: some Scene {
        WindowGroup {
            LiquifyEditorContainer()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}

private struct LiquifyEditorContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        LiquifyEditorViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

#Preview {
    LiquifyEditorContainer()
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
}
