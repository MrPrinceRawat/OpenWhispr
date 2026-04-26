import AppKit
import SwiftUI
import Combine
import AVFoundation
class AppDelegate: NSObject, NSApplicationDelegate {
    private var pillWindow: PillWindow!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let history = HistoryStore()
    private let textProcessor = TextProcessor()
    private let dictionary = DictionaryStore.shared
    private let vad = VoiceActivityDetector()
    private var editMonitorTimer: Timer?
    private var lastPastedText: String?
    private var monitoredElement: AXUIElement?
    private var fnMonitor: Any?
    private var localFnMonitor: Any?
    private var hotkeyEventTap: CFMachPort?
    private var hotkeyMonitor: Any?
    private var accessibilityTimer: Timer?
    private var fnEventTap: CFMachPort?
    private enum RecordingPhase {
        case idle
        case recording          // Fn held down
        case pendingLock        // Fn released, waiting for quick re-press
        case recordingLocked    // Recording hands-free
        case recordingSummarize         // Ctrl+Fn held down (summarize mode)
        case pendingLockSummarize       // Summarize Fn released, waiting for re-press
        case recordingLockedSummarize   // Summarize recording hands-free
        case recordingQuestion          // Cmd+Fn held down (Q&A mode)
    }
    private var isSummarizeMode: Bool {
        switch recordingPhase {
        case .recordingSummarize, .pendingLockSummarize, .recordingLockedSummarize: return true
        default: return false
        }
    }
    private var recordingPhase: RecordingPhase = .idle
    private var currentRecordingSummarize: Bool = false
    private var currentRecordingQuestion: Bool = false
    private var pendingLockTimer: Timer?
    private var lastAltPressTime: Date?
    private var lastCtrlPressTime: Date?
    private var debounceTimer: Timer?
    private var cancelledProcessing: Bool = false
    private var recordingStartTime: Date?
    private var levelCancellable: AnyCancellable?
    private var modelCancellable: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var unifiedWindow: UnifiedWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Request mic permission upfront so first recording isn't delayed
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("[Mic] Microphone permission denied")
            }
        }

        // Prompt for Accessibility permission if not granted
        requestAccessibilityIfNeeded()

        pillWindow = PillWindow()
        pillWindow.show()

        // Menubar status item
        setupStatusItem()

        // Unified window controller
        unifiedWindow = UnifiedWindowController(historyStore: history)

        // Auto-download model
        modelCancellable = transcriber.$modelState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .checking:
                    break
                case .notDownloaded, .downloading:
                    if case .downloading(let p) = state {
                        self.pillWindow.setState(.downloading(progress: p))
                    }
                case .ready:
                    self.pillWindow.setState(.idle)
                case .error(let msg):
                    print("Model error: \(msg)")
                    self.pillWindow.setState(.idle)
                }
            }

        transcriber.checkAndDownload()
        // LLM always loads — formatting is always on
        textProcessor.setup()

        // Show onboarding on first launch within unified window
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            unifiedWindow?.show(onboarding: true) { [weak self] in
                self?.unifiedWindow?.showNormal()
            }
        }

        // Pipe audio levels to pill
        levelCancellable = recorder.levelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.pillWindow.pushLevel(level)
            }

        // Monitor Fn key — use CGEvent tap to intercept and suppress emoji picker
        setupFnEventTap()
        // Fallback NSEvent monitors if CGEvent tap isn't available yet
        fnMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
        localFnMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }

        // Ctrl+Cmd+V — paste last transcription
        // CGEvent tap requires Accessibility. Retry periodically until granted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.attemptHotkeySetup()
        }

        // Right-click pill for menu
        pillWindow.onRightClick = { [weak self] in
            self?.showContextMenu()
        }

        // Click idle pill to start locked recording
        pillWindow.onIdleClick = { [weak self] in
            guard let self, self.transcriber.isModelReady, self.recordingPhase == .idle else { return }
            self.startRecording()
            self.recordingPhase = .recordingLocked
            self.pillWindow.setState(.recordingLocked)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            unifiedWindow?.toggle()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            unifiedWindow?.toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "OpenWhispr", action: #selector(openApp), keyEquivalent: ""))

        if !AXIsProcessTrusted() {
            let axItem = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
            axItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(axItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenWhispr", action: #selector(quit), keyEquivalent: ""))

        for item in menu.items {
            item.target = self
        }

        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: location.x, y: location.y), in: nil)
    }

    private func setupFnEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                let flags = event.flags
                let fnPressed = flags.contains(.maskSecondaryFn)

                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()

                // Check modifier state
                let hasControl = flags.contains(.maskControl)
                let hasCommand = flags.contains(.maskCommand)
                let hasAlt = flags.contains(.maskAlternate)

                // Only intercept Fn if model is ready
                guard delegate.transcriber.isModelReady else {
                    return Unmanaged.passUnretained(event)
                }

                // Track modifier press times — Fn/Globe key causes macOS to release other modifiers
                if hasControl { delegate.lastCtrlPressTime = Date() }
                if hasAlt { delegate.lastAltPressTime = Date() }

                // Allow Cmd combos to pass through
                if hasCommand && !fnPressed && !delegate.isRecording {
                    return Unmanaged.passUnretained(event)
                }

                // Only intercept when Fn is involved — don't eat plain modifier events
                if !fnPressed && !delegate.isRecording {
                    return Unmanaged.passUnretained(event)
                }

                // Check if modifier was held recently (within 500ms) — survives Globe key release
                let now = Date()
                let summarize = hasControl || (delegate.lastCtrlPressTime.map { now.timeIntervalSince($0) < 0.5 } ?? false)
                let question = hasAlt || (delegate.lastAltPressTime.map { now.timeIntervalSince($0) < 0.5 } ?? false)

                print("[EventTap] fn=\(fnPressed) ctrl=\(summarize) alt=\(question) phase=\(delegate.recordingPhase)")

                if question {
                    DispatchQueue.main.async { delegate.handleFn(pressed: fnPressed, question: true) }
                } else if summarize {
                    DispatchQueue.main.async { delegate.handleFn(pressed: fnPressed, summarize: true) }
                } else {
                    DispatchQueue.main.async { delegate.handleFn(pressed: fnPressed) }
                }

                // Suppress Fn event to prevent emoji picker
                return nil
            },
            userInfo: refcon
        ) else {
            print("[Fn] CGEvent tap for Fn failed — emoji picker suppression unavailable")
            return
        }

        fnEventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[Fn] CGEvent tap installed — emoji picker suppressed")
    }

    private func handleFlags(_ event: NSEvent) {
        // Fallback for when CGEvent tap isn't available
        guard fnEventTap == nil else { return }
        let fnPressed = event.modifierFlags.contains(.function)
        let hasControl = event.modifierFlags.contains(.control)
        let hasOption = event.modifierFlags.contains(.option)
        if hasOption {
            handleFn(pressed: fnPressed, question: true)
        } else {
            handleFn(pressed: fnPressed, summarize: hasControl)
        }
    }

    private func handleFn(pressed: Bool, summarize: Bool = false, question: Bool = false) {
        guard transcriber.isModelReady else { return }

        switch recordingPhase {
        case .idle:
            if pressed {
                if question {
                    startRecording(question: true)
                    recordingPhase = .recordingQuestion
                } else {
                    startRecording(summarize: summarize)
                    recordingPhase = summarize ? .recordingSummarize : .recording
                }
            }

        case .recording:
            if pressed {
                // Fn re-pressed during debounce — treat as double-tap lock
                if debounceTimer != nil {
                    debounceTimer?.invalidate()
                    debounceTimer = nil
                    recordingPhase = .recordingLocked
                    pillWindow.setState(.recordingLocked)
                }
            } else {
                // Pill shows processing immediately — feels responsive
                pillWindow.setState(.processing)
                // Recorder silently keeps running for debounce + lock window
                debounceTimer?.invalidate()
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                    guard let self, self.recordingPhase == .recording else { return }
                    self.debounceTimer = nil
                    self.recordingPhase = .pendingLock
                    self.pendingLockTimer?.invalidate()
                    self.pendingLockTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                        guard let self, self.recordingPhase == .pendingLock else { return }
                        self.recordingPhase = .idle
                        self.stopRecording()
                    }
                }
            }

        case .pendingLock:
            if pressed {
                pendingLockTimer?.invalidate()
                pendingLockTimer = nil
                recordingPhase = .recordingLocked
                pillWindow.setState(.recordingLocked)
            }

        case .recordingLocked:
            if pressed {
                // Pill shows processing immediately
                pillWindow.setState(.processing)
                // Silently capture trailing speech for 100ms
                debounceTimer?.invalidate()
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                    guard let self, self.recordingPhase == .recordingLocked else { return }
                    self.debounceTimer = nil
                    self.recordingPhase = .idle
                    self.stopRecording()
                }
            }

        // Summarize mode — mirrors normal recording
        case .recordingSummarize:
            if pressed {
                if debounceTimer != nil {
                    debounceTimer?.invalidate()
                    debounceTimer = nil
                    recordingPhase = .recordingLockedSummarize
                    pillWindow.setState(.recordingLockedSummarize)
                }
            } else {
                pillWindow.setState(.processing)
                debounceTimer?.invalidate()
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                    guard let self, self.recordingPhase == .recordingSummarize else { return }
                    self.debounceTimer = nil
                    self.recordingPhase = .pendingLockSummarize
                    self.pendingLockTimer?.invalidate()
                    self.pendingLockTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                        guard let self, self.recordingPhase == .pendingLockSummarize else { return }
                        self.recordingPhase = .idle
                        self.stopRecording()
                    }
                }
            }

        case .pendingLockSummarize:
            if pressed {
                pendingLockTimer?.invalidate()
                pendingLockTimer = nil
                recordingPhase = .recordingLockedSummarize
                pillWindow.setState(.recordingLockedSummarize)
            }

        case .recordingLockedSummarize:
            if pressed {
                pillWindow.setState(.processing)
                debounceTimer?.invalidate()
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                    guard let self, self.recordingPhase == .recordingLockedSummarize else { return }
                    self.debounceTimer = nil
                    self.recordingPhase = .idle
                    self.stopRecording()
                }
            }

        case .recordingQuestion:
            if !pressed {
                // Simple hold-and-release — no double-tap lock for Q&A
                pillWindow.setState(.processing)
                debounceTimer?.invalidate()
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                    guard let self, self.recordingPhase == .recordingQuestion else { return }
                    self.debounceTimer = nil
                    self.recordingPhase = .idle
                    self.stopRecording()
                }
            }
        }
    }

    private func startRecording(summarize: Bool = false, question: Bool = false) {
        recordingStartTime = Date()
        currentRecordingSummarize = summarize
        currentRecordingQuestion = question
        recorder.start()
        if question {
            pillWindow.setState(.recordingQuestion)
        } else {
            pillWindow.setState(summarize ? .recordingSummarize : .recording)
        }
    }

    private var isRecording: Bool {
        switch recordingPhase {
        case .idle: return false
        default: return true
        }
    }

    private var isActive: Bool {
        isRecording || pillWindow.currentState == .processing || pillWindow.currentState == .polishing
    }

    private func scheduleAnswerDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self else { return }
            guard case .answer = self.pillWindow.currentState else { return }
            if self.pillWindow.isHovered {
                // Still hovered — check again later
                self.scheduleAnswerDismiss()
            } else {
                self.pillWindow.setState(.idle)
            }
        }
    }

    private func cancelRecording() {
        print("[Cancel] Escape pressed — cancelling (phase=\(recordingPhase))")
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingLockTimer?.invalidate()
        pendingLockTimer = nil
        cancelledProcessing = true

        if isRecording {
            recorder.stop { _ in } // discard audio
        }
        recordingPhase = .idle
        pillWindow.setState(.idle)
    }

    private func stopRecording() {
        let summarize = currentRecordingSummarize
        let question = currentRecordingQuestion
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        // Whisper needs at least ~0.5s of audio to produce results
        if duration < 0.3 {
            recorder.stop { _ in }
            pillWindow.setState(.idle)
            return
        }

        pillWindow.setState(.processing)
        cancelledProcessing = false

        // Capture frontmost app on main thread before async work
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        recorder.stop { [weak self] audioURL in
            guard let self, let url = audioURL else {
                self?.pillWindow.setState(.idle)
                return
            }
            Task {
                // Check cancellation before each expensive step
                guard !self.cancelledProcessing else { return }
                // Run VAD to strip silence before transcription
                let transcribeURL: URL
                let vadOutput = self.vad.process(inputURL: url)
                if let vadURL = vadOutput {
                    transcribeURL = vadURL
                    try? FileManager.default.removeItem(at: url)
                } else {
                    transcribeURL = url
                }

                var text = await self.transcriber.transcribe(fileURL: transcribeURL)
                try? FileManager.default.removeItem(at: transcribeURL)

                guard !self.cancelledProcessing else { return }

                // Q&A mode — send question to LLM, show answer in pill
                if question, let questionText = text, !questionText.isEmpty, self.textProcessor.isReady {
                    await MainActor.run { self.pillWindow.setState(.polishing) }
                    let answer = await self.textProcessor.answerQuestion(questionText)
                    await MainActor.run {
                        if !answer.isEmpty {
                            self.pillWindow.setState(.answer(answer))
                            // Auto-dismiss after a few seconds (pause while hovered)
                            self.scheduleAnswerDismiss()
                        } else {
                            self.pillWindow.setState(.idle)
                        }
                    }
                    return
                }

                // Build processing context
                let tone = ToneManager.shared.tone(forBundleID: frontmostBundleID)
                print("[Pipeline] bundleID=\(frontmostBundleID ?? "nil") tone=\(tone) processorReady=\(self.textProcessor.isReady)")
                let context = TextProcessor.ProcessingContext(
                    tone: tone,
                    polishingEnabled: UserDefaults.standard.bool(forKey: "polishingEnabled"),
                    alwaysEnglish: UserDefaults.standard.bool(forKey: "alwaysEnglish"),
                    userStyleDescription: UserDefaults.standard.string(forKey: "userStyleDescription") ?? "",
                    summarize: summarize
                )

                // Process through LLM, then apply dictionary as final pass
                if let raw = text, !raw.isEmpty {
                    var processed = raw
                    if self.textProcessor.isReady && tone != "raw" {
                        await MainActor.run { self.pillWindow.setState(.polishing) }
                        processed = await self.textProcessor.process(processed, context: context)
                    }
                    // Dictionary corrections after LLM so they stick in the final output
                    processed = self.dictionary.apply(to: processed)
                    text = processed
                }

                let finalResult = text
                await MainActor.run {
                    if let finalText = finalResult, !finalText.isEmpty {
                        self.history.add(text: finalText, durationSeconds: duration)
                        let pasted = self.pasteText(finalText)
                        if pasted {
                            self.pillWindow.setState(.idle)
                            self.startEditMonitoring(pastedText: finalText)
                        }
                        // If paste failed, pasteText already showed the error pill
                    } else {
                        self.pillWindow.setState(.idle)
                    }
                }
            }
        }
    }

    private func attemptHotkeySetup() {
        let trusted = AXIsProcessTrusted()
        print("[Hotkey] Accessibility trusted: \(trusted)")

        if trusted {
            // Stop retrying
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil

            if setupHotkeyTap() {
                return
            }
            // CGEvent tap failed even with Accessibility — use NSEvent monitor
            print("[Hotkey] CGEvent tap failed despite Accessibility, using NSEvent monitor")
            setupHotkeyMonitor()
        } else {
            // Not trusted yet — install NSEvent monitor as temporary fallback
            // and start polling for Accessibility to be granted
            if hotkeyMonitor == nil && hotkeyEventTap == nil {
                setupHotkeyMonitor()
            }
            if accessibilityTimer == nil {
                accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if AXIsProcessTrusted() {
                        print("[Hotkey] Accessibility now granted, upgrading to CGEvent tap")
                        // Remove NSEvent monitor
                        if let monitor = self.hotkeyMonitor {
                            NSEvent.removeMonitor(monitor)
                            self.hotkeyMonitor = nil
                        }
                        self.attemptHotkeySetup()

                        // Also retry Fn tap if it failed earlier
                        if self.fnEventTap == nil {
                            print("[Fn] Retrying Fn CGEvent tap now that Accessibility is granted")
                            self.setupFnEventTap()
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func setupHotkeyTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()

                // Escape cancels active recording/processing
                if keyCode == 53 && delegate.isActive {
                    DispatchQueue.main.async { delegate.cancelRecording() }
                    return nil
                }

                // Ctrl+Cmd+V — paste last transcription
                if keyCode == 0x09 && flags.contains(.maskCommand) && flags.contains(.maskControl) {
                    DispatchQueue.main.async { delegate.pasteLastTranscription() }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            print("[Hotkey] CGEvent tap creation failed")
            return false
        }

        hotkeyEventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[Hotkey] CGEvent tap installed for Ctrl+Cmd+V")
        return true
    }

    private func setupHotkeyMonitor() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 0x09 && flags.contains(.control) && flags.contains(.command) {
                print("[Hotkey] Ctrl+Cmd+V via NSEvent monitor")
                self?.pasteLastTranscription()
            }
        }
        print("[Hotkey] NSEvent global monitor installed for Ctrl+Cmd+V")
    }

    private func pasteLastTranscription() {
        guard let lastEntry = history.entries.first else {
            pillWindow.setState(.error("No transcriptions yet"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.pillWindow.setState(.idle)
            }
            return
        }
        pasteText(lastEntry.text)
    }

    private func requestAccessibilityIfNeeded() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            print("Accessibility permission not granted — auto-paste and Ctrl+Cmd+V won't work until granted.")
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns true if auto-paste succeeded, false if text was only copied to clipboard.
    @discardableResult
    private func pasteText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Check if we can auto-paste
        let trusted = AXIsProcessTrusted()
        let hasFocus = trusted && frontmostAppHasTextFocus()

        guard trusted && hasFocus else {
            // Can't auto-paste — text is on clipboard, tell the user
            pillWindow.setState(.error("Copied — press Cmd+V to paste"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.pillWindow.setState(.idle)
            }
            return false
        }

        // Auto-paste via simulated Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

            guard let keyDown, let keyUp else { return }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)

            // Restore clipboard after paste completes
            if let previous = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
        return true
    }

    /// Check if the frontmost app has a focused element that accepts text input
    private func frontmostAppHasTextFocus() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focused = focusedRef else { return false }

        let element = focused as! AXUIElement

        // Check the role of the focused element
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String {
            let textRoles: Set<String> = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                "AXSearchField",
                kAXComboBoxRole as String,
                "AXWebArea",        // Web content (browsers, Electron apps)
            ]
            if textRoles.contains(role) { return true }
        }

        // Fallback: check if the element has a value attribute that's a string (editable text)
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        if valueResult == .success, valueRef is String {
            // Also check it's not read-only by seeing if AXInsertionPointLineNumber exists
            var insertionRef: CFTypeRef?
            let insertionResult = AXUIElementCopyAttributeValue(element, "AXInsertionPointLineNumber" as CFString, &insertionRef)
            if insertionResult == .success { return true }
        }

        return false
    }

    // MARK: - Edit Monitoring (Custom Dictionary Learning)

    private func startEditMonitoring(pastedText: String) {
        stopEditMonitoring()

        guard AXIsProcessTrusted(),
              let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focused = focusedRef else { return }

        monitoredElement = (focused as! AXUIElement)
        lastPastedText = pastedText

        // Poll the text field every 1s for 10s to detect edits
        var tickCount = 0
        editMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            tickCount += 1

            if tickCount > 10 {
                self.finalizeEditMonitoring()
                return
            }

            // Stop if user started a new recording
            if self.isRecording {
                self.stopEditMonitoring()
                return
            }
        }
    }

    private func finalizeEditMonitoring() {
        guard let element = monitoredElement, let originalText = lastPastedText else {
            stopEditMonitoring()
            return
        }

        // Read current text field value
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)

        stopEditMonitoring()

        guard result == .success, let currentValue = valueRef as? String else { return }

        // The field may contain more text than what we pasted.
        // Try to find our pasted text region and see what it became.
        learnCorrections(original: originalText, current: currentValue)
    }

    private func stopEditMonitoring() {
        editMonitorTimer?.invalidate()
        editMonitorTimer = nil
        monitoredElement = nil
        lastPastedText = nil
    }

    private func learnCorrections(original: String, current: String) {
        // Tokenize both into words
        let originalWords = original.split(separator: " ").map(String.init)
        let currentWords = current.split(separator: " ").map(String.init)

        // If the field has way more text than we pasted, try to find our region
        // by looking for a subsequence match
        let matchWords: [String]
        if currentWords.count > originalWords.count + 5 {
            matchWords = findBestMatch(original: originalWords, in: currentWords)
        } else {
            matchWords = currentWords
        }

        guard matchWords.count == originalWords.count else { return }

        // Compare word by word
        var learned: [(String, String)] = []
        for (orig, curr) in zip(originalWords, matchWords) {
            let origClean = orig.trimmingCharacters(in: .punctuationCharacters)
            let currClean = curr.trimmingCharacters(in: .punctuationCharacters)

            if origClean.lowercased() != currClean.lowercased() && !currClean.isEmpty {
                dictionary.add(original: origClean, corrected: currClean)
                learned.append((origClean, currClean))
            }
        }

        if !learned.isEmpty {
            let summary = learned.map { "\($0.0) → \($0.1)" }.joined(separator: ", ")
            pillWindow.setState(.learned("Learned: \(summary)"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.pillWindow.setState(.idle)
            }
        }
    }

    /// Find the best matching subsequence of `original` words within `field` words
    private func findBestMatch(original: [String], in field: [String]) -> [String] {
        guard original.count <= field.count else { return [] }

        var bestStart = 0
        var bestScore = 0

        for start in 0...(field.count - original.count) {
            var score = 0
            for i in 0..<original.count {
                if original[i].lowercased() == field[start + i].lowercased() {
                    score += 1
                }
            }
            if score > bestScore {
                bestScore = score
                bestStart = start
            }
        }

        // Need at least 50% match to consider it a valid alignment
        guard bestScore >= original.count / 2 else { return [] }

        return Array(field[bestStart..<(bestStart + original.count)])
    }

    @objc private func openApp() {
        unifiedWindow?.show()
    }

    @objc private func grantAccessibility() {
        openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

}
