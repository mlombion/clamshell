import ClamshellCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private let root = RootViewController()

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let w = UIWindow(windowScene: scene)
    w.rootViewController = root
    w.makeKeyAndVisible()
    window = w
    if let url = options.urlContexts.first?.url { handle(url) }
  }

  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    if let url = contexts.first?.url { handle(url) }
  }

  private func handle(_ url: URL) {
    guard let p = PairingInfo(url: url) else { return }
    DispatchQueue.main.async { [root] in
      _ = root.view
      root.pair(p)
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) { root.resumeSession() }
  func sceneDidEnterBackground(_ scene: UIScene) { root.suspendSession() }
}
