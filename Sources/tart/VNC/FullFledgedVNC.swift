import Foundation
import Dynamic
import Virtualization

class FullFledgedVNC: VNC {
  // _VZVNCServer's state after it fails to listen
  // (e.g. when the requested port is already in use)
  private static let stateFailed = 2

  let password: String
  private let requestedPort: UInt16
  private let vnc: Dynamic

  init(virtualMachine: VZVirtualMachine, port: UInt16 = 0, password: String? = nil) {
    self.password = password ?? Array(PassphraseGenerator().prefix(4)).joined(separator: "-")
    requestedPort = port
    let securityConfiguration = Dynamic._VZVNCAuthenticationSecurityConfiguration(password: self.password)
    vnc = Dynamic._VZVNCServer(port: port, queue: DispatchQueue.global(),
                               securityConfiguration: securityConfiguration)
    vnc.virtualMachine = virtualMachine
    vnc.start()
  }

  func waitForURL(netBridged: Bool) async throws -> URL {
    while true {
      // Port is 0 shortly after start(),
      // but will be initialized later
      if let port = vnc.port.asUInt16, port != 0 {
        // Use URLComponents to percent-encode user-provided passwords
        var components = URLComponents()
        components.scheme = "vnc"
        components.user = ""
        components.password = password
        components.host = "127.0.0.1"
        components.port = Int(port)

        return components.url!
      }

      if vnc.state.asInt == Self.stateFailed {
        if requestedPort != 0 {
          throw RuntimeError.VNCFailed("failed to listen on port \(requestedPort), is it already in use?")
        }

        throw RuntimeError.VNCFailed("failed to start the VNC server")
      }

      // Wait 50 ms.
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  func stop() throws {
    vnc.stop()
  }

  deinit {
    try? stop()
  }
}
