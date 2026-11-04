// Network.framework setup shared by both apps.
import CryptoKit
import Foundation
import Network

public enum Transport {
  /// TLS 1.2 with a pre-shared key over TCP: only a device holding the pairing secret can complete the handshake.
  public static func controlParameters(secret: Data) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let key = secret.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    let identity = Data(ClamshellProtocol.pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key, identity)
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 5
    tcp.keepaliveInterval = 2
    tcp.keepaliveCount = 3
    let params = NWParameters(tls: tls, tcp: tcp)
    params.serviceClass = .interactiveVideo
    return params
  }

  public static func datagramParameters() -> NWParameters {
    let params = NWParameters.udp
    params.serviceClass = .interactiveVideo
    params.allowLocalEndpointReuse = true
    return params
  }

  public static func newSecret() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

/// Monotonic clock in microseconds; only ever compared after the phone estimates the offset between the two machines.
public func monotonicMicros() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }
public func monotonicSeconds() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }

/// Audio datagram: [u8 codec][payload]. 0 = Opus packet, 1 = raw 16-bit stereo PCM at 48 kHz.
public enum AudioFormatTag { public static let opus: UInt8 = 0, pcm16: UInt8 = 1 }
