import AppKit
import Combine
import SwiftUI
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SettingsBackupRoundTripTests: XCTestCase {
    private final class SearchFieldWriteProbe: NSSearchField {
        var writes = 0
        override var stringValue: String {
            get { super.stringValue }
            set { self.writes += 1; super.stringValue = newValue }
        }
    }

    func testSearchTypingDoesNotEchoCharactersIntoNativeEditor() {
        var text = ""
        var focused = false
        let input = SidebarSearchInput(
            text: Binding(get: { text }, set: { text = $0 }), placeholder: "Search Settings", isActive: true,
            isFocused: Binding(get: { focused }, set: { focused = $0 })
        )
        let coordinator = input.makeCoordinator()
        let field = SearchFieldWriteProbe()
        for letter in "audio" {
            field.stringValue.append(letter)
            field.writes = 0
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            coordinator.synchronizeExternalText(text, in: field)
            XCTAssertEqual(field.writes, 0, "SwiftUI must not reapply an in-progress native edit")
        }
        XCTAssertEqual(text, "audio")
        text = ""
        coordinator.synchronizeExternalText(text, in: field)
        XCTAssertEqual(field.stringValue, "", "Explicit Clear must still reach the native field")
    }

    func testPersonalIdentityImportsPreferencesOnceWithoutCredentials() throws {
        let suite = "MurmurMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "ExistingSetting")
        let old: [String: Any] = ["ExistingSetting": "overwrite", "SavedModel": "parakeet", "ProviderAPIKeys": ["openai": "test-only"], "MicrophoneSelectionMode": "manual"]
        SettingsStore.migratePersonalAppIdentityIfNeeded(defaults: defaults, bundleIdentifier: "dev.cymule.murmur", previousPreferences: old)
        XCTAssertEqual(defaults.string(forKey: "ExistingSetting"), "keep")
        XCTAssertEqual(defaults.string(forKey: "SavedModel"), "parakeet")
        XCTAssertNil(defaults.object(forKey: "ProviderAPIKeys"))
        XCTAssertEqual(defaults.string(forKey: "MicrophoneSelectionMode"), "followSystem")
        defaults.set("manual", forKey: "MicrophoneSelectionMode")
        SettingsStore.migratePersonalAppIdentityIfNeeded(defaults: defaults, bundleIdentifier: "dev.cymule.murmur", previousPreferences: old)
        XCTAssertEqual(defaults.string(forKey: "MicrophoneSelectionMode"), "manual")
    }

    func testDraggedOverlayPositionSurvivesBackupAndRestore() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let placement = SettingsStore.OverlayPlacement(displayID: "external-monitor", x: 0.85, y: 0.3)
            settings.overlayPlacement = placement
            let payload = settings.makeBackupPayload()
            let restored = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONEncoder().encode(payload))
            settings.overlayPlacement = nil
            settings.restore(from: restored, promptProfiles: settings.dictationPromptProfiles, appPromptBindings: [])
            XCTAssertEqual(settings.overlayPlacement, placement)
            let oldBackup = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            var legacy = oldBackup
            legacy.removeValue(forKey: "overlayPlacement")
            let oldPayload = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertNil(oldPayload.overlayPlacement)
        }
    }

    func testPreviewResizeKeepsTopLeftAndSurvivesNextPresentation() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let controller = BottomOverlayWindowController.shared
            settings.overlaySize = .small
            settings.overlayPlacement = .init(displayID: "fallback", x: 0.4, y: 0.4)
            defer { controller.hideImmediately(); controller.destroyWindowForTests() }
            controller.show(audioPublisher: Empty<CGFloat, Never>().eraseToAnyPublisher(), mode: .dictation)
            let panel = try XCTUnwrap(NSApp.windows.first { $0 is BottomOverlayPanel })
            let original = panel.frame
            controller.beginResizing(at: .zero)
            controller.resize(to: CGPoint(x: 70, y: -50))
            controller.finishResizing()
            let resized = panel.frame
            XCTAssertEqual(resized.minX, original.minX, accuracy: 1)
            XCTAssertEqual(resized.maxY, original.maxY, accuracy: 1)
            XCTAssertEqual(resized.width, original.width + 70, accuracy: 1)
            XCTAssertEqual(resized.height, original.height + 50, accuracy: 1)
            let payload = settings.makeBackupPayload()
            let restored = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONEncoder().encode(payload))
            settings.overlaySize = .medium
            XCTAssertNil(settings.overlayCustomSize)
            settings.restore(from: restored, promptProfiles: settings.dictationPromptProfiles, appPromptBindings: [])
            XCTAssertEqual(settings.overlayCustomSize, payload.overlayCustomSize)
            controller.hideImmediately()
            controller.show(audioPublisher: Empty<CGFloat, Never>().eraseToAnyPublisher(), mode: .dictation)
            XCTAssertEqual(panel.frame.width, resized.width, accuracy: 1)
            XCTAssertEqual(panel.frame.height, resized.height, accuracy: 1)
            XCTAssertEqual(panel.frame.minX, resized.minX, accuracy: 1)
            XCTAssertEqual(panel.frame.minY, resized.minY, accuracy: 1)
        }
    }

    func testStablePreviewDefaultPreservesUserResizing() throws {
        let suite = "MurmurPreviewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("small", forKey: "OverlaySize")
        SettingsStore.migrateStablePreviewSizeIfNeeded(defaults: defaults, bundleIdentifier: "dev.cymule.murmur")
        let data = try XCTUnwrap(defaults.data(forKey: "MurmurOverlayCustomSize"))
        XCTAssertEqual(try JSONDecoder().decode(SettingsStore.OverlayCustomSize.self, from: data), SettingsStore.defaultPreviewSize)
        let custom = SettingsStore.OverlayCustomSize(width: 420, height: 180)
        defaults.set(try JSONEncoder().encode(custom), forKey: "MurmurOverlayCustomSize")
        defaults.removeObject(forKey: "MurmurStablePreviewV1")
        SettingsStore.migrateStablePreviewSizeIfNeeded(defaults: defaults, bundleIdentifier: "dev.cymule.murmur")
        XCTAssertEqual(try JSONDecoder().decode(SettingsStore.OverlayCustomSize.self, from: XCTUnwrap(defaults.data(forKey: "MurmurOverlayCustomSize"))), custom)
    }

    func testCustomPreviewFrameStaysFixedAsTranscriptWraps() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let controller = BottomOverlayWindowController.shared
            settings.overlaySize = .small
            settings.overlayCustomSize = SettingsStore.defaultPreviewSize
            settings.enableStreamingPreview = true
            defer { controller.hideImmediately(); controller.destroyWindowForTests() }
            controller.show(audioPublisher: Empty<CGFloat, Never>().eraseToAnyPublisher(), mode: .dictation)
            let panel = try XCTUnwrap(NSApp.windows.first { $0 is BottomOverlayPanel })
            let original = panel.frame
            for (index, text) in ["", "This preview wraps onto several lines and keeps the visualizer, app icon, and Dictate controls at the bottom while you speak."].enumerated() {
                NotchContentState.shared.updateTranscription(text)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                panel.contentView?.layoutSubtreeIfNeeded()
                XCTAssertEqual(panel.frame, original)
                if let view = panel.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/murmur-preview-\(index).png"))
                }
            }
            XCTAssertEqual(panel.frame.width, 312, accuracy: 0.5)
            XCTAssertEqual(panel.frame.height, 140, accuracy: 0.5)
        }
    }

    func testCustomPreviewSizeHasSafeBounds() {
        XCTAssertEqual(SettingsStore.OverlayCustomSize(width: 50, height: 20).clamped, .init(width: 180, height: 96))
        XCTAssertEqual(SettingsStore.OverlayCustomSize(width: 1000, height: 1000).clamped, .init(width: 600, height: 360))
        XCTAssertEqual(SettingsStore.OverlayCustomSize(width: .nan, height: .infinity).clamped, SettingsStore.defaultPreviewSize)
    }

    func testSavedOverlayPositionIsReusedAcrossPresentations() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let controller = BottomOverlayWindowController.shared
            let saved = SettingsStore.OverlayPlacement(displayID: "fallback-screen", x: 0.8, y: 0.4)
            settings.overlaySize = .small
            settings.overlayPlacement = saved
            defer {
                controller.hideImmediately()
                controller.destroyWindowForTests()
            }
            for _ in 0..<2 {
                controller.show(audioPublisher: Empty<CGFloat, Never>().eraseToAnyPublisher(), mode: .dictation)
                let panel = try XCTUnwrap(NSApp.windows.first { $0 is BottomOverlayPanel })
                let screen = try XCTUnwrap(panel.screen)
                let expected = BottomOverlayWindowController.savedOrigin(for: panel.frame.size, visibleFrame: screen.visibleFrame, placement: saved)
                XCTAssertEqual(panel.frame.minX, expected.x, accuracy: 1)
                XCTAssertEqual(panel.frame.minY, expected.y, accuracy: 1)
                XCTAssertEqual(panel.frame.width, SettingsStore.defaultPreviewSize.width, accuracy: 1)
                controller.hideImmediately()
            }
        }
    }

    func testSavedOverlayPositionClampsAfterDisplayAndSizeChanges() {
        let visible = CGRect(x: -1200, y: 40, width: 1200, height: 760)
        let placement = SettingsStore.OverlayPlacement(displayID: "removed", x: 1.2, y: 1)
        for size in [CGSize(width: 220, height: 90), CGSize(width: 600, height: 300)] {
            let origin = BottomOverlayWindowController.savedOrigin(for: size, visibleFrame: visible, placement: placement)
            XCTAssertTrue(visible.contains(CGRect(origin: origin, size: size)))
            XCTAssertEqual(origin.x, visible.maxX - size.width - 8)
            XCTAssertEqual(origin.y, visible.maxY - size.height - 8)
        }
    }

    func testFollowSystemMicrophoneModeSurvivesBackupRestore() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.recordInputDeviceSelection("usb", name: "USB microphone")
            settings.microphoneSelectionMode = .followSystem
            let payload = settings.makeBackupPayload()
            let restored = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONEncoder().encode(payload))
            settings.microphoneSelectionMode = .manual
            settings.restore(from: restored, promptProfiles: settings.dictationPromptProfiles, appPromptBindings: [])
            XCTAssertEqual(settings.microphoneSelectionMode, .followSystem)
            XCTAssertEqual(settings.microphoneSelectionMigrationVersion, SettingsStore.microphonePriorityMigrationVersion)
        }
    }

    func testModernBackupExportsAndRestoresMeetingIdleAndPromptConfiguration() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "backup-dictation")
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.dictationPromptProfiles = [profile]
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .oneHour
            settings.dictationPromptConfigurations = configurations
            let payload = settings.makeBackupPayload()
            let encoded = try JSONEncoder().encode(payload)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNotNil(json["meetingRecordingDefaults"])
            XCTAssertEqual(json["privateAIIdleUnload"] as? Int, 60)
            XCTAssertNotNil(json["dictationPromptConfigurations"])

            settings.meetingRecordingDefaults = .unconfigured
            settings.privateAIIdleUnload = .never
            settings.dictationPromptConfigurations = [:]
            settings.dictationPromptProfiles = []
            try settings.restore(
                from: JSONDecoder().decode(SettingsBackupPayload.self, from: encoded),
                promptProfiles: [profile],
                appPromptBindings: []
            )
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .oneHour)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 3)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    func testLegacyAbsentFieldsPreserveCurrentPreferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "legacy-survivor")
            settings.dictationPromptProfiles = [profile]
            let payload = try self.payload(removing: [
                "meetingRecordingDefaults", "privateAIIdleUnload", "dictationPromptConfigurations",
            ])
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .thirtyMinutes
            settings.dictationPromptConfigurations = configurations
            settings.restore(from: payload, promptProfiles: [profile], appPromptBindings: [])
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .thirtyMinutes)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
        }
    }

    func testExplicitEmptyPromptConfigurationsClearPreviousMappings() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.dictationPromptConfigurations = [:]
            let payload = settings.makeBackupPayload()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            XCTAssertEqual((json["dictationPromptConfigurations"] as? [String: Any])?.count, 0)
            settings.dictationPromptConfigurations = self.configurations(profileID: "previous")
            settings.restore(from: payload, promptProfiles: [], appPromptBindings: [])
            XCTAssertTrue(settings.dictationPromptConfigurations.isEmpty)
            XCTAssertTrue(settings.dictationPromptShortcutAssignments().isEmpty)
        }
    }

    func testImportedPromptConfigurationsUseRestoredProfilesAndCannotActivateInvalidReferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let valid = self.profile(id: "imported")
            let edit = self.profile(id: "edit-only", mode: .edit)
            let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .option])
            let imported: [String: SettingsStore.DictationPromptConfiguration] = [
                "profile:imported": .init(shortcut: shortcut, providerID: "openai", modelName: "imported-model"),
                "profile:missing": .init(shortcut: shortcut, providerID: "openai", modelName: "missing-model"),
                "profile:edit-only": .init(shortcut: shortcut, providerID: "openai", modelName: "edit-model"),
                "unknown": .init(shortcut: shortcut),
                "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: []), providerID: "openai", modelName: "default-model"),
                "__privateAI__": .init(shortcut: shortcut, providerID: "apple-intelligence", modelName: "retired-model"),
            ]
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.makeBackupPayload())) as? [String: Any])
            json["dictationPromptConfigurations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported))
            let payload = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
            settings.dictationPromptProfiles = [self.profile(id: "previous")]
            settings.dictationPromptConfigurations = ["profile:previous": .init(shortcut: shortcut)]
            settings.restore(from: payload, promptProfiles: [valid, edit], appPromptBindings: [])

            XCTAssertEqual(settings.dictationPromptConfigurations["profile:imported"], imported["profile:imported"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:missing"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:edit-only"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:previous"])
            XCTAssertNil(settings.dictationPromptConfigurations["unknown"])
            XCTAssertNil(settings.dictationPromptConfiguration(for: .default).shortcut)
            XCTAssertEqual(settings.dictationPromptConfiguration(for: .default).modelName, "default-model")
            XCTAssertEqual(settings.dictationPromptConfigurations["__privateAI__"], .init(shortcut: shortcut))
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 2)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    private func payload(removing keys: [String]) throws -> SettingsBackupPayload {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsStore.shared.makeBackupPayload())) as? [String: Any])
        for key in keys {
            json.removeValue(forKey: key)
        }
        return try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func profile(id: String, mode: SettingsStore.PromptMode = .dictate) -> SettingsStore.DictationPromptProfile {
        .init(id: id, name: "Backup fixture", prompt: "Keep these words", mode: mode)
    }

    private func configurations(profileID: String) -> [String: SettingsStore.DictationPromptConfiguration] {
        [
            "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: .control), providerID: "openai", modelName: "default-model"),
            "__privateAI__": .init(shortcut: HotkeyShortcut(keyCode: 3, modifierFlags: .control), providerID: "fluid-fixture", modelName: "private-model"),
            "profile:\(profileID)": .init(shortcut: HotkeyShortcut(keyCode: 5, modifierFlags: .control), providerID: "custom:fixture", modelName: "profile-model"),
        ]
    }

    private func meetingDefaults() -> MeetingRecordingDefaults {
        .init(
            isConfigured: true,
            mode: .inRoom,
            applicationBundleIdentifier: "fixture.meeting",
            applicationDisplayName: "Fixture Meeting",
            microphoneCaptureDeviceID: "fixture-capture",
            microphoneCoreAudioUID: "fixture-core-audio",
            microphoneRole: .shared,
            languageCode: "fr"
        )
    }

    private func withSavedDefaults(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let original = defaults.persistentDomain(forName: domain)
        defer {
            if let original {
                defaults.setPersistentDomain(original, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        try body()
    }
}
