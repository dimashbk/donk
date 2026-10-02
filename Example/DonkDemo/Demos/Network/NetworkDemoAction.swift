import DonkUI
import Foundation

enum NetworkDemoSection: String, CaseIterable, Identifiable {
    case methods = "Methods & statuses"
    case content = "Content & streaming"
    case sessions = "Session styles"
    case failures = "Failures & load"

    var id: String { rawValue }

    var actions: [NetworkDemoAction] {
        NetworkDemoAction.allCases.filter { $0.section == self }
    }
}

enum NetworkDemoAction: String, CaseIterable, Identifiable {
    case getJSON, postJSON, put, patch, delete, notFound, serverError, redirect, slow
    case image, largeJSON, gzip, chunked, sse
    case sharedCompletion, asyncAwait, delegateSession, multipart
    case startCancel, dnsFailure, burst
    case breakpointTarget

    var id: String { rawValue }

    var section: NetworkDemoSection? {
        switch self {
        case .getJSON, .postJSON, .put, .patch, .delete, .notFound, .serverError, .redirect, .slow: return .methods
        case .image, .largeJSON, .gzip, .chunked, .sse: return .content
        case .sharedCompletion, .asyncAwait, .delegateSession, .multipart: return .sessions
        case .startCancel, .dnsFailure, .burst: return .failures
        case .breakpointTarget: return nil
        }
    }

    var title: String {
        switch self {
        case .getJSON: return "GET JSON"
        case .postJSON: return "POST JSON"
        case .put: return "PUT"
        case .patch: return "PATCH"
        case .delete: return "DELETE"
        case .notFound: return "404 Not Found"
        case .serverError: return "500 Server Error"
        case .redirect: return "Redirect ×2"
        case .slow: return "Slow (3 s)"
        case .image: return "Image"
        case .largeJSON: return "Large JSON"
        case .gzip: return "gzip"
        case .chunked: return "Chunked stream"
        case .sse: return "Server-sent events"
        case .sharedCompletion: return "URLSession.shared"
        case .asyncAwait: return "async / await"
        case .delegateSession: return "Custom delegate session"
        case .multipart: return "Multipart upload"
        case .startCancel: return "Start + cancel"
        case .dnsFailure: return "DNS failure"
        case .burst: return "Burst ×20"
        case .breakpointTarget: return "POST /anything"
        }
    }

    var subtitle: String {
        switch self {
        case .getJSON: return "jsonplaceholder · /todos/1"
        case .postJSON: return "httpbin · /post"
        case .put: return "httpbin · /put"
        case .patch: return "httpbin · /patch"
        case .delete: return "httpbin · /delete"
        case .notFound: return "httpbin · /status/404"
        case .serverError: return "httpbin · /status/500"
        case .redirect: return "httpbin · /redirect/2"
        case .slow: return "httpbin · /delay/3"
        case .image: return "picsum · /400 (redirects to CDN)"
        case .largeJSON: return "jsonplaceholder · /photos ≈ 1 MB"
        case .gzip: return "httpbin · /gzip, body captured decoded"
        case .chunked: return "httpbin · /stream/20, read with bytes(for:)"
        case .sse: return "httpbun · /sse, 10 events at 1/s"
        case .sharedCompletion: return "completion handler API"
        case .asyncAwait: return "data(for:) on an ephemeral session"
        case .delegateSession: return "Alamofire-style delegate, redirect approved after 300 ms"
        case .multipart: return "upload task, passes through natively unless a rule targets it"
        case .startCancel: return "httpbin · /delay/5, cancelled after 0.6 s"
        case .dnsFailure: return "nonexistent.invalid"
        case .burst: return "20 parallel GETs"
        case .breakpointTarget: return "httpbin · paused by the sample breakpoint"
        }
    }

    var method: String {
        switch self {
        case .postJSON, .multipart, .breakpointTarget: return "POST"
        case .put: return "PUT"
        case .patch: return "PATCH"
        case .delete: return "DELETE"
        case .sse, .chunked: return "SSE"
        default: return "GET"
        }
    }

    var icon: String {
        switch self {
        case .getJSON: return "arrow.down.doc"
        case .postJSON: return "paperplane"
        case .put: return "square.and.pencil"
        case .patch: return "bandage"
        case .delete: return "trash"
        case .notFound: return "questionmark.folder"
        case .serverError: return "exclamationmark.triangle"
        case .redirect: return "arrow.triangle.turn.up.right.diamond"
        case .slow: return "tortoise"
        case .image: return "photo"
        case .largeJSON: return "doc.text.magnifyingglass"
        case .gzip: return "archivebox"
        case .chunked: return "square.stack.3d.down.right"
        case .sse: return "dot.radiowaves.left.and.right"
        case .sharedCompletion: return "globe"
        case .asyncAwait: return "arrow.triangle.2.circlepath"
        case .delegateSession: return "person.crop.circle.badge.checkmark"
        case .multipart: return "square.and.arrow.up"
        case .startCancel: return "xmark.octagon"
        case .dnsFailure: return "wifi.exclamationmark"
        case .burst: return "bolt.horizontal"
        case .breakpointTarget: return "pause.circle"
        }
    }

    var tone: DonkTone {
        switch self {
        case .notFound: return .warning
        case .serverError, .dnsFailure, .startCancel, .delete: return .error
        case .sse, .chunked: return .web
        case .image, .largeJSON, .gzip: return .info
        case .sharedCompletion, .asyncAwait, .delegateSession, .multipart: return .accent
        case .breakpointTarget: return .warning
        default: return .success
        }
    }
}
