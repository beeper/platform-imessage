public enum SystemSettingsOnboarding {
    @MainActor
    static var onboardingManager: OnboardingManager?

    @MainActor
    public static func start() {
        guard onboardingManager == nil else { return }
        let onboardingManager = OnboardingManager()
        self.onboardingManager = onboardingManager
        onboardingManager.createWindow()
    }

    @MainActor
    public static func stop() {
        onboardingManager?.closeWindow()
        onboardingManager = nil
    }
}
