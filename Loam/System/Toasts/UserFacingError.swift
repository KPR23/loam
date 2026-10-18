import Foundation
import AuthenticationServices
import Supabase

/// Turns any error into one short sentence a person can act on. Raw backend
/// text, status codes and response bodies never reach the screen.
enum UserFacingError {
    static let fallback = "Something went wrong. Try again."

    /// Nil when nothing should be shown, such as a cancelled request or sign-in.
    static func message(for error: Error) -> String? {
        if isCancellation(error) { return nil }
        if let error = error as? URLError { return message(for: error) }
        if let error = error as? PostgrestError { return message(postgrestCode: error.code, text: error.message) }
        if let error = error as? HTTPError { return message(status: error.response.statusCode) }
        if let error = error as? AuthError { return message(for: error) }
        if let error = error as? FunctionsError {
            if case let .httpError(code, _) = error { return message(status: code) }
            return unreachable
        }
        if error is DecodingError || error is EncodingError { return unexpectedResponse }
        if let error = error as? ASAuthorizationError {
            return error.code == .canceled ? nil : "Sign in with Apple didn't finish. Try again."
        }
        if let error = error as? LocalizedError, let description = error.errorDescription, !description.isEmpty {
            // Loam's own errors are written for people; known backend wording is reworded.
            return serverMessages[normalized(description)] ?? description
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return message(for: URLError(URLError.Code(rawValue: nsError.code))) }
        // Loam's own NSErrors carry sentences written for people.
        if nsError.domain.hasPrefix("Loam"), let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String {
            return description
        }
        return fallback
    }

    /// The sentence for a message that is already text, such as one a server sent.
    static func message(forServerText text: String) -> String {
        serverMessages[normalized(text)] ?? fallback
    }

    // MARK: - Network

    static let offline = "You're offline. Check your connection and try again."
    static let unreachable = "Couldn't reach Loam. Try again in a moment."
    static let unexpectedResponse = "Loam got an unexpected response. Try again."
    static let sessionExpired = "Your session expired. Sign in again."

    private static func message(for error: URLError) -> String? {
        switch error.code {
        case .cancelled: return nil
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return offline
        case .timedOut: return "Loam took too long to respond. Try again."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return unreachable
        case .userAuthenticationRequired: return sessionExpired
        case .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse, .badServerResponse:
            return unexpectedResponse
        default: return unreachable
        }
    }

    static func message(status: Int) -> String {
        switch status {
        case 401: return sessionExpired
        case 403: return "You don't have access to that."
        case 404: return "That's no longer available."
        case 409: return "This changed somewhere else. Refresh and try again."
        case 429: return "Too many attempts. Wait a moment and try again."
        case 500...599: return "Loam is having trouble right now. Try again shortly."
        default: return fallback
        }
    }

    private static func message(for error: AuthError) -> String {
        switch error.errorCode {
        case .sessionNotFound, .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed, .badJWT, .invalidJWT:
            return sessionExpired
        case .overRequestRateLimit, .overEmailSendRateLimit, .overSMSSendRateLimit:
            return "Too many attempts. Wait a moment and try again."
        case .userBanned: return "This account can't sign in."
        default: return "Couldn't sign you in. Try again."
        }
    }

    // MARK: - Database

    static func message(postgrestCode code: String?, text: String) -> String {
        if let known = serverMessages[normalized(text)] { return known }
        switch code {
        // A function raised a reason of its own; anything not reworded above stays generic.
        case "P0001": return fallback
        case "42501": return "You don't have permission to do that."
        case "23505": return "That already exists."
        case "23503": return "Something this needs was removed. Refresh and try again."
        case "23514", "22P02", "22023", "23502": return "Some details aren't valid. Check them and try again."
        case "PGRST301", "PGRST302": return sessionExpired
        case "PGRST116": return "That's no longer available."
        case "57014": return "Loam took too long to respond. Try again."
        case let code? where code.hasPrefix("08") || code.hasPrefix("53"):
            return "Loam is having trouble right now. Try again shortly."
        default: return fallback
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            .lowercased()
    }

    /// Reasons the backend raises, keyed by their lowercased text without the final period.
    private static let serverMessages: [String: String] = {
        let pairs: [(String, String)] = [
            ("Not authenticated", sessionExpired),
            ("Account is closed", "This account was deleted."),
            ("Account unavailable", "This account isn't available."),
            ("Account not found", "This account isn't available."),
            ("Expense not found", "This expense is no longer available."),
            ("Expense not found or not allowed", "This expense is no longer available."),
            ("Expense changed. Refresh and try again", "This expense changed. Refresh and try again."),
            ("Expense changed. Request a new proposal", "This expense changed. Suggest your edit again."),
            ("Recurring rule changed. Refresh and try again", "This repeating expense changed. Refresh and try again."),
            ("Rule not found", "This repeating expense is no longer available."),
            ("Recurring rule not found", "This repeating expense is no longer available."),
            ("Invalid recurring expense", "Check the repeat dates and try again."),
            ("Proposal not found", "This suggestion is no longer available."),
            ("Proposal is no longer pending", "This suggestion was already answered."),
            ("Proposer is not a participant", "They're no longer part of this expense."),
            ("Proposer is no longer a participant", "They're no longer part of this expense."),
            ("Creator cannot propose edits to own expense", "Edit your own expenses directly."),
            ("Only creator can respond", "Only the person who added this expense can answer."),
            ("Share not found", "This request is no longer available."),
            ("Pending share not found", "This request was already answered."),
            ("Share is not pending", "This request was already answered."),
            ("Failed to update own share", fallback),
            ("Not a participant", "You're no longer part of this expense."),
            ("Not a shared expense", "This expense isn't shared."),
            ("Shares must sum to expense total", "The split must add up to the total."),
            ("Shares must sum to the expense total", "The split must add up to the total."),
            ("Invalid shares", "The split must add up to the total."),
            ("Expense must have matching shares including creator and payer", "The split must include you and whoever paid."),
            ("Personal expenses must be paid by the creator", "You must be the payer of a personal expense."),
            ("Personal expense shares must belong to the creator", "A personal expense can't include others."),
            ("Invalid payer, participants or total", "Check who paid, who's in and the total."),
            ("Invalid expense", "Some details aren't valid. Check them and try again."),
            ("Invalid date", "Choose a valid date."),
            ("Date is required", "Choose a date."),
            ("Choose between 1 and 9 participants", "Split with 1 to 9 people."),
            ("Choose between 1 and 8 partners", "Split with 1 to 8 people."),
            ("Every split participant must be a connected user with a profile", "You can only split with your friends."),
            ("Every participant must be connected to the creator", "You can only split with your friends."),
            ("Participant unavailable", "Someone in this split isn't available anymore."),
            ("Share user must be a household member", "You can only split with your friends."),
            ("Payer must be a household member", "Whoever paid must be part of the split."),
            ("Connection required", "You can only split with your friends."),
            ("Friend not found", "This friend is no longer available."),
            ("Settle up before removing this friend", "Settle up before removing this friend."),
            ("You cannot connect with yourself", "That's your own code."),
            ("That code is unavailable", "That code is unavailable. Check it and try again."),
            ("Too many attempts. Please try again later", "Too many attempts. Try again later."),
            ("You can add up to 20 people without an account", "You can add up to 20 people without an account."),
            ("Placeholder partner cannot create households", "They need a Loam account for that."),
            ("Invalid repayment", "Enter a valid amount."),
            ("Repayment exceeds confirmed debt", "That's more than the confirmed balance."),
            ("Repayment not found or already reversed", "This repayment was already undone."),
            ("Custom categories need Loam Pro", "Custom categories need Loam Pro."),
            ("Removing categories needs Loam Pro", "Hiding categories needs Loam Pro."),
            ("You can have up to 50 categories", "You can have up to 50 categories."),
            ("Category not found", "This category is no longer available."),
            ("Custom categories are filed under Other", "Custom categories are filed under Other."),
            ("Name must be 1 to 100 characters", "Use a name up to 100 characters."),
            ("Display name must be 1 to 100 characters", "Use a name up to 100 characters."),
            ("Display name is required", "Enter your name."),
            ("Invalid email", "Enter a valid email."),
            ("Profile not found", "Your profile couldn't be found. Sign in again."),
            ("Deletion already accepted", "Your account is already being deleted."),
        ]
        return Dictionary(pairs.map { (normalized($0.0), $0.1) }, uniquingKeysWith: { first, _ in first })
    }()

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
