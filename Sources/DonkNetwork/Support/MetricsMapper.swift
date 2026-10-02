import DonkCore
import Foundation

package protocol TransactionMetricsSource {
    var fetchStartDate: Date? { get }
    var domainLookupStartDate: Date? { get }
    var domainLookupEndDate: Date? { get }
    var connectStartDate: Date? { get }
    var connectEndDate: Date? { get }
    var secureConnectionStartDate: Date? { get }
    var secureConnectionEndDate: Date? { get }
    var requestStartDate: Date? { get }
    var requestEndDate: Date? { get }
    var responseStartDate: Date? { get }
    var responseEndDate: Date? { get }
    var networkProtocolName: String? { get }
    var isProxyConnection: Bool { get }
    var isReusedConnection: Bool { get }
    var remoteAddressValue: String? { get }
    var remotePortValue: Int? { get }
    var tlsProtocolVersionValue: UInt16? { get }
    var tlsCipherSuiteValue: UInt16? { get }
    var requestHeaderBytes: Int64 { get }
    var requestBodyBytes: Int64 { get }
    var responseHeaderBytes: Int64 { get }
    var responseBodyBytes: Int64 { get }
}

extension URLSessionTaskTransactionMetrics: TransactionMetricsSource {
    package var remoteAddressValue: String? { remoteAddress }
    package var remotePortValue: Int? { remotePort }
    package var tlsProtocolVersionValue: UInt16? { negotiatedTLSProtocolVersion?.rawValue }
    package var tlsCipherSuiteValue: UInt16? { negotiatedTLSCipherSuite?.rawValue }
    package var requestHeaderBytes: Int64 { countOfRequestHeaderBytesSent }
    package var requestBodyBytes: Int64 { countOfRequestBodyBytesSent }
    package var responseHeaderBytes: Int64 { countOfResponseHeaderBytesReceived }
    package var responseBodyBytes: Int64 { countOfResponseBodyBytesReceived }
}

package enum MetricsMapper {
    package static func map(_ metrics: URLSessionTaskMetrics) -> [TransactionMetrics] {
        metrics.transactionMetrics.map { map($0) }
    }

    package static func sentHeaders(_ metrics: URLSessionTaskMetrics) -> [HTTPHeader] {
        guard let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }) else { return [] }
        return HTTPHeader.list(from: transaction.request.allHTTPHeaderFields)
    }

    package static func map(_ source: TransactionMetricsSource) -> TransactionMetrics {
        TransactionMetrics(
            fetchStart: source.fetchStartDate,
            domainLookupStart: source.domainLookupStartDate,
            domainLookupEnd: source.domainLookupEndDate,
            connectStart: source.connectStartDate,
            connectEnd: source.connectEndDate,
            secureConnectionStart: source.secureConnectionStartDate,
            secureConnectionEnd: source.secureConnectionEndDate,
            requestStart: source.requestStartDate,
            requestEnd: source.requestEndDate,
            responseStart: source.responseStartDate,
            responseEnd: source.responseEndDate,
            networkProtocol: protocolName(source.networkProtocolName),
            remoteAddress: address(source.remoteAddressValue, port: source.remotePortValue),
            tlsProtocol: source.tlsProtocolVersionValue.flatMap(tlsVersionName),
            tlsCipherSuite: source.tlsCipherSuiteValue.map(cipherSuiteName),
            isReusedConnection: source.isReusedConnection,
            isProxyConnection: source.isProxyConnection,
            requestHeaderBytes: max(0, source.requestHeaderBytes),
            requestBodyBytes: max(0, source.requestBodyBytes),
            responseHeaderBytes: max(0, source.responseHeaderBytes),
            responseBodyBytes: max(0, source.responseBodyBytes)
        )
    }

    package static func protocolName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "h2", "h2c": return "HTTP/2"
        case "h3", "http/3": return "HTTP/3"
        case "http/1.1": return "HTTP/1.1"
        case "http/1.0": return "HTTP/1.0"
        case "http/0.9": return "HTTP/0.9"
        default:
            if raw.lowercased().hasPrefix("h3-") { return "HTTP/3" }
            return raw.uppercased()
        }
    }

    package static func address(_ host: String?, port: Int?) -> String? {
        guard let host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        guard let port, port > 0 else { return host }
        if host.contains(":"), !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    package static func tlsVersionName(_ raw: UInt16) -> String? {
        switch raw {
        case 0x0300: return "SSL 3.0"
        case 0x0301: return "TLS 1.0"
        case 0x0302: return "TLS 1.1"
        case 0x0303: return "TLS 1.2"
        case 0x0304: return "TLS 1.3"
        case 0xFEFF: return "DTLS 1.0"
        case 0xFEFD: return "DTLS 1.2"
        case 0: return nil
        default: return String(format: "TLS 0x%04X", raw)
        }
    }

    package static func cipherSuiteName(_ raw: UInt16) -> String {
        cipherSuites[raw] ?? String(format: "0x%04X", raw)
    }

    private static let cipherSuites: [UInt16: String] = [
        0x1301: "TLS_AES_128_GCM_SHA256",
        0x1302: "TLS_AES_256_GCM_SHA384",
        0x1303: "TLS_CHACHA20_POLY1305_SHA256",
        0x1304: "TLS_AES_128_CCM_SHA256",
        0x1305: "TLS_AES_128_CCM_8_SHA256",
        0xC02B: "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
        0xC02C: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
        0xC02F: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
        0xC030: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
        0xCCA8: "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
        0xCCA9: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
        0xC009: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA",
        0xC00A: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA",
        0xC013: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
        0xC014: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
        0xC023: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
        0xC024: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384",
        0xC027: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256",
        0xC028: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384",
        0xC008: "TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA",
        0xC012: "TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA",
        0x009C: "TLS_RSA_WITH_AES_128_GCM_SHA256",
        0x009D: "TLS_RSA_WITH_AES_256_GCM_SHA384",
        0x003C: "TLS_RSA_WITH_AES_128_CBC_SHA256",
        0x003D: "TLS_RSA_WITH_AES_256_CBC_SHA256",
        0x002F: "TLS_RSA_WITH_AES_128_CBC_SHA",
        0x0035: "TLS_RSA_WITH_AES_256_CBC_SHA",
        0x000A: "TLS_RSA_WITH_3DES_EDE_CBC_SHA",
    ]
}
