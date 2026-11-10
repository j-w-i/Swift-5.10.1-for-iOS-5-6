import UIKit
import Darwin

// UIKit-app regression: stack creation MUST be the first Auto Layout operation.
// Do not set translatesAutoresizingMaskIntoConstraints or construct a constraint
// before init(arrangedSubviews:), or the original bootstrap bug is masked.
final class StackFirstUseController: UIViewController {
    private let label = UILabel()
    private let button = UIButton(type: UIButton.ButtonType(rawValue: 1)!) // roundedRect/system ABI value
    private var stack: UIStackView?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        label.text = "Ready"
        label.font = .systemFont(ofSize: 24)
        button.setTitle("Run Async Test", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20)
        button.addTarget(self, action: #selector(runTest), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        precondition(stack.arrangedSubviews.count == 2)
        precondition(!label.translatesAutoresizingMaskIntoConstraints)
        precondition(!button.translatesAutoresizingMaskIntoConstraints)
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        self.stack = stack
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20)
        ])
        print("PASS stack-first-use constructs arranged subviews and constraints"); fflush(stdout)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // No manual layoutIfNeeded/setNeedsLayout: validate normal UIKit delivery,
            // actual visible geometry, and hit testing rather than just label state.
            guard let stack = self.stack, let window = self.view.window else { preconditionFailure("missing stack/window") }
            precondition(stack.frame.width > 0 && stack.frame.height > 0)
            precondition(self.label.frame.width > 0 && self.label.frame.height > 0)
            precondition(self.button.frame.width > 0 && self.button.frame.height > 0)
            let center = CGPoint(x: self.button.bounds.midX, y: self.button.bounds.midY)
            let point = self.button.convert(center, to: window as UIView?)
            guard let hit = window.hitTest(point, with: nil) else { preconditionFailure("button not hittable") }
            precondition(hit === self.button || hit.isDescendant(of: self.button))
            print("PASS nonzero visible stack geometry and button hit testing"); fflush(stdout)
            self.button.sendActions(for: .touchUpInside)
        }
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
            try? await Task.sleep(nanoseconds: 100_000_000)
            let natural = label.sizeThatFits(CGSize(width: 10000, height: 10000))
            precondition(label.frame.width + 0.5 >= natural.width, "final label must grow, not truncate")
            print("PASS five async main-actor steps, button re-enable and readable final label"); fflush(stdout)
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
