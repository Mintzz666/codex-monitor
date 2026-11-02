import CryptoKit
import Foundation

/// A short-lived identity for validating a quota response against the
/// currently selected Codex home. The account ID is kept private and is never
/// encoded or included in this type's textual descriptions.
public struct CredentialIdentity: Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let accountID: String
  public let fingerprint: String

  private init(accountID: String, fingerprint: String) {
    self.accountID = accountID
    self.fingerprint = fingerprint
  }

  public var description: String {
    "CredentialIdentity(fingerprint: \(fingerprint))"
  }

  public var debugDescription: String { description }

  /// Returns a fingerprint only when the effective Codex home contains a
  /// ChatGPT auth record with a non-empty account ID.
  public static func currentFingerprint() -> String? {
    current()?.fingerprint
  }

  /// Computes the stable quota identity digest for an already canonicalized
  /// absolute Codex home and account ID. This is also useful for fixed-vector
  /// compatibility checks across clients.
  public static func fingerprint(
    canonicalCodexHome: String,
    accountID: String
  ) -> String {
    let payload = "codex-quota-v1\u{0}\(canonicalCodexHome)\u{0}\(accountID)"
    let digest = SHA256.hash(data: Data(payload.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> CredentialIdentity? {
    let homeURL: URL
    if let configuredHome = environment["CODEX_HOME"] {
      guard !configuredHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      let expandedHome = (configuredHome as NSString).expandingTildeInPath
      homeURL = URL(fileURLWithPath: expandedHome, isDirectory: true)
    } else {
      homeURL = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    }

    let canonicalHomeURL = homeURL.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory = ObjCBool(false)
    guard canonicalHomeURL.path.hasPrefix("/"),
      fileManager.fileExists(
        atPath: canonicalHomeURL.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      return nil
    }

    let authURL = canonicalHomeURL.appendingPathComponent(
      "auth.json",
      isDirectory: false
    )
    guard let data = try? Data(contentsOf: authURL),
      let object = try? JSONSerialization.jsonObject(with: data),
      let auth = object as? [String: Any],
      auth["auth_mode"] as? String == "chatgpt"
    else {
      return nil
    }

    let nestedAccountID = (auth["tokens"] as? [String: Any])?["account_id"] as? String
    let rootAccountID = auth["account_id"] as? String
    guard let accountID = [nestedAccountID, rootAccountID]
      .compactMap({ $0 })
      .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      .first(where: { !$0.isEmpty })
    else {
      return nil
    }

    let canonicalPath = canonicalHomeURL.path
    return CredentialIdentity(
      accountID: accountID,
      fingerprint: fingerprint(
        canonicalCodexHome: canonicalPath,
        accountID: accountID
      )
    )
  }

  func matchesQuotaAccountID(_ candidate: String) -> Bool {
    accountID == candidate
  }
}

public enum CredentialIdentityError: LocalizedError, Equatable {
  case accountChanged

  public var errorDescription: String? {
    "Codex 账号在读取期间发生变化，额度数据已丢弃并可重试"
  }
}
