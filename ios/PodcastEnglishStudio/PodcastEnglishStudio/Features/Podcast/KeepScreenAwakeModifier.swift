import CloudSyncKit
import SwiftUI

#if os(iOS)
import UIKit
#endif

// Keeps the device screen awake while audio is playing. The idle timer is disabled only when
// playback is active AND the user's keepScreenAwake setting is enabled, and it is always
// re-enabled on disappear so leaving the screen never leaks the awake state. UIApplication is
// iOS-only, so all idle-timer access is guarded by #if os(iOS); on tvOS and the macOS test host
// the modifier is a no-op.
private struct KeepScreenAwakeModifier: ViewModifier {
    var isActive: Bool

    @Environment(SettingsStore.self) private var settings

    func body(content: Content) -> some View {
        content
            .onAppear { updateIdleTimer() }
            .onChange(of: isActive) { _, _ in updateIdleTimer() }
            .onChange(of: settings.configuration.keepScreenAwake) { _, _ in updateIdleTimer() }
            .onDisappear { setIdleTimerDisabled(false) }
    }

    // Applies the current combined state (playing AND setting enabled) to the idle timer.
    private func updateIdleTimer() {
        setIdleTimerDisabled(isActive && settings.configuration.keepScreenAwake)
    }

    // Sets the idle timer on iOS; a no-op on platforms where UIApplication is unavailable.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

extension View {
    func keepScreenAwake(while isActive: Bool) -> some View {
        modifier(KeepScreenAwakeModifier(isActive: isActive))
    }
}
