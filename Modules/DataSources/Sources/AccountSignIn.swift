import Foundation
import Mockable

/// *Sign in with browser*: the vendor's own login command, run with the
/// environment that points it at a new folder of its own — what the
/// provider's `accounts.cli` says, filled with that folder.
public struct SignInCall: Sendable, Equatable {
    public let cli: String
    public let args: [String]
    /// Set to the folder, so the login lands there and nowhere else, and
    /// without the variables that would pick another way to sign in.
    public let environment: ProcessEnvironment
    /// Seconds to wait for the person to finish in the browser.
    public let timeout: TimeInterval

    public init(cli: String, args: [String], environment: ProcessEnvironment = ProcessEnvironment(), timeout: TimeInterval = 300) {
        self.cli = cli
        self.args = args
        self.environment = environment
        self.timeout = timeout
    }
}

/// Why a sign-in did not give a login.
public enum SignInError: Error, Equatable, LocalizedError {
    case cliNotFound(String)
    case folderExists
    case didNotFinish
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let cli):
            "`\(cli)` wasn't found. Install it, or choose a folder you already signed in to."
        case .folderExists:
            "That folder already exists, so ClaudeBar won't sign in there. Try again."
        case .didNotFinish:
            "Sign-in didn't finish. Try again and complete it in your browser."
        case .timedOut:
            "Sign-in timed out. Try again and complete it in your browser within five minutes."
        }
    }
}

/// Runs a login to the end: the process exits with a status, or is stopped
/// when the time is up (`SignInError.timedOut`) or the task is cancelled.
@Mockable
public protocol SignInProcess: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) async throws -> Int32
}

/// Signs in to a vendor's CLI into a NEW folder ClaudeBar makes (0700). The
/// folder is the whole result: whoever checks it next decides whether it holds
/// a login. Nothing is left behind when the login does not finish.
public struct AccountSignIn: Sendable {
    private let process: any SignInProcess
    private let folders: any LoginFolders
    private let locate: @Sendable (String) -> String?
    private let environment: @Sendable () -> [String: String]

    public init(
        process: any SignInProcess = FoundationSignInProcess(),
        folders: any LoginFolders = DiskLoginFolders(),
        locate: @escaping @Sendable (String) -> String? = { DataSources.locate($0) },
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.process = process
        self.folders = folders
        self.locate = locate
        self.environment = environment
    }

    public func signIn(_ call: SignInCall, into folder: URL) async throws {
        guard let executable = executable(for: call) else { throw SignInError.cliNotFound(call.cli) }
        guard !folders.exists(folder) else { throw SignInError.folderExists }
        try folders.create(folder)

        do {
            try await run(call, executable, in: folder)
        } catch {
            folders.delete(folder)
            throw error
        }
    }

    /// Signs in again in a folder this login already lives in — for a login
    /// whose session expired. The folder is kept whatever happens.
    public func signInAgain(_ call: SignInCall, in folder: URL) async throws {
        guard let executable = executable(for: call) else { throw SignInError.cliNotFound(call.cli) }
        guard folders.exists(folder) else { throw SignInError.didNotFinish }
        try await run(call, executable, in: folder)
    }

    /// The login, pointed at `folder` and nothing inherited that would pick
    /// another way in.
    private func run(_ call: SignInCall, _ executable: String, in folder: URL) async throws {
        var variables = environment()
        for name in call.environment.unset { variables.removeValue(forKey: name) }
        variables.merge(call.environment.set) { _, new in new }
        let status = try await process.run(executable: executable, arguments: call.args, environment: variables,
                                           directory: folder, timeout: call.timeout)
        guard status == 0 else { throw SignInError.didNotFinish }
    }

    /// The CLI the call names — a name on the PATH, or the path its
    /// provider's CLI location gave it.
    private func executable(for call: SignInCall) -> String? {
        locate(call.cli)
    }
}
