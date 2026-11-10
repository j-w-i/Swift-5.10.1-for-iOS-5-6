import UIKit
import Darwin

// UIKit-app regression: stack creation MUST be the first Auto Layout operation.
// Do not set translatesAutoresizingMaskIntoConstraints or construct a constraint
// before init(arrangedSubviews:), or the original bootstrap bug is masked.
final class StackFirstUseController: UIViewController {
    private let label = UILabel()
    private let button = UIButton(type: UIButton.ButtonType(rawValue: 1)!) // roundedRect/system ABI value
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        label.text = "Ready"
        button.setTitle("Run Async Test", for: .normal)
        button.addTarget(self, action: #selector(runTest), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        precondition(stack.arrangedSubviews.count == 2)
        precondition(!label.translatesAutoresizingMaskIntoConstraints)
        precondition(!button.translatesAutoresizingMaskIntoConstraints)
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20)
        ])
        print("PASS stack-first-use constructs arranged subviews and constraints"); fflush(stdout)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        button.sendActions(for: .touchUpInside)
    }
    @objc private func runTest() {
        button.isEnabled = false
        Task { @MainActor in
            for step in 1...5 {
                label.text = "Step \(step)/5"
                precondition(Thread.isMainThread)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            label.text = "Async/Await works!"
            button.isEnabled = true
            precondition(Thread.isMainThread && button.isEnabled)
            print("PASS five async main-actor steps and button re-enable"); fflush(stdout)
            try? "STACK FIRST USE PASS".write(toFile: NSHomeDirectory() + "/Documents/stack-first-use-result.txt", atomically: true, encoding: .utf8)
        }
    }
}
final class StackFirstUseDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = StackFirstUseController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(StackFirstUseDelegate.self))
