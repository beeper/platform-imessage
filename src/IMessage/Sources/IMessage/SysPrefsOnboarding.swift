enum SysPrefsOnboarding {
    static var onboardingManager: OnboardingManager?

    static func start() {
        guard onboardingManager == nil else { return }
        let onboardingManager = OnboardingManager()
        self.onboardingManager = onboardingManager
        onboardingManager.createWindow()
    }

    static func stop() {
        onboardingManager?.closeWindow()
        onboardingManager = nil
    }
}
