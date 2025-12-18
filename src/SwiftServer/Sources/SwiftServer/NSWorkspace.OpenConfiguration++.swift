import AppKit

extension NSWorkspace.OpenConfiguration {
    private static let backgroundLaunchKey = "_kLSOpenOptionBackgroundLaunchKey"
    private static let launchIsUserActionKey = "_kLSOpenOptionLaunchIsUserActionKey"

    private struct PrivateSelectors {
        static let getAdditionalOptions = Selector(("_additionalLSOpenOptions"))
        static let setAdditionalOptions = Selector(("_setAdditionalLSOpenOptions:"))
    }
    
    // Runs `body` on the main thread, synchronously, without deadlocking if already on main.
    private static func onMainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
    
    private func readAdditionalOptions_mainThread() -> [String: Any] {
        guard responds(to: PrivateSelectors.getAdditionalOptions),
              let unmanaged = perform(PrivateSelectors.getAdditionalOptions),
              let dict = unmanaged.takeUnretainedValue() as? NSDictionary
        else { return [:] }
        
        // Copy into Swift-owned storage
        return (dict.copy() as? [String: Any]) ?? [:]
    }
    
    private func writeAdditionalOptions_mainThread(_ options: [String: Any]) {
        guard responds(to: PrivateSelectors.setAdditionalOptions) else { return }
        perform(PrivateSelectors.setAdditionalOptions, with: options as NSDictionary)
    }
    
    private func withAdditionalOptionsThreadSafe(_ mutate: (inout [String: Any]) -> Void) {
        Self.onMainSync {
            var opts = readAdditionalOptions_mainThread()
            mutate(&opts)
            writeAdditionalOptions_mainThread(opts)
        }
    }
    
    // MARK: - Public API (callable from any thread)
    
    public var launchesInBackground: Bool {
        get {
            Self.onMainSync {
                readAdditionalOptions_mainThread()[Self.backgroundLaunchKey] as? Bool ?? false
            }
        }
        set {
            withAdditionalOptionsThreadSafe { $0[Self.backgroundLaunchKey] = newValue }
        }
    }
    
    public var launchIsUserAction: Bool {
        get {
            Self.onMainSync {
                readAdditionalOptions_mainThread()[Self.launchIsUserActionKey] as? Bool ?? false
            }
        }
        set {
            withAdditionalOptionsThreadSafe { $0[Self.launchIsUserActionKey] = newValue }
        }
    }
}
