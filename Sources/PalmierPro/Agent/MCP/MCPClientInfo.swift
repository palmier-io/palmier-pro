import MCP

struct MCPClientInfo: Equatable, Sendable {
    let name: String
    let title: String?
    let version: String
    let description: String?
    let websiteUrl: String?

    init(
        name: String,
        title: String? = nil,
        version: String,
        description: String? = nil,
        websiteUrl: String? = nil
    ) {
        self.name = name
        self.title = title
        self.version = version
        self.description = description
        self.websiteUrl = websiteUrl
    }

    init(_ clientInfo: Client.Info) {
        self.init(
            name: clientInfo.name,
            title: clientInfo.title,
            version: clientInfo.version,
            description: clientInfo.description,
            websiteUrl: clientInfo.websiteUrl
        )
    }

    var payload: Analytics.Payload {
        var payload: Analytics.Payload = [
            "name": name,
            "version": version,
        ]
        if let title { payload["title"] = title }
        if let description { payload["description"] = description }
        if let websiteUrl { payload["websiteUrl"] = websiteUrl }
        return payload
    }
}
