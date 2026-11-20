import XCTest

final class GmailMimeTests: XCTestCase {

    // MARK: OAuth and PKCE

    func testPKCEKnownVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(GmailPKCE.challenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let generated = GmailPKCE.verifier()
        XCTAssertGreaterThanOrEqual(generated.count, 43)
        XCTAssertLessThanOrEqual(generated.count, 128)
        XCTAssertFalse(generated.contains("="))
        XCTAssertFalse(generated.contains("+"))
        XCTAssertFalse(generated.contains("/"))
    }

    func testAuthorizationURLContainsPKCEAndScopes() {
        let config = GmailOAuthConfig(clientID: "123-abc.apps.googleusercontent.com")
        let url = GmailOAuth.authorizationURL(
            config: config, redirectURI: "http://127.0.0.1:49152",
            state: "state", challenge: "challenge")
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], config.clientID)
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:49152")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertTrue(items["scope"]?.contains("gmail.modify") == true)
        XCTAssertTrue(items["scope"]?.contains("gmail.send") == true)
    }

    // MARK: Payload parsing

    func testParsesNestedGmailPayload() throws {
        let plain = Data("Hello there".utf8).base64URLEncodedString()
        let html = Data("<p>Hello <b>there</b></p>".utf8).base64URLEncodedString()
        let json = """
        {
          "id": "m1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"],
          "snippet": "Hello there", "internalDate": "1700000000000",
          "sizeEstimate": 1234,
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [
              {"name": "From", "value": "Priya Sharma <priya@client.com>"},
              {"name": "To", "value": "Me <me@example.com>"},
              {"name": "Subject", "value": "Re: Pricing"},
              {"name": "Message-ID", "value": "<m1@example.com>"},
              {"name": "References", "value": "<root@example.com> <m1@example.com>"}
            ],
            "parts": [
              {
                "mimeType": "multipart/alternative",
                "parts": [
                  {"mimeType": "text/plain", "body": {"data": "\(plain)"}},
                  {"mimeType": "text/html", "body": {"data": "\(html)"}}
                ]
              },
              {
                "mimeType": "application/pdf", "filename": "plan.pdf",
                "headers": [{"name": "Content-Disposition", "value": "attachment; filename=plan.pdf"}],
                "body": {"attachmentId": "att1", "size": 99}
              }
            ]
          }
        }
        """
        let dto = try JSONDecoder().decode(GmailMessageDTO.self, from: Data(json.utf8))
        let message = GmailMime.message(from: dto, accountID: UUID())
        XCTAssertEqual(message.from.name, "Priya Sharma")
        XCTAssertEqual(message.from.email, "priya@client.com")
        XCTAssertEqual(message.to.first?.email, "me@example.com")
        XCTAssertEqual(message.subject, "Re: Pricing")
        XCTAssertEqual(message.bodyText, "Hello there")
        XCTAssertEqual(message.bodyHTML, "<p>Hello <b>there</b></p>")
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.filename, "plan.pdf")
        XCTAssertEqual(message.attachments.first?.id, "att1")
        XCTAssertTrue(message.isUnread)
        XCTAssertEqual(message.references, ["root@example.com", "m1@example.com"])
        XCTAssertEqual(message.internalDate.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    // MARK: Building

    func testBuildsMultipartMailWithAttachmentAndInlineImage() {
        let message = GmailOutgoingMessage(
            from: GmailAddress(name: "Me", email: "me@example.com"),
            to: [GmailAddress(name: "Priya", email: "priya@client.com")],
            cc: [GmailAddress(email: "sam@example.com")],
            subject: "Quarterly pricïng\nBcc: bad@example.com",
            text: "Hello there",
            html: "<p>Hello <b>there</b><img src=\"cid:inline1\"></p>",
            attachments: [
                GmailOutgoingAttachment(filename: "plan.pdf", mimeType: "application/pdf",
                                        data: Data("PDF".utf8)),
                GmailOutgoingAttachment(filename: "chart.png", mimeType: "image/png",
                                        data: Data([0x89, 0x50, 0x4E, 0x47]),
                                        isInline: true, contentID: "inline1")
            ],
            inReplyTo: "m1@example.com",
            references: ["root@example.com", "m1@example.com"],
            threadID: "t1")
        let raw = GmailMime.build(message)
        XCTAssertTrue(raw.contains("From: \"Me\" <me@example.com>"))
        XCTAssertTrue(raw.contains("To: \"Priya\" <priya@client.com>"))
        XCTAssertTrue(raw.contains("Cc: sam@example.com"))
        XCTAssertFalse(raw.contains("\nBcc:"), "header injection is flattened")
        XCTAssertTrue(raw.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed"))
        XCTAssertTrue(raw.contains("Content-Type: multipart/related"))
        XCTAssertTrue(raw.contains("Content-ID: <inline1>"))
        XCTAssertTrue(raw.contains("filename=\"plan.pdf\""))
        XCTAssertTrue(raw.contains("In-Reply-To: m1@example.com"))
        XCTAssertTrue(raw.contains("References: <root@example.com> <m1@example.com>"))
        // The whole message uses RFC 5322 line endings.
        XCTAssertFalse(raw.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testSanitizerRemovesActiveContentAndRemoteImages() {
        let dirty = """
            <p onclick="steal()">Hello</p>
            <script>alert(1)</script>
            <iframe src="https://evil.example"></iframe>
            <a href="javascript:alert(1)">bad</a>
            <img src="https://tracker.example/pixel.gif" alt="tracker">
            <img src="cid:inline1" alt="kept">
            """
        let clean = GmailMime.sanitizeHTML(dirty)
        XCTAssertFalse(clean.lowercased().contains("<script"))
        XCTAssertFalse(clean.lowercased().contains("onclick"))
        XCTAssertFalse(clean.lowercased().contains("<iframe"))
        XCTAssertFalse(clean.lowercased().contains("javascript:"))
        XCTAssertFalse(clean.contains("tracker.example"))
        XCTAssertTrue(clean.contains("cid:inline1"))
        XCTAssertTrue(clean.contains("remote image blocked"))
    }

    func testRFC2047HeadersAreDecoded() {
        let encoded = "=?UTF-8?B?UHJpY2luZyBmb3IgUTE=?="
        XCTAssertEqual(GmailMime.decodeHeader(encoded), "Pricing for Q1")
        XCTAssertEqual(GmailMime.decodeHeader("=?UTF-8?Q?Caf=C3=A9_meeting?="),
                       "Café meeting")
    }

    func testHTMLOnlyMessageGetsSearchablePlainText() throws {
        let html = "<html><body><p>Hello <b>there</b></p><p>Pricing is due Friday.</p></body></html>"
        let encoded = Data(html.utf8).base64URLEncodedString()
        let json = """
        {"id":"m1","threadId":"t1","payload":{"mimeType":"text/html",
          "headers":[{"name":"Subject","value":"HTML only"}],
          "body":{"data":"\(encoded)"}}}
        """
        let dto = try JSONDecoder().decode(GmailMessageDTO.self, from: Data(json.utf8))
        let message = GmailMime.message(from: dto, accountID: UUID())
        XCTAssertEqual(message.bodyText, "Hello there\nPricing is due Friday.")
        XCTAssertEqual(message.bodyHTML, html)
    }

    func testInlineDataReplacement() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let html = GmailMime.inline("<img src=\"cid:inline1\">",
                                    images: ["inline1": png])
        XCTAssertTrue(html.contains("data:image/png;base64,"))
    }

    func testInlineFileReferenceReplacement() {
        let attachment = GmailDraftAttachment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            filename: "chart.png", mimeType: "image/png",
            localPath: "/tmp/chart.png", isInline: true,
            contentID: "cid-1")
        let html = GmailMime.inlineFileReferences(
            "<img src=\"file:///tmp/chart.png\">", attachments: [attachment])
        XCTAssertEqual(html, "<img src=\"cid:cid-1\">")
    }
}
