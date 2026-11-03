import Observation
import ServiceManagement

@MainActor @Observable
final class LaunchAtLoginService {
    private(set) var status: SMAppService.Status
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    // Registered but awaiting approval remains checked so it can be unregistered.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var isEnabled: Bool { status == .enabled }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        errorMessage = nil
        guard enabled != isOn else { return }
        isUpdating = true
        defer { refresh(); isUpdating = false }
        do {
            if enabled { try register() }
            else { try await unregister() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
