import Cocoa

class GradientView: NSView {
    private var gradientLayer: CAGradientLayer?
    private var animationTimer: Timer?
    private var animationProgress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGradient()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGradient()
    }

    private func setupGradient() {
        wantsLayer = true

        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(red: 0.4, green: 0.494, blue: 0.918, alpha: 1.0).cgColor,
            NSColor(red: 0.463, green: 0.294, blue: 0.635, alpha: 1.0).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = bounds

        layer?.addSublayer(gradient)
        gradientLayer = gradient

        // Start animation
        startAnimation()
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
    }

    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            self.animationProgress += 0.005
            if self.animationProgress > 1.0 {
                self.animationProgress = 0
            }

            // Animate gradient position
            let progress = sin(self.animationProgress * .pi * 2) * 0.5 + 0.5
            self.gradientLayer?.startPoint = CGPoint(x: progress, y: 0)
            self.gradientLayer?.endPoint = CGPoint(x: 1 - progress, y: 1)
        }
    }

    deinit {
        animationTimer?.invalidate()
    }
}
