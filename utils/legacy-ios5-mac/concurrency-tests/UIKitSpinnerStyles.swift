import UIKit
import Darwin
// Run as a UIKit app: pre-UIApplicationMain spinner creation is invalid on iOS 5.
final class SpinnerTestDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        for value in [0, 1, 2, 100, 101] {
            let style = UIActivityIndicatorView.Style(rawValue: value)!
            let spinner = UIActivityIndicatorView(style: style)
            window.addSubview(spinner)
            spinner.startAnimating()
            precondition(spinner.isAnimating)
            spinner.stopAnimating()
            spinner.style = style
            print("PASS spinner init/set/animate style=\(value)")
            fflush(stdout)
        }
        DispatchQueue.main.async { exit(0) }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(SpinnerTestDelegate.self))
