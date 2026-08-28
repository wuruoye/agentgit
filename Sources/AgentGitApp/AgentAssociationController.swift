import AgentGitCore
import AgentGitIntegrationShared
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentAssociationController {
    private let store: AgentAssociationStore?
    private let storeInitializationError: String?
    private let auditStore: AgentRegistrationAuditStore?
    private let auditStoreInitializationError: String?
    private let navigationResolver: AgentSessionNavigationResolver
    private var associationNotificationToken: NSObjectProtocol?
    private var auditNotificationToken: NSObjectProtocol?
    private var navigationRefreshTask: Task<Void, Never>?
    private var navigationAssociationIDsInFlight: Set<AgentAssociation.ID>?
    private var navigationGeneration = 0
    private var hasStarted = false
    private var isApplicationActive = true
    private var associationPersistenceError: String?
    private var auditPersistenceError: String?

    private(set) var associations: [AgentAssociation] = []
    private(set) var registrationEvents: [AgentRegistrationEvent] = []
    private(set) var navigationResolutions: [
        AgentAssociation.ID: AgentSessionNavigationResolution
    ] = [:]
    private(set) var errorMessage: String?
    private(set) var recoveryMessage: String?

    var persistenceErrorMessage: String? {
        let messages = [
            associationPersistenceError.map { "Associations: \($0)" },
            auditPersistenceError.map { "Registration history: \($0)" }
        ].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    var canRepairPersistence: Bool {
        (associationPersistenceError != nil && store != nil)
            || (auditPersistenceError != nil && auditStore != nil)
    }

    init(
        store: AgentAssociationStore? = nil,
        auditStore: AgentRegistrationAuditStore? = nil,
        navigationResolver: AgentSessionNavigationResolver = AgentSessionNavigationResolver()
    ) {
        if let store {
            self.store = store
            self.storeInitializationError = nil
        } else {
            do {
                self.store = AgentAssociationStore(
                    storeURL: try AgentAssociationStore.defaultStoreURL()
                )
                self.storeInitializationError = nil
            } catch {
                self.store = nil
                self.storeInitializationError = String(describing: error)
            }
        }
        if let auditStore {
            self.auditStore = auditStore
            self.auditStoreInitializationError = nil
        } else {
            do {
                self.auditStore = AgentRegistrationAuditStore(
                    storeURL: try AgentRegistrationAuditStore.defaultStoreURL()
                )
                self.auditStoreInitializationError = nil
            } catch {
                self.auditStore = nil
                self.auditStoreInitializationError = String(describing: error)
            }
        }
        self.navigationResolver = navigationResolver
        self.associationPersistenceError = storeInitializationError
        self.auditPersistenceError = auditStoreInitializationError
        self.errorMessage = storeInitializationError ?? auditStoreInitializationError
        self.recoveryMessage = nil
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        associationNotificationToken = DistributedNotificationCenter.default().addObserver(
            forName: AgentIntegrationContract.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.isApplicationActive == true else {
                    return
                }
                self?.refresh()
            }
        }
        auditNotificationToken = DistributedNotificationCenter.default().addObserver(
            forName: AgentIntegrationContract.registrationAuditChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.isApplicationActive == true else {
                    return
                }
                self?.refreshRegistrationEvents()
            }
        }
        if isApplicationActive {
            refresh(forceNavigationResolution: true)
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else {
            return
        }
        isApplicationActive = isActive
        if isActive {
            let wasStarted = hasStarted
            start()
            if wasStarted {
                refresh(forceNavigationResolution: true)
            }
        } else {
            navigationRefreshTask?.cancel()
            navigationRefreshTask = nil
            navigationAssociationIDsInFlight = nil
        }
    }

    func refresh(forceNavigationResolution: Bool = false) {
        guard let store else {
            associationPersistenceError = storeInitializationError
            refreshRegistrationEvents()
            errorMessage = storeInitializationError ?? auditStoreInitializationError
            return
        }
        do {
            let loadedAssociations = try store.list()
            if associations != loadedAssociations {
                associations = loadedAssociations
            }
            associationPersistenceError = nil
        } catch {
            associationPersistenceError = String(describing: error)
            refreshRegistrationEvents()
            errorMessage = persistenceErrorMessage
            return
        }
        refreshRegistrationEvents()
        if persistenceErrorMessage == nil {
            errorMessage = nil
        }
        refreshNavigationResolutions(force: forceNavigationResolution)
    }

    func associations(for worktree: GitWorktree) -> [AgentAssociation] {
        let path = worktree.rootURL.standardizedFileURL.path
        return associations.filter { $0.worktreePath == path }.sorted { lhs, rhs in
            let lhsRank = navigationAvailability(for: lhs).sortRank
            let rhsRank = navigationAvailability(for: rhs).sortRank
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    func latestRegistrationEvent(
        for provider: AgentProvider
    ) -> AgentRegistrationEvent? {
        registrationEvents.first { $0.provider == provider }
    }

    func navigationAvailability(
        for association: AgentAssociation
    ) -> AgentSessionNavigationAvailability {
        navigationResolutions[association.id]?.availability ?? .resolving
    }

    func open(_ association: AgentAssociation) {
        guard let resolution = navigationResolutions[association.id] else {
            resolveAndOpen(association)
            return
        }
        open(association, resolution: resolution)
    }

    func remove(_ association: AgentAssociation) {
        guard let store else {
            errorMessage = storeInitializationError
            return
        }
        do {
            associations = try store.remove(
                provider: association.provider,
                sessionID: association.sessionID
            )
            navigationResolutions[association.id] = nil
            associationPersistenceError = nil
            errorMessage = nil
        } catch {
            associationPersistenceError = String(describing: error)
            errorMessage = persistenceErrorMessage
        }
    }

    func repairPersistence() {
        var backups: [URL] = []
        do {
            if associationPersistenceError != nil,
               let backupURL = try store?.recoverCorruptFile() {
                backups.append(backupURL)
            }
            if auditPersistenceError != nil,
               let backupURL = try auditStore?.recoverCorruptFile() {
                backups.append(backupURL)
            }
            associationPersistenceError = nil
            auditPersistenceError = nil
            recoveryMessage = backups.isEmpty
                ? "Agent session storage is ready."
                : "Recovered agent session storage. Backups: "
                    + backups.map(\.path).joined(separator: ", ")
            refresh(forceNavigationResolution: true)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func refreshRegistrationEvents() {
        guard let auditStore else {
            auditPersistenceError = auditStoreInitializationError
            errorMessage = auditStoreInitializationError
            return
        }
        do {
            let loadedEvents = try auditStore.list()
            if registrationEvents != loadedEvents {
                registrationEvents = loadedEvents
            }
            auditPersistenceError = nil
            if associationPersistenceError == nil {
                errorMessage = nil
            }
        } catch {
            auditPersistenceError = String(describing: error)
            errorMessage = persistenceErrorMessage
        }
    }

    private func refreshNavigationResolutions(force: Bool) {
        let associationIDs = Set(associations.map(\.id))
        guard !associationIDs.isEmpty else {
            navigationRefreshTask?.cancel()
            navigationRefreshTask = nil
            navigationAssociationIDsInFlight = nil
            navigationGeneration &+= 1
            if !navigationResolutions.isEmpty {
                navigationResolutions = [:]
            }
            return
        }
        guard shouldRefreshAgentNavigationResolutions(
            currentIDs: Set(navigationResolutions.keys),
            associationIDs: associationIDs,
            inFlightIDs: navigationAssociationIDsInFlight,
            force: force
        ) else {
            return
        }
        navigationRefreshTask?.cancel()
        navigationGeneration += 1
        let generation = navigationGeneration
        let associations = associations
        let navigationResolver = navigationResolver
        navigationAssociationIDsInFlight = associationIDs
        let retainedResolutions = retainedAgentNavigationResolutions(
            current: navigationResolutions,
            associations: associations
        )
        if navigationResolutions != retainedResolutions {
            navigationResolutions = retainedResolutions
        }
        navigationRefreshTask = Task {
            let worker = Task.detached(priority: .utility) {
                navigationResolver.resolve(associations)
            }
            let resolutions = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  generation == navigationGeneration else {
                return
            }
            if navigationResolutions != resolutions {
                navigationResolutions = resolutions
            }
            navigationRefreshTask = nil
            navigationAssociationIDsInFlight = nil
        }
    }

    private func resolveAndOpen(_ association: AgentAssociation) {
        let navigationResolver = navigationResolver
        Task {
            let resolution = await Task.detached(priority: .userInitiated) {
                navigationResolver.resolve([association])[association.id]
            }.value
            guard associations.contains(where: { $0.id == association.id }),
                  let resolution else {
                return
            }
            navigationResolutions[association.id] = resolution
            open(association, resolution: resolution)
        }
    }

    private func open(
        _ association: AgentAssociation,
        resolution: AgentSessionNavigationResolution
    ) {
        guard let target = resolution.target else {
            errorMessage = resolution.errorDescription
                ?? "Unable to open \(association.provider.displayName) session."
            return
        }
        guard NSWorkspace.shared.open(target.url) else {
            errorMessage = "macOS did not accept the \(association.provider.displayName) session link."
            return
        }
        errorMessage = nil
    }
}

func retainedAgentNavigationResolutions(
    current: [AgentAssociation.ID: AgentSessionNavigationResolution],
    associations: [AgentAssociation]
) -> [AgentAssociation.ID: AgentSessionNavigationResolution] {
    let retainedIDs = Set(associations.map(\.id))
    return current.filter { retainedIDs.contains($0.key) }
}

func shouldRefreshAgentNavigationResolutions(
    currentIDs: Set<AgentAssociation.ID>,
    associationIDs: Set<AgentAssociation.ID>,
    inFlightIDs: Set<AgentAssociation.ID>?,
    force: Bool
) -> Bool {
    if force {
        return true
    }
    return currentIDs != associationIDs
        && inFlightIDs != associationIDs
}
