public enum SystemSettingsOnboarding {
    static var onboardingManager: OnboardingManager?

    public static func start() {
        guard onboardingManager == nil else { return }
        let onboardingManager = OnboardingManager()
        self.onboardingManager = onboardingManager
        onboardingManager.createWindow()
    }

    public static func stop() {
        onboardingManager?.closeWindow()
        onboardingManager = nil
    }
}
