import DataSources
import Foundation
import Mockable
import Testing

/// *Sign in with browser*: the vendor's own login, run into a new folder
/// ClaudeBar makes — never an existing one, and nothing left behind when it
/// does not finish.
@Suite
struct AccountSignInTests {
    private let folder = URL(fileURLWithPath: "/accounts/codex/new-login")

    private let call = SignInCall(
        cli: "codex", args: ["login"],
        environment: ProcessEnvironment(unset: ["OPENAI_API_KEY"], set: ["CODEX_HOME": "/accounts/codex/new-login"])
    )

    /// What the login was started with.
    private final class Launch: @unchecked Sendable {
        var executable: String?
        var arguments: [String]?
        var environment: [String: String]?
        var directory: URL?
        var timeout: TimeInterval?
    }

    private func recording(_ launch: Launch, exitStatus: Int32 = 0) -> MockSignInProcess {
        let process = MockSignInProcess()
        given(process).run(executable: .any, arguments: .any, environment: .any, directory: .any, timeout: .any)
            .willProduce { executable, arguments, environment, directory, timeout in
                launch.executable = executable
                launch.arguments = arguments
                launch.environment = environment
                launch.directory = directory
                launch.timeout = timeout
                return exitStatus
            }
        return process
    }

    private func signIn(
        _ process: MockSignInProcess,
        folders: InMemoryLoginFolders = InMemoryLoginFolders(),
        found: [String: String] = ["codex": "/usr/local/bin/codex"]
    ) -> AccountSignIn {
        AccountSignIn(
            process: process,
            folders: folders,
            locate: { found[$0] },
            environment: { ["PATH": "/usr/bin", "OPENAI_API_KEY": "sk-shared", "HOME": "/Users/me"] }
        )
    }

    @Test
    func `should run the vendor's login in a new folder with only its home variable added`() async throws {
        let launch = Launch()
        let folders = InMemoryLoginFolders()

        try await signIn(recording(launch), folders: folders).signIn(call, into: folder)

        #expect(launch.executable == "/usr/local/bin/codex")
        #expect(launch.arguments == ["login"])
        #expect(launch.environment == ["PATH": "/usr/bin", "HOME": "/Users/me", "CODEX_HOME": folder.path])
        #expect(launch.directory == folder)
        #expect(launch.timeout == 300)
        #expect(folders.all == [folder.path])
    }

    @Test
    func `should make no folder when the CLI is not installed`() async throws {
        let folders = InMemoryLoginFolders()

        await #expect(throws: SignInError.cliNotFound("codex")) {
            try await signIn(MockSignInProcess(), folders: folders, found: [:]).signIn(call, into: folder)
        }
        #expect(folders.all.isEmpty)
    }

    @Test
    func `should leave no folder when the login does not finish`() async throws {
        let folders = InMemoryLoginFolders()

        await #expect(throws: SignInError.didNotFinish) {
            try await signIn(recording(Launch(), exitStatus: 1), folders: folders).signIn(call, into: folder)
        }
        #expect(folders.all.isEmpty)
    }

    @Test
    func `should leave no folder when the login times out`() async throws {
        let folders = InMemoryLoginFolders()
        let process = MockSignInProcess()
        given(process).run(executable: .any, arguments: .any, environment: .any, directory: .any, timeout: .any)
            .willThrow(SignInError.timedOut)

        await #expect(throws: SignInError.timedOut) { try await signIn(process, folders: folders).signIn(call, into: folder) }

        #expect(folders.all.isEmpty)
    }

    @Test
    func `should never sign into a folder that already exists`() async throws {
        let folders = InMemoryLoginFolders([folder])

        await #expect(throws: SignInError.folderExists) {
            try await signIn(MockSignInProcess(), folders: folders).signIn(call, into: folder)
        }
        #expect(folders.all == [folder.path])
    }
}

/// The real disk behind `LoginFolders`: private, new, and gone when deleted.
@Suite
struct DiskLoginFoldersTests {
    @Test
    func `should make a login folder private, never over another, and gone once deleted`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("login-folders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("codex/login")
        let disk = DiskLoginFolders()

        try disk.create(folder)
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int

        #expect(permissions == 0o700)
        #expect(throws: SignInError.folderExists) { try disk.create(folder) }
        disk.delete(folder)
        #expect(!disk.exists(folder))
    }

    @Test(arguments: [
        (SignInError.cliNotFound("codex"), "`codex` wasn't found. Install it, or choose a folder you already signed in to."),
        (.folderExists, "That folder already exists, so ClaudeBar won't sign in there. Try again."),
        (.didNotFinish, "Sign-in didn't finish. Try again and complete it in your browser."),
        (.timedOut, "Sign-in timed out. Try again and complete it in your browser within five minutes."),
    ])
    func `should tell the person why the sign-in stopped and what to do next`(error: SignInError, message: String) {
        #expect(error.errorDescription == message)
    }
}
