import Cocoa
import Quartz
import ServiceManagement

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Stores whether the menu bar icon is hidden.
    let hideStatusItemPreferenceKey = "hideStatusItemFromMenuBar"
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let unlockRSSIMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    let externalDisplayMenu = NSMenu()
    let sleepRSSIMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem : NSMenuItem?
    let prefs = UserDefaults.standard
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var nowPlayingWasPlaying = false
    var aboutBox: AboutBox? = nil
    var wakeTimer: Timer?
    var manualLock = false
    var unlockedAt = 0.0
    var inScreensaver = false
    var lastRSSI: Int? = nil
    var externalDisplayModelOnly = false
    var didRunEventScriptSinceLock = false

    var customNames: [String: String] {
        get { prefs.dictionary(forKey: "customDeviceNames") as? [String: String] ?? [:] }
        set { prefs.set(newValue, forKey: "customDeviceNames") }
    }

    func updateMonitorMenuTitle() {
        let prefix: String
        if let uuid = ble.monitoredUUID, let name = customNames[uuid.uuidString], !name.isEmpty {
            prefix = name + ": "
        } else {
            prefix = ""
        }
        if connected, let r = lastRSSI {
            monitorMenuItem?.title = prefix + String(format: "%ddBm", r)
        } else {
            monitorMenuItem?.title = prefix.isEmpty ? t("not_detected") : prefix + t("not_detected")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.startScanning()
        } else if menu == lockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.lockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == unlockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.unlockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == sleepRSSIMenu {
            for item in menu.items {
                if item.tag == ble.sleepRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == timeoutMenu {
            for item in menu.items {
                if item.tag == Int(ble.signalTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == lockDelayMenu {
            for item in menu.items {
                if item.tag == Int(ble.proximityTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == externalDisplayMenu {
            updateExternalMonitor()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.menu == lockRSSIMenu {
            return menuItem.tag < ble.unlockRSSI
        } else if menuItem.menu == unlockRSSIMenu {
            return menuItem.tag >= ble.lockRSSI
        } else if menuItem.menu == sleepRSSIMenu {
            return menuItem.tag < ble.lockRSSI || menuItem.tag == ble.LOCK_DISABLED
        } else if menuItem.action == #selector(renameDevice) {
            return ble.monitoredUUID != nil
        }
        return true
    }

    @objc func renameDevice() {
        guard let uuid = ble.monitoredUUID else { return }

        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("rename_device")
        msg.informativeText = t("rename_device_info")
        msg.window.title = "BLEUnlock"

        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = t("rename_device_placeholder")
        if let existing = customNames[uuid.uuidString] {
            txt.stringValue = existing
        }
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()

        if response == .alertFirstButtonReturn {
            var names = customNames
            let name = txt.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                names.removeValue(forKey: uuid.uuidString)
            } else {
                names[uuid.uuidString] = name
            }
            customNames = names
            updateMonitorMenuTitle()
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.stopScanning()
        }
    }
    
    func menuItemTitle(device: Device) -> String {
        let customName = customNames[device.uuid.uuidString]
        let label = customName.flatMap { $0.isEmpty ? nil : $0 } ?? device.description
        let desc: String
        if let mac = device.macAddr {
            let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
            desc = "\(label) (\(prettifiedMac))"
        } else {
            desc = label
        }
        return String(format: "%@ (%ddBm)", desc, device.rssi)
    }
    
    func newDevice(device: Device) {
        let title = menuItemTitle(device: device)
        
        // Check for duplicate menu items by title (without RSSI) to catch duplicates that slipped through
        let titleWithoutRSSI = title.components(separatedBy: " (").first ?? title
        var duplicateUUID: UUID? = nil
        for (existingUUID, existingItem) in deviceDict {
            if existingUUID != device.uuid {
                let existingTitle = existingItem.title
                let existingTitleWithoutRSSI = existingTitle.components(separatedBy: " (").first ?? existingTitle
                if existingTitleWithoutRSSI == titleWithoutRSSI {
                    duplicateUUID = existingUUID
                    break
                }
            }
        }
        
        if let dupUUID = duplicateUUID {
            // Find the actual device from BLE and remove it properly
            if let dupDevice = ble.devices[dupUUID] {
                removeDevice(device: dupDevice)
            } else {
                // Fallback: just remove from menu and dict
                if let menuItem = deviceDict[dupUUID] {
                    menuItem.menu?.removeItem(menuItem)
                }
                deviceDict.removeValue(forKey: dupUUID)
            }
        }
        
        let menuItem = deviceMenu.addItem(withTitle: title, action:#selector(selectDevice), keyEquivalent: "")
        deviceDict[device.uuid] = menuItem
        if (device.uuid == ble.monitoredUUID) {
            menuItem.state = .on
        }
    }
    
    func updateDevice(device: Device) {
        if let menu = deviceDict[device.uuid] {
            menu.title = menuItemTitle(device: device)
        }
    }
    
    func removeDevice(device: Device) {
        if let menuItem = deviceDict[device.uuid] {
            menuItem.menu?.removeItem(menuItem)
        }
        deviceDict.removeValue(forKey: device.uuid)
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        // Keep updating the status item even when it is hidden.
        if let r = rssi {
            lastRSSI = r
            if (!connected) {
                connected = true
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            if (connected) {
                connected = false
                statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            }
        }
        updateMonitorMenuTitle()
        if let r = rssi, active {
            monitorMenuItem?.title += " (Active)"
        }
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String) {
        let un = NSUserNotification()
        un.title = "BLEUnlock"
        if reason == "lost" {
            un.subtitle = t("notification_lost_signal")
        } else if reason == "away" {
            un.subtitle = t("notification_device_away")
        }
        un.informativeText = t("notification_locked")
        un.deliveryDate = Date().addingTimeInterval(1)
        NSUserNotificationCenter.default.scheduleNotification(un)
        userNotification = un
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if notification != userNotification {
            NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        }
    }

    func runScript(_ arg: String) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        if let r = lastRSSI {
            process.arguments = [arg, String(r)]
        } else {
            process.arguments = [arg]
        }
        try? process.run()
    }

    func pauseNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(
            DispatchQueue.main,
            { (playing) in
                self.nowPlayingWasPlaying = playing
                if self.nowPlayingWasPlaying {
                    print("pause")
                    MRMediaRemoteSendCommand(MRCommandPause, nil)
                }
            }
        )
    }
    
    func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        if nowPlayingWasPlaying {
            print("play")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
                MRMediaRemoteSendCommand(MRCommandPlay, nil)
                self.nowPlayingWasPlaying = false
            })
        }
    }

    func lockOrSaveScreen() {
        DiagnosticsLogger.shared.log("lock_requested", fields: [
            "method": prefs.bool(forKey: "screensaver") ? "screensaver" : "immediate",
            "lastRSSI": lastRSSI.map(String.init) ?? "nil",
        ])
        if prefs.bool(forKey: "screensaver") {
            NSWorkspace.shared.launchApplication("ScreenSaverEngine")
            DiagnosticsLogger.shared.log("lock_started", fields: ["method": "screensaver"])
        } else {
            let status = SACLockScreenImmediate()
            DiagnosticsLogger.shared.log("lock_result", fields: ["status": String(status)])
            if status != 0 {
                print("Failed to lock screen")
            }
            if prefs.bool(forKey: "sleepDisplay") {
                print("sleep display")
                sleepDisplay()
            }
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        DiagnosticsLogger.shared.log("presence_changed", fields: [
            "presence": String(presence),
            "reason": reason,
            "lastRSSI": lastRSSI.map(String.init) ?? "nil",
            "lockRSSI": String(ble.lockRSSI),
            "unlockRSSI": String(ble.unlockRSSI),
        ])
        if presence {
            if ble.unlockRSSI != ble.UNLOCK_DISABLED {
                if let un = userNotification {
                    NSUserNotificationCenter.default.removeDeliveredNotification(un)
                    userNotification = nil
                }
                if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                    print("Waking display")
                    wakeDisplay()
                    wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { _ in
                        print("Retrying waking display")
                        wakeDisplay()
                    })
                }
                tryUnlockScreen()
            }
        } else {
            // Turn off the screen (without locking) when the device is far away.
            if (!displaySleep && ble.sleepRSSI != ble.LOCK_DISABLED &&
                (lastRSSI == nil || lastRSSI! <= ble.sleepRSSI)) {
                print("sleep display due to RSSI threshold")
                sleepDisplay()
                displaySleep = true // Mark as sleeping to prevent lock
                return // Skip lock logic
            }
            if ble.lockRSSI != ble.LOCK_DISABLED {
                let locked = isScreenLocked()
                if !locked {
                    pauseNowPlaying()
                    lockOrSaveScreen()
                    notifyUser(reason)
                }
                if (!locked || prefs.bool(forKey: "runEventScriptWhileLocked")) && !didRunEventScriptSinceLock {
                    runScript(reason)
                    didRunEventScriptSinceLock = true
                }
            }
            manualLock = false
        }
    }

    func fakeKeyStrokes(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Send 20 characters per keyboard event. That seems to be the limit.
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
        
        // Return key
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }
    
    func getDisplayUUIDs() -> [(localizedName: String, uuidString: String)] {
        var displayInfoArray: [(localizedName: String, uuidString: String)] = []
        
        let screens = NSScreen.screens
        for screen in screens {
            let deviceDescription = screen.deviceDescription
            if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                let uuidRef = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeRetainedValue()
                if let uuidRef = uuidRef {
                    let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuidRef) as String
                    if #available(macOS 10.15, *) {
                        displayInfoArray.append((localizedName: screen.localizedName, uuidString: uuidString))
                    } else {
                        displayInfoArray.append((localizedName: uuidString, uuidString: uuidString))
                    }
                }
            }
        }
        return displayInfoArray
    }
    
    func updateExternalMonitor() {
        externalDisplayMenu.removeAllItems()
        let selectedDisplayUUIDs = prefs.array(forKey: "externalDisplays") as? [String] ?? []
        let displays = getDisplayUUIDs()
        
        for display in displays {
            let menuItem = NSMenuItem(title: display.localizedName, action: nil, keyEquivalent: "")
            menuItem.representedObject = display.uuidString
            
            if display.localizedName.contains("Built-in") {
                menuItem.isEnabled = false
            } else {
                menuItem.action = #selector(setExternalDisplays(_:))
                menuItem.target = self
                menuItem.state = selectedDisplayUUIDs.contains(display.uuidString) ? .on : .off
            }
            
            externalDisplayMenu.addItem(menuItem)
        }
    }
    
    func isExternalDisplayConnected() -> Bool {
        let selectedDisplayUUIDs = prefs.array(forKey: "externalDisplays") as? [String] ?? []
        
        if selectedDisplayUUIDs.isEmpty {
            return false
        }
        
        let connectedDisplayUUIDs = getDisplayUUIDs().map { $0.uuidString }
        
        return selectedDisplayUUIDs.allSatisfy { connectedDisplayUUIDs.contains($0) }
    }
    
    func tryUnlockScreen() {
        // Diagnostics: state of every gate on each unlock attempt.
        DiagnosticsLogger.shared.log("unlock_attempt", fields: [
            "manualLock": String(manualLock),
            "presence": String(ble.presence),
            "systemSleep": String(systemSleep),
            "displaySleep": String(displaySleep),
            "screenLocked": String(isScreenLocked()),
            "accessibility": String(AXIsProcessTrusted()),
        ])
        func skip(_ reason: String) {
            DiagnosticsLogger.shared.log("unlock_skipped", fields: ["reason": reason])
        }
        guard !manualLock else { skip("manual_lock"); return }
        guard ble.presence else { skip("no_presence"); return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { skip("unlock_disabled"); return }
        guard !systemSleep else { skip("system_sleep"); return }
        guard !displaySleep else { skip("display_sleep"); return }

        if inScreensaver {
            // In screensaver, make sure Login panel is displayed
            let src = CGEventSource(stateID: .hidSystemState)
            // Esc key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }
        
        if self.prefs.bool(forKey: "externalDisplayModelOnly") && !isExternalDisplayConnected() {
            print("External Display is not connected")
            skip("external_display_missing")
            return
        }

        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { skip("wake_without_unlocking"); return }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
            // Diagnostics: the two conditions that decide whether the password is typed.
            DiagnosticsLogger.shared.log("unlock_check", fields: [
                "screenLocked": String(self.isScreenLocked()),
                "accessibility": String(AXIsProcessTrusted()),
            ])
            guard self.isScreenLocked() else { return }
            // macOS 26 and later keep the password field hidden and consume the first key
            // event to reveal it. fakeKeyStrokes sends up to 20 characters in a single
            // event, so that first event takes the whole password with it and the screen
            // stays locked. Wake the field up first with keys that insert no text.
            self.nudgeLockScreen()
            Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false, block: { _ in
                self.enterPassword(attempt: 1)
            })
        })
    }

    /// Presses keys that reveal the lock screen's password field without typing a character.
    func nudgeLockScreen() {
        let src = CGEventSource(stateID: .hidSystemState)
        // Left and up arrow: real key presses, but they add nothing to a password field.
        for key in [CGKeyCode(0x7B), CGKeyCode(0x7E)] {
            CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        }
        DiagnosticsLogger.shared.log("lock_screen_nudged")
    }

    /// Selects everything in the password field and deletes it, so a retry can never type
    /// the password twice into the same field.
    func clearPasswordField() {
        let src = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        let aDown = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true)
        let aUp = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        for event in [cmdDown, aDown, aUp, cmdUp] {
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func enterPassword(attempt: Int) {
        guard isScreenLocked() else {
            DiagnosticsLogger.shared.log("unlock_ok", fields: ["attempt": String(attempt)])
            return
        }
        guard let password = self.fetchPassword(warn: attempt == 1) else {
            DiagnosticsLogger.shared.log("unlock_skipped", fields: ["reason": "no_password"])
            return
        }

        print("Entering password")
        DiagnosticsLogger.shared.log("password_typed", fields: ["attempt": String(attempt)])
        if attempt == 1 {
            self.unlockedAt = Date().timeIntervalSince1970
        }
        self.fakeKeyStrokes(password)
        if attempt == 1 {
            self.playNowPlaying()
            self.runScript("unlocked")
        }

        // Verify: if the screen is still locked the keystrokes did not get through, so clear
        // the field and try once more.
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false, block: { _ in
            let locked = self.isScreenLocked()
            DiagnosticsLogger.shared.log(locked ? "unlock_still_locked" : "unlock_ok",
                                         fields: ["attempt": String(attempt)])
            guard locked, attempt < 2 else { return }
            self.clearPasswordField()
            self.enterPassword(attempt: attempt + 1)
        })
    }

    @objc func onDisplayWake() {
        print("display wake")
        DiagnosticsLogger.shared.log("display_wake")
        //unlockedAt = Date().timeIntervalSince1970
        displaySleep = false
        wakeTimer?.invalidate()
        wakeTimer = nil
        tryUnlockScreen()
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        DiagnosticsLogger.shared.log("display_sleep")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("system wake")
        DiagnosticsLogger.shared.log("system_wake")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            print("delayed system wake job")
            NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
            self.systemSleep = false
            self.tryUnlockScreen()
        })
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        DiagnosticsLogger.shared.log("system_sleep")
        systemSleep = true
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
    }

    @objc func onUnlock() {
        didRunEventScriptSinceLock = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            print("onUnlock")
            if Date().timeIntervalSince1970 >= self.unlockedAt + 10 {
                if self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED {
                    self.runScript("intruded")
                }
                self.playNowPlaying()
            }
        })
        manualLock = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            checkUpdate()
        })
    }

    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
    }

    @objc func selectDevice(item: NSMenuItem) {
        for (uuid, menuItem) in deviceDict {
            if menuItem == item {
                monitorDevice(uuid: uuid)
                prefs.set(uuid.uuidString, forKey: "device")
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
        }
    }

    func monitorDevice(uuid: UUID) {
        connected = false
        lastRSSI = nil
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        ble.startMonitor(uuid: uuid)
        updateMonitorMenuTitle()
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecAttrLabel): "BLEUnlock",
            String(kSecValueData): pw,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let err = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to store password to Keychain", info: err as String? ?? "Status \(status)")
            return
        }
    }

    func fetchPassword(warn: Bool = false) -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if (status == errSecItemNotFound) {
            print("Password is not stored")
            if warn {
                errorModal(t("password_not_set"))
            }
            return nil
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            errorModal("Failed to convert password")
            return nil
        }
        return String(data: data, encoding: .utf8)!
    }
    
    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "BLEUnlock"

        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let pw = txt.stringValue
            storePassword(pw)
        }
    }
    
    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLEUnlock"
        
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let val = txt.intValue
            ble.thresholdRSSI = Int(val)
            prefs.set(val, forKey: "thresholdRSSI")
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "wakeOnProximity")
    }
    
    @objc func toggleExternalDisplayModeOnly(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "externalDisplayModelOnly")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "externalDisplayModelOnly")
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockRSSI")
        ble.lockRSSI = value
    }
    
    @objc func setUnlockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "unlockRSSI")
        ble.unlockRSSI = value
    }
    
    @objc func setSleepRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "sleepRSSI")
        ble.sleepRSSI = value
    }

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "timeout")
        ble.signalTimeout = Double(value)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, launchAtLogin)
    }

    @objc func togglePauseNowPlaying(_ menuItem: NSMenuItem) {
        let pauseNowPlaying = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseNowPlaying, forKey: "pauseItunes")
        menuItem.state = pauseNowPlaying ? .on : .off
    }

    @objc func toggleRunEventScriptWhileLocked(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "runEventScriptWhileLocked")
        prefs.set(value, forKey: "runEventScriptWhileLocked")
        menuItem.state = value ? .on : .off
    }
    
    @objc func toggleUseScreensaver(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "screensaver")
        prefs.set(value, forKey: "screensaver")
        menuItem.state = value ? .on : .off
    }

    @objc func toggleSleepDisplay(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "sleepDisplay")
        prefs.set(value, forKey: "sleepDisplay")
        menuItem.state = value ? .on : .off
    }
    
    @objc func togglePassiveMode(_ menuItem: NSMenuItem) {
        let passiveMode = !prefs.bool(forKey: "passiveMode")
        prefs.set(passiveMode, forKey: "passiveMode")
        menuItem.state = passiveMode ? .on : .off
        ble.setPassiveMode(passiveMode)
    }

    @objc func toggleWakeWithoutUnlocking(_ menuItem: NSMenuItem) {
        let wakeWithoutUnlocking = !prefs.bool(forKey: "wakeWithoutUnlocking")
        prefs.set(wakeWithoutUnlocking, forKey: "wakeWithoutUnlocking")
        menuItem.state = wakeWithoutUnlocking ? .on : .off
    }
    
    @objc func setExternalDisplays(_ menuItem: NSMenuItem) {
        guard let uuidString = menuItem.representedObject as? String else { return }
      
        menuItem.state = (menuItem.state == .on) ? .off : .on
      
        var selectedDisplayUUIDs = prefs.array(forKey: "externalDisplays") as? [String] ?? []
        if menuItem.state == .on {
            selectedDisplayUUIDs.append(uuidString)
        } else {
            selectedDisplayUUIDs.removeAll { $0 == uuidString }
        }
        prefs.set(selectedDisplayUUIDs, forKey: "externalDisplays")
    }

    @objc func toggleHideMenuBarIcon(_ menuItem: NSMenuItem) {
        let hideMenuBarIcon = !prefs.bool(forKey: hideStatusItemPreferenceKey)
        prefs.set(hideMenuBarIcon, forKey: hideStatusItemPreferenceKey)
        menuItem.state = hideMenuBarIcon ? .on : .off

        // Apply the visibility change immediately.
        statusItem.isVisible = !hideMenuBarIcon
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        pauseNowPlaying()
        lockOrSaveScreen()
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }

    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("scanning"), action: nil, keyEquivalent: "")

        mainMenu.addItem(withTitle: t("rename_device"), action: #selector(renameDevice), keyEquivalent: "")

        let unlockRSSIItem = mainMenu.addItem(withTitle: t("unlock_rssi"), action: nil, keyEquivalent: "")
        unlockRSSIItem.submenu = unlockRSSIMenu
        item = unlockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setUnlockRSSI), keyEquivalent: "")
        item.tag = ble.UNLOCK_DISABLED
        constructRSSIMenu(unlockRSSIMenu, #selector(setUnlockRSSI))

        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: "")
        item.tag = ble.LOCK_DISABLED
        
        let sleepRSSIItem = mainMenu.addItem(withTitle: t("sleep_rssi"), action: nil, keyEquivalent: "")
            sleepRSSIItem.submenu = sleepRSSIMenu
            constructRSSIMenu(sleepRSSIMenu, #selector(setSleepRSSI))
            item = sleepRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setSleepRSSI), keyEquivalent: "")
            item.tag = ble.LOCK_DISABLED

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }
        
        mainMenu.addItem(NSMenuItem.separator())
        item = mainMenu.addItem(withTitle: t("external_display_mode_only"), action: #selector(toggleExternalDisplayModeOnly), keyEquivalent: "")
        if prefs.bool(forKey: "externalDisplayModelOnly") {
            item.state = .on
        }
        
        item = mainMenu.addItem(withTitle: t("external_displays"), action: nil, keyEquivalent: "")
        item.submenu = externalDisplayMenu
        externalDisplayMenu.delegate = self
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("wake_without_unlocking"), action: #selector(toggleWakeWithoutUnlocking), keyEquivalent: "")
        if prefs.bool(forKey: "wakeWithoutUnlocking") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("pause_now_playing"), action: #selector(togglePauseNowPlaying), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("run_event_script_while_locked"), action: #selector(toggleRunEventScriptWhileLocked), keyEquivalent: "")
        if prefs.bool(forKey: "runEventScriptWhileLocked") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver), keyEquivalent: "")
        if prefs.bool(forKey: "screensaver") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("sleep_display"), action: #selector(toggleSleepDisplay), keyEquivalent: "")
        if prefs.bool(forKey: "sleepDisplay") {
            item.state = .on
        }
        
        mainMenu.addItem(withTitle: t("set_password"), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off

        item = mainMenu.addItem(withTitle: t("hide_menu_bar_icon"), action: #selector(toggleHideMenuBarIcon), keyEquivalent: "")
        item.state = prefs.bool(forKey: hideStatusItemPreferenceKey) ? .on : .off
        
        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        // Keep the menu attached to the status item.
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if (!AXIsProcessTrustedWithOptions([key: true] as CFDictionary)) {
            // Sometimes Prompt option above doesn't work.
            // Actually trying to send key may open that dialog.
            let src = CGEventSource(stateID: .hidSystemState)
            // "Fn" key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    func resetHiddenMenuBarIconState() {
        guard prefs.bool(forKey: hideStatusItemPreferenceKey) else { return }

        // Show the icon again when the app is reopened.
        prefs.set(false, forKey: hideStatusItemPreferenceKey)
        statusItem.isVisible = true

        if let item = mainMenu.items.first(where: { $0.action == #selector(toggleHideMenuBarIcon) }) {
            item.state = .off
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
        }
        constructMenu()

        let hideMenuBarIcon = prefs.bool(forKey: hideStatusItemPreferenceKey)

        // Restore the saved visibility state on launch.
        statusItem.isVisible = !hideMenuBarIcon

        ble.delegate = self
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI != 0 {
            ble.lockRSSI = lockRSSI
        }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI")
        if unlockRSSI != 0 {
            ble.unlockRSSI = unlockRSSI
        }
        let sleepRSSI = prefs.integer(forKey: "sleepRSSI")
            if sleepRSSI != 0 {
                ble.sleepRSSI = sleepRSSI
        }
        let timeout = prefs.integer(forKey: "timeout")
        if timeout != 0 {
            ble.signalTimeout = Double(timeout)
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if thresholdRSSI != 0 {
            ble.thresholdRSSI = thresholdRSSI
        }
        let lockDelay = prefs.integer(forKey: "lockDelay")
        if lockDelay != 0 {
            ble.proximityTimeout = Double(lockDelay)
        }

        // Start monitoring only after all persisted BLE settings are applied.
        // Otherwise startMonitor() creates a signal timer with the default
        // 60-second timeout before the configured timeout is loaded.
        if let str = prefs.string(forKey: "device"),
           let uuid = UUID(uuidString: str) {
            monitorDevice(uuid: uuid)
        }

        NSUserNotificationCenter.default.delegate = self

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        if ble.unlockRSSI != ble.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && fetchPassword() == nil {
            askPassword()
        }
        checkAccessibility()
        checkUpdate()

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        NSApp.setActivationPolicy(.accessory)
        DiagnosticsLogger.shared.log("application_ready", fields: [
            "bundleVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "device": ble.monitoredUUID?.uuidString ?? "none",
            "lockRSSI": String(ble.lockRSSI),
            "unlockRSSI": String(ble.unlockRSSI),
            "signalTimeout": String(ble.signalTimeout),
            "proximityTimeout": String(ble.proximityTimeout),
        ])
    }

    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Restore the icon when the running app is reopened.
        resetHiddenMenuBarIconState()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Also restore the icon when the app becomes active again.
        resetHiddenMenuBarIconState()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
