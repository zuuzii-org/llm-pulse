import AppKit
import Sparkle

@MainActor
final class AppCoordinator {
    private let monitor: TaskMonitor
    private let settings: PulseSettings
    private let launchAtLogin: LaunchAtLoginService
    private let modelSelection: ModelSelectionStore
    private let panelVisibilityState: TaskPanelVisibilityState
    private let updaterIsStarted: Bool
    private let updaterController: SPUStandardUpdaterController
    private var notificationService: NotificationService!
    private var taskOpeningService: TaskOpeningService!

    private var panelController: TaskPanelController!
    private var statusItemController: StatusItemController!
    private var edgeTriggerService: EdgeTriggerService!
    private var notificationObserver: TaskNotificationObserver!
    private var settingsWindowController: SettingsWindowController!

    init(
        monitor: TaskMonitor,
        settings: PulseSettings,
        launchAtLogin: LaunchAtLoginService
    ) {
        self.monitor = monitor
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        modelSelection = ModelSelectionStore()
        panelVisibilityState = TaskPanelVisibilityState()
        updaterIsStarted = !Self.isRunningTests
        updaterController = SPUStandardUpdaterController(
            // XCTest hosts must not schedule background checks or display
            // Sparkle UI. Production starts immediately and preserves
            // Sparkle's normal first/second-launch automatic-check flow.
            startingUpdater: updaterIsStarted,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let navigator = TaskNavigator()

        let sidebar = TaskSidebarView(
            monitor: monitor,
            settings: settings,
            modelSelection: modelSelection,
            panelVisibilityState: panelVisibilityState,
            onOpenTask: { [weak self] task in self?.openTask(task) ?? false },
            onDismiss: { [weak self] in self?.panelController.hide() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        panelController = TaskPanelController(
            width: settings.panelWidth,
            dismissDelay: settings.panelDismissDelay,
            statusItemDisplayDuration: settings.statusItemPanelDisplayDuration,
            rootView: sidebar,
            visibilityState: panelVisibilityState,
            settings: settings
        )
        panelController.onSelectAdjacentModel = { [weak self] direction in
            _ = self?.modelSelection.selectAdjacent(direction)
        }
        panelController.isModelSelectionEnabled = { [weak self] in
            guard let self else { return false }
            return !self.modelSelection.isSelectionLocked
                && self.monitor.hubSnapshot.models.count > 1
        }

        taskOpeningService = TaskOpeningService(
            navigator: navigator,
            markViewed: { [weak monitor] task in monitor?.markViewed(task: task) },
            dismiss: { [weak self] in self?.panelController.hide() }
        )
        notificationService = NotificationService(
            settings: settings,
            onOpenTask: { [weak self] route in
                self?.openNotification(route)
            },
            onMarkViewed: { [weak self] route in
                await self?.markNotificationViewed(route)
            },
            onOpenPanel: { [weak self] in
                self?.showPanel()
            }
        )
        settingsWindowController = SettingsWindowController(
            settings: settings,
            launchAtLogin: launchAtLogin,
            requestNotificationAuthorization: { [weak self] in
                await self?.requestNotificationAuthorization()
            }
        )

        statusItemController = StatusItemController(
            monitor: monitor,
            settings: settings,
            modelSelectionStore: modelSelection
        )
        statusItemController.onTogglePanel = { [weak self] in self?.togglePanel() }
        statusItemController.onOpenAttentionTask = { [weak self] in self?.openAttentionTask() }
        statusItemController.onSelectProfile = { [weak self] profileID in
            guard let self, self.modelSelection.select(profileID) else { return }
            self.showPanel()
        }
        statusItemController.onRefresh = { [weak monitor] in monitor?.refresh() }
        statusItemController.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItemController.onCheckForUpdates = { [weak self] in
            guard self?.updaterIsStarted == true else { return }
            self?.updaterController.checkForUpdates(nil)
        }
        statusItemController.onQuit = { NSApp.terminate(nil) }
        panelController.setOutsideDismissExcludedView(statusItemController.button)

        edgeTriggerService = EdgeTriggerService(settings: settings)
        edgeTriggerService.isPanelVisible = { [weak self] in
            self?.panelController.isVisible ?? false
        }
        edgeTriggerService.onTrigger = { [weak self] screen in
            self?.panelController.show(on: screen, source: .edgeHover)
        }
        edgeTriggerService.onPointerMove = { [weak self] location in
            self?.panelController.handlePointerMove(to: location)
        }

        notificationObserver = TaskNotificationObserver(
            monitor: monitor,
            notificationService: notificationService
        )
    }

    func start() {
        monitor.start()
        notificationObserver.start()

#if DEBUG
        let isPanelUITest = ProcessInfo.processInfo.arguments.contains("--show-panel-for-ui-test")
        if isPanelUITest {
            panelController.preventsAutomaticDismiss = true
            if let screen = NSScreen.main {
                panelController.show(on: screen, source: .programmatic)
            }
        } else {
            edgeTriggerService.start()
        }
#else
        edgeTriggerService.start()
#endif

        Task {
            await notificationService.requestAuthorizationIfNeeded()
        }
    }

    func stop() {
        edgeTriggerService.stop()
        notificationObserver.stop()
        panelController.hide()
        monitor.stop()
    }

    func requestNotificationAuthorization() async {
        await notificationService.requestAuthorizationIfNeeded()
    }

    private func togglePanel() {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.containing(location) ?? NSScreen.main
        guard let screen else { return }
        panelController.toggleFromStatusItem(on: screen)
    }

    private func showPanel() {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.containing(location) ?? NSScreen.main
        guard let screen else { return }
        panelController.show(on: screen, source: .programmatic)
    }

    private func openTask(_ task: PulseTask) -> Bool {
        taskOpeningService.open(task: task)
    }

    private func openAttentionTask() {
        let task = AttentionTaskSelector.next(
            in: monitor.hubSnapshot.models.flatMap(\.tasks)
        )
        guard let task else {
            showPanel()
            return
        }

        guard modelSelection.select(task.profileID, origin: .automatic) else {
            showPanel()
            return
        }

        if !openTask(task) {
            showPanel()
        }
    }

    private func openNotification(_ route: TaskNotificationRoute) {
        guard modelSelection.select(route.profileID, origin: .automatic) else {
            showPanel()
            return
        }
        let tasks = monitor.hubSnapshot.models.flatMap(\.tasks)
        if !taskOpeningService.open(route: route, currentTasks: tasks) {
            showPanel()
        }
    }

    private func markNotificationViewed(_ route: TaskNotificationRoute) async {
        if let task = monitor.hubSnapshot.models
            .flatMap(\.tasks)
            .first(where: route.matches) {
            _ = await monitor.markViewedAndRefresh(tasks: [task])
            return
        }

        guard route.allowsCodexFallback else {
            showPanel()
            return
        }

        let identityPrefix = route.threadID + ":"
        let suffix = route.taskID.hasPrefix(identityPrefix)
            ? String(route.taskID.dropFirst(identityPrefix.count))
            : "thread"
        let task = PulseTask(
            threadId: route.threadID,
            turnId: suffix == "thread" ? nil : suffix,
            title: PulseL10n.text(
                "通知中的已完成任务",
                language: settings.appLanguage
            ),
            projectDirectory: "",
            state: .completed,
            startedAt: .now,
            updatedAt: .now,
            completedAt: .now,
            lastStatus: "completed",
            isUnread: true
        )
        guard task.id == route.taskID else {
            showPanel()
            return
        }
        _ = await monitor.markViewedAndRefresh(tasks: [task])
    }

    private func openSettings() {
        panelController.hide()
        launchAtLogin.refresh()
        settingsWindowController.present()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
