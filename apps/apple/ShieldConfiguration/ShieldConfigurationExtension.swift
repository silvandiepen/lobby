// SPDX-License-Identifier: MPL-2.0
import ManagedSettings
import ManagedSettingsUI
import UIKit

/// What a child sees over any other app while the device is locked to Lobby (docs/decisions.md,
/// "Lock to Lobby"): the sparkle door, "Only Lobby right now" and "Ask a grown-up", in place of
/// the system's own shield. OK closes it; there is nothing else to do from there.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        Self.lobby()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        Self.lobby()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.lobby()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        Self.lobby()
    }

    private static func lobby() -> ShieldConfiguration {
        // The kids screens' purple (KidsTheme.page), always dark like them.
        let purple = UIColor(red: 0x4A / 255.0, green: 0x2C / 255.0, blue: 0x82 / 255.0, alpha: 1)
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialDark,
            backgroundColor: purple,
            icon: UIImage(named: "KidsDoor"),
            title: ShieldConfiguration.Label(text: "Only Lobby right now", color: .white),
            subtitle: ShieldConfiguration.Label(
                text: "Ask a grown-up if you want to use something else.", color: UIColor(white: 1, alpha: 0.85)),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: purple),
            primaryButtonBackgroundColor: .white)
    }
}
