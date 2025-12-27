import AppKit
import Combine
import SwiftServerFoundation
import SwiftUI

@available(macOS 13, *)
struct SettingsView: View {
    @AppStorage(DefaultsKeys.coordinator, store: Defaults.swiftServer)
    var coordinator: String = ""
    
    @AppStorage(DefaultsKeys.misfirePreventionTracingPII, store: Defaults.swiftServer)
    var misfirePreventionTracingPII: Bool = false
    
    @AppStorage(DefaultsKeys.windowCoordination, store: Defaults.swiftServer)
    var windowCoordination: Bool = true
    
    @AppStorage(DefaultsKeys.hidingCoordinatorDebounce, store: Defaults.swiftServer)
    var hidingCoordinatorDebounce = 0.75
    
    @AppStorage(DefaultsKeys.misfirePrevention, store: Defaults.swiftServer)
    var misfirePrevention: Bool = true
    
    @AppStorage(DefaultsKeys.misfirePreventionAlwaysFallback, store: Defaults.swiftServer)
    var misfirePreventionAlwaysFallback: Bool = false
    
    @AppStorage(DefaultsKeys.imCoreSPI, store: Defaults.swiftServer)
    var imCoreSPI: Bool = true
    
    @AppStorage(DefaultsKeys.contactsAttemptFormattingWithShortStyle, store: Defaults.swiftServer)
    var contactsAttemptFormattingWithShortStyle: Bool = true
    
    @AppStorage(DefaultsKeys.predictionPredictsGroupChats, store: Defaults.swiftServer)
    var predictionPredictsGroupChats = true
    
    @AppStorage(DefaultsKeys.eclipsingUsesLargestWindow, store: Defaults.swiftServer)
    var eclipsingUsesLargestWindow = true
    
    @AppStorage(DefaultsKeys.eclipsingDebug, store: Defaults.swiftServer)
    var eclipsingDebug = false
    
    @AppStorage(DefaultsKeys.spacesObserveDock, store: Defaults.swiftServer)
    var spacesObserveDock = true
    
    // help button popover
    @State private var presentingHelp = false
    
    // "are you sure you want to enable logging?"
    @State private var presentingPrivacyAlert = false
    @State private var hasConsentedOnce = false
    
    // when user tries to enable, ask them if they'd like to purge log files
    @State private var presentingPurgeAlert = false
    @State private var purgeError: Error?
    
    static var windowTitle: String {
        "On-Device iMessage Connection Settings"
    }
    
    var piiToggle: Binding<Bool> {
        Binding(get: {
            misfirePreventionTracingPII
        }, set: { intention in
            guard intention != misfirePreventionTracingPII else {
                return
            }
            
            if intention {
                // enabling
                guard hasConsentedOnce else {
                    presentingPrivacyAlert = true
                    return
                }
            } else {
                // disabling
                presentingPurgeAlert = true
                // make the user choose whether to keep existing PII in logs;
                // actually affect the default when handling the alert
                return
            }
            
            misfirePreventionTracingPII = intention
        })
    }
    
    var body: some View {
        VStack {
            Form {
                windowCoordinationSection
                misfirePreventionSection
                spacesSection
                diagnosticsSection
                
                HStack {
                    showLogFileInFinderButton
                    Spacer()
                    helpButton
                }
            }
        }
        .navigationTitle(Text(Self.windowTitle))
        .formStyle(.grouped)
        .alert("Couldn’t Purge Log", isPresented: .init(get: { purgeError != nil }, set: { _ in })) {
            Button("Show in Finder") {
                Log.reveal()
            }
            Button("OK") {}
        } message: {
            Text("Try manually purging the log file by moving it to the Trash.")
        }
        .alert("Purge existing personal data from logs?", isPresented: $presentingPurgeAlert) {
            Button("Stop Logging and Purge") {
                do {
                    try Log.purge()
                } catch {
                    purgeError = error
                }
                misfirePreventionTracingPII = false
            }
            Button("Stop Logging and Keep") {
                misfirePreventionTracingPII = false
            }
            Button("Continue Logging", role: .cancel) {}
        } message: {
            Text("""
            Even when not logging personal data, historically logged personal data \
            will continue to be sent in problem reports unless it’s purged, \
            or until it’s removed by occasional log maintenance.
            """)
        }
        .alert("Begin recording chat and contact data to send when reporting problems?", isPresented: $presentingPrivacyAlert) {
            Button("Start Logging My Data") {
                hasConsentedOnce = true
                misfirePreventionTracingPII = true
            }
            
            Button("Cancel", role: .cancel) {
                // FIXME: currently does nothing
            }
        } message: {
            Text("""
            Contact names, email addresses, phone numbers, group chat names, and \
            group chat member names will be included in the diagnostic information sent \
            to Beeper when reporting a problem.
            
            After you’ve collected the relevant data and sent a report, \
            you can stop logging personal data and choose to purge your logs \
            as to only send as much personal data is necessary.
            
            Message content and attachments are never recorded.
            """)
        }
        .frame(width: 600, height: 400)
    }
    
    @ViewBuilder
    private var windowCoordinationSection: some View {
        Section {
            Picker("Window Coordinator Override", selection: $coordinator) {
                Text("Edge Coordinator")
                    .tag("edge")
                Text("Eclipsing Coordinator")
                    .tag("eclipsing")
                Text("Spaces Coordinator")
                    .tag("spaces")
                Text("Default")
                    .tag("")
            }
            
            Toggle(isOn: $windowCoordination) {
                Text("Coordinate the Messages window")
                Text("Allow Beeper to manage the Messages window when needed.")
            }
            
            HStack {
                Stepper("Debounce before hiding the Messages window", onIncrement: {
                    hidingCoordinatorDebounce += 0.05
                }, onDecrement: {
                    hidingCoordinatorDebounce -= 0.05
                })
                Spacer()
                TextField("", value: $hidingCoordinatorDebounce, format: .number.precision(.fractionLength(2)))
                    .frame(width: 80)
                Text("s")
            }
            
            Toggle(isOn: $eclipsingUsesLargestWindow) {
                Text("Use the largest window for eclipsing")
            }
            
            Toggle(isOn: $eclipsingDebug) {
                Text("Show eclipsing debug visualization")
            }
        } header: {
            Text("Window Coordination")
            Text("Controls whether window coordination happens at all. Changes take effect immediately.")
        } footer: {
        }
    }
    
    @ViewBuilder
    private var misfirePreventionSection: some View {
        Section {
            Toggle(isOn: $misfirePrevention) {
                Text("Misfire prevention")
                Text("Reduce the chance of acting on the wrong chat when selecting threads.")
            }
            
            Toggle(isOn: $misfirePreventionAlwaysFallback) {
                Text("Always use fallback strategy")
            }
            
            Toggle(isOn: $imCoreSPI) {
                Text("Use IMCore SPI for title prediction")
            }
            
            Toggle(isOn: $contactsAttemptFormattingWithShortStyle) {
                Text("Format contacts with private short style")
            }
            
            Toggle(isOn: $predictionPredictsGroupChats) {
                Text("Predict group chats")
            }
        } header: {
            Text("Thread Selection Safety")
        } footer: {
        }
    }
    
    @ViewBuilder
    private var spacesSection: some View {
        Section {
            Toggle(isOn: $spacesObserveDock) {
                Text("Observe Dock relaunches for hidden space behavior")
            }
        } header: {
            Text("Spaces")
        } footer: {
        }
    }
    
    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            Toggle(isOn: piiToggle) {
                Text("Log chat and contact information to send in future problem reports")
                Text("""
                Record identifying information such as contact names, phone numbers, \
                group names, and group chat members.
                """)
            }
        } header: {
            Text("Troubleshooting with Personal Data")
            Text("""
            Only consider enabling these settings if you’d like to submit \
            personal data as part of a problem report, which can help diagnose \
            certain issues. Normally, personal data is not logged to protect \
            your privacy.
            """)
        } footer: {
        }
    }
    
    @ViewBuilder
    private var showLogFileInFinderButton: some View {
        Button("Show Log in Finder…") {
            Log.reveal()
        }
    }
    
    @ViewBuilder
    private var helpButton: some View {
        HelpButton {
            presentingHelp = true
        }
        .popover(isPresented: $presentingHelp, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                As you use iMessage with Beeper, various mechanisms are used \
                to ensure that the actions you perform (sending messages, archiving chats, etc.) \
                affect only the intended recipients. This involves personal chat and contact information, \
                which normally isn’t logged to keep your data private, but needs to be processed by
                the app in order to work. If you need to submit a problem report, then \
                choosing to include personal data relevant to the problem at hand may \
                help with investigation.
                """)
                
                Text("""
                Note that any recorded personal information may be included in submitted problem reports, \
                even after the relevant settings are turned off; historical diagnostic data is only deleted \
                during occasional maintenance, which doesn’t run consistently. To resolve this, \
                press “Show Log in Finder…”, remove the selected log file, and completely restart \
                the app. You are also prompted to do this when turning off personal data logging.
                """)
                
                Text("For more information, visit [beeper.com/privacy](https://www.beeper.com/privacy).")
            }
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .frame(width: 300)
            .padding()
        }
    }
}

@available(macOS 13, *)
#Preview {
    SettingsView()
}
