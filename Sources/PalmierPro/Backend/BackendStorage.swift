import Foundation
@preconcurrency import ConvexMobile

enum BackendStorage {
    static func uploadStaged(fileURL: URL, contentType: String) async throws -> String {
        let ticket = try await uploadTicket()
        guard let stagingURL = URL(string: ticket.uploadUrl) else {
            throw BackendError.transport("Invalid staging URL")
        }

        var request = URLRequest(url: stagingURL)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try assertHTTPOK(respData: data, response: response)
        return try JSONDecoder().decode(StagingUploadResponse.self, from: data).storageId
    }

    @MainActor
    private static func uploadTicket() async throws -> StagingTicket {
        guard let convex = AccountService.shared.convex else {
            throw BackendError.notConfigured
        }
        return try await convex.mutation("uploads:generateUploadTicket")
    }

    private static func assertHTTPOK(respData: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response")
        }
        if (200..<300).contains(http.statusCode) { return }
        let detail = String(data: respData, encoding: .utf8) ?? ""
        if let parsed = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: respData) {
            throw BackendError.api(
                status: http.statusCode,
                code: parsed.error.code,
                message: parsed.error.message
            )
        }
        throw BackendError.transport("HTTP \(http.statusCode): \(detail)")
    }
}

private struct StagingTicket: Decodable, Sendable {
    let uploadUrl: String
}

private struct StagingUploadResponse: Decodable, Sendable {
    let storageId: String
}

private struct BackendErrorEnvelope: Decodable, Sendable {
    struct Inner: Decodable, Sendable {
        let code: String
        let message: String
    }
    let error: Inner
}
