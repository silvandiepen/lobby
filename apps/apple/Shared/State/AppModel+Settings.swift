// SPDX-License-Identifier: MPL-2.0
import LobbyKit

extension AppModel {
    /// Who is in front of Settings, for `SettingsMap` to choose the pages.
    var settingsAudience: SettingsAudience {
        let profile = activeProfile
        #if os(macOS)
        let sidebarHasCategories = true
        #else
        let sidebarHasCategories = false
        #endif
        return SettingsAudience(
            level: device?.level ?? .viewer,
            isGuest: isGuest,
            isKidsMode: isKidsMode,
            isConnected: connection != nil,
            hasViewer: profile != nil,
            offersPlayback: offersPlaybackPreferences,
            offersSubtitles: offersSubtitlePreferences,
            offersSkipping: offersSkipPreferences,
            sidebarHasCategories: sidebarHasCategories,
            needsSetup: serverSetup?.needed == true)
    }
}
