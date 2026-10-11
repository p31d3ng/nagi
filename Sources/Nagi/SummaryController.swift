import Foundation
import JournalCore
import SwiftUI

@MainActor final class SummaryController: ObservableObject {
    @Published var endpointText: String
    @Published var automatic: Bool
    @Published var credentialAvailable = false
    @Published var configurationMessage = ""
    @Published var busySession: String?
    @Published var latest: [String: String]?
    @Published var envelope: SummaryEnvelope?
    @Published var selectedRevision = 0
    @Published var lastMessage = ""
    @Published var messageSession: String?
    @Published var selectedReady = false
    private let store: Store
    private let vault: SummaryCredentialVault
    private let transport: SummaryTransport
    private let networkAllowed: Bool
    private var task: Task<Void, Never>?
    private var activeID: String?
    private var activeAutomatic = false
    private var selection: String?
    init(
        store: Store, networkAllowed: Bool, vault: SummaryCredentialVault = SummaryKeychain(),
        transport: SummaryTransport = SummaryHTTPTransport()
    ) {
        self.store = store; self.vault = vault; self.transport = transport;
        self.networkAllowed = networkAllowed
        endpointText = store.setting("summary-endpoint", fallback: SummaryEndpoint.suggested)
        automatic = store.setting("summary-automatic") == "true"
        // A lost response must never turn into a duplicate billed inference after restart.
        _ = try? store.exec(
            "UPDATE summaries SET status='uncertain',error='App interrupted while waiting. The service may have processed the request; retry only manually.' WHERE status='sending'"
        )
        if let url = try? SummaryEndpoint.validate(endpointText) {
            credentialAvailable = vault.contains(endpoint: url)
        }
    }
    var savedEndpoint: URL? {
        try? SummaryEndpoint.validate(
            store.setting("summary-endpoint", fallback: SummaryEndpoint.suggested))
    }
    func endpointDraftChanged() {
        if (try? SummaryEndpoint.validate(endpointText)) != savedEndpoint {
            cancel(); setAutomatic(false)
            configurationMessage =
                "Unsaved destination: submissions are paused. Save the endpoint, then enter its credential and opt in again if desired."
        }
    }
    func saveEndpoint() {
        do {
            let url = try SummaryEndpoint.validate(endpointText)
            if url != savedEndpoint {
                cancel(); setAutomatic(false)
                try store.set("summary-endpoint", url.absoluteString)
            } else {
                try store.set("summary-endpoint", url.absoluteString)
            }
            endpointText = url.absoluteString
            credentialAvailable = vault.contains(endpoint: url)
            configurationMessage =
                credentialAvailable
                ? "Endpoint saved. Credential is bound to this exact URL."
                : "Endpoint saved. Enter its app bearer; credentials are not copied to changed URLs."
        } catch { configurationMessage = error.localizedDescription }
    }
    func saveBearer(_ value: String) {
        guard networkAllowed, let endpoint = savedEndpoint,
            (try? SummaryEndpoint.validate(endpointText)) == endpoint
        else {
            configurationMessage = "Save the endpoint first."; return
        }
        do {
            try vault.save(value, endpoint: endpoint); credentialAvailable = true
            configurationMessage =
                "App bearer saved in this Mac's Keychain. It is not stored in the journal."
        } catch { configurationMessage = error.localizedDescription }
    }
    func forgetBearer() {
        guard networkAllowed, let endpoint = savedEndpoint else { return }
        cancel(); setAutomatic(false)
        do {
            try vault.delete(endpoint: endpoint); credentialAvailable = false
            configurationMessage = "Credential removed. Automatic summarization is off."
        } catch { configurationMessage = error.localizedDescription }
    }
    func setAutomatic(_ enabled: Bool) {
        guard networkAllowed else { return }
        automatic =
            enabled && credentialAvailable && savedEndpoint != nil
            && (try? SummaryEndpoint.validate(endpointText)) == savedEndpoint
        try? store.set("summary-automatic", automatic ? "true" : "false")
        if !automatic {
            _ = try? store.exec("UPDATE summary_auto SET state='cancelled' WHERE state='waiting'")
            if activeAutomatic { cancel() }
        }
    }
    func arm(session: String) {
        guard networkAllowed, automatic, credentialAvailable, let endpoint = savedEndpoint else {
            return
        }
        _ = try? store.exec(
            "INSERT OR IGNORE INTO summary_auto(session,endpoint) VALUES(?,?)",
            [session, endpoint.absoluteString])
    }
    func observe(selected: String?) {
        selection = selected
        if let selected {
            let row =
                try? store.exec(
                    "SELECT * FROM summaries WHERE session=? ORDER BY created DESC LIMIT 1",
                    [selected]
                )
                .first
            if latest != row {
                latest = row
                envelope = row?["response"]
                    .flatMap {
                        try? JSONDecoder().decode(SummaryEnvelope.self, from: Data($0.utf8))
                    }
            }
            let revision = SummaryStorage.revision(store, session: selected)
            if selectedRevision != revision { selectedRevision = revision }
            let ready = (try? SummaryStorage.ready(store, session: selected)) == true
            if selectedReady != ready { selectedReady = ready }
        } else {
            if latest != nil { latest = nil; envelope = nil }
            if selectedRevision != 0 { selectedRevision = 0 }
            if selectedReady { selectedReady = false }
        }
        guard networkAllowed, automatic, task == nil, let endpoint = savedEndpoint else { return }
        // Consent rows only; incomplete sessions cannot starve a later finalized one.
        _ = try? SummaryStorage.recordFinalized(store)
        if let id = try? store
            .exec(
                "SELECT a.session FROM summary_auto a JOIN summary_ready r ON r.session=a.session JOIN sessions s ON s.id=a.session WHERE a.state='waiting' AND a.endpoint=? AND s.status!='recording' AND NOT EXISTS(SELECT 1 FROM chunks c WHERE c.session=s.id AND NOT (c.status IN ('done','silence') OR (c.status='expired' AND EXISTS(SELECT 1 FROM summary_chunk_final f WHERE f.chunk=c.id)))) LIMIT 1",
                [endpoint.absoluteString]
            )
            .first?["session"]
        {
            submit(session: id, automatic: true)
        }
    }
    func cancel(session: String? = nil) {
        if let session, session != busySession { return }
        task?.cancel()
        if let id = activeID {
            _ = try? store.exec(
                "UPDATE summaries SET status='uncertain',error='Cancelled locally. The service may already have processed this request; retry only manually.' WHERE id=? AND status='sending'",
                [id])
        }
    }
    func submit(session: String, automatic isAutomatic: Bool = false) {
        guard networkAllowed, task == nil, let endpoint = savedEndpoint else { return }
        guard (try? SummaryEndpoint.validate(endpointText)) == endpoint else {
            lastMessage = "Save the changed endpoint before submitting. Nothing was sent."
            messageSession = session; return
        }
        busySession = session; activeAutomatic = isAutomatic
        lastMessage = ""; messageSession = session
        let store = store, transport = transport
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil; self.activeID = nil; self.busySession = nil;
                self.activeAutomatic = false
                self.observe(selected: self.selection)
            }
            let id = UUID().uuidString
            do {
                let snapshot =
                    try await Task.detached(priority: .utility) {
                        try SummaryStorage.snapshot(store, session: session)
                    }
                    .value
                try Task.checkCancellation()
                if isAutomatic && (!self.automatic || self.savedEndpoint != endpoint) { return }
                let bearer = try self.vault.read(endpoint: endpoint)
                try store.transaction {
                    if isAutomatic {
                        guard
                            !(try store.exec(
                                "SELECT 1 FROM summary_auto WHERE session=? AND state='waiting' AND endpoint=?",
                                [session, endpoint.absoluteString]))
                                .isEmpty
                        else { throw CancellationError() }
                        try store.exec(
                            "UPDATE summary_auto SET state='attempted' WHERE session=?", [session])
                    }
                    if !isAutomatic {
                        try store.exec(
                            "UPDATE summary_auto SET state='attempted' WHERE session=? AND endpoint=? AND state='waiting'",
                            [session, endpoint.absoluteString])
                    }
                    try store.exec(
                        "INSERT INTO summaries VALUES(?,?,?,?,?,'', '',?,?)",
                        [
                            id, session, snapshot.input.version, endpoint.absoluteString, "sending",
                            Date().timeIntervalSince1970, isAutomatic ? 1 : 0,
                        ])
                }
                self.activeID = id; self.observe(selected: self.selection)
                let result = try await transport.send(
                    endpoint: endpoint, body: snapshot.body, bearer: bearer)
                try Task.checkCancellation()
                guard result.status == 200 else { throw JournalError(Self.failure(result.status)) }
                let response = try JSONDecoder().decode(SummaryEnvelope.self, from: result.body)
                    .checked(against: snapshot.input)
                let data = try JSONEncoder().encode(response)
                guard !String(decoding: data, as: UTF8.self).contains(bearer) else {
                    throw JournalError(
                        "Service response contained credential material and was discarded. No response was saved; retry only manually."
                    )
                }
                let state =
                    SummaryStorage.revision(store, session: session) == snapshot.input.version
                    ? "done" : "stale"
                try store.exec(
                    "UPDATE summaries SET status=?,response=? WHERE id=? AND status='sending'",
                    [state, String(decoding: data, as: UTF8.self), id])
            } catch {
                // Never persist raw HTTP bodies, Authorization headers or URLSession errors.
                let message: String
                if error is CancellationError {
                    message =
                        "Cancelled locally. The service may have processed it; retry only manually."
                } else if let known = error as? JournalError {
                    message = known.message
                } else {
                    message =
                        "Invalid or interrupted service response. It may have processed the request; retry only manually."
                }
                self.lastMessage = message
                if isAutomatic && self.activeID != nil { self.setAutomatic(false) }
                if self.activeID != nil {
                    _ = try? store.exec(
                        "UPDATE summaries SET status='uncertain',error=? WHERE id=? AND status='sending'",
                        [message, id])
                } else {
                    if isAutomatic {
                        do {
                            try store.exec(
                                "UPDATE summary_auto SET state='attempted' WHERE session=?",
                                [session])
                        } catch { self.automatic = false }
                    }
                    _ = try? store.exec(
                        "INSERT INTO summaries VALUES(?,?,?,?,?,?, '',?,?)",
                        [
                            id, session, SummaryStorage.revision(store, session: session),
                            endpoint.absoluteString, "blocked", message,
                            Date().timeIntervalSince1970, isAutomatic ? 1 : 0,
                        ])
                }
            }
        }
    }
    private static func failure(_ status: Int) -> String {
        switch status {
        case 301...399:
            return
                "Redirect blocked. Use the service's direct HTTPS URL. No credential was forwarded."
        case 401, 403:
            return
                "Service rejected authentication. Check endpoint and original app bearer in Settings; retry manually."
        case 402, 429:
            return
                "Service quota or billing limit reached. Check the service account; no automatic retry."
        case 413:
            return
                "Service rejected an oversized transcript. Nothing was truncated; long-transcript support is unavailable."
        case 504: return "Service timed out. Inference may have run; retry only manually."
        default:
            return
                "Service returned HTTP \(status). It may have processed the request; retry only manually."
        }
    }
}
