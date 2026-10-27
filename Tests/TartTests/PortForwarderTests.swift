import Foundation
import Network
import XCTest
@testable import tart

final class PortForwarderTests: XCTestCase {
  func testPortForwardParsesHostAndGuestPorts() throws {
    let portForward = try XCTUnwrap(PortForward(argument: "2222:22"))

    XCTAssertEqual(portForward.hostPort, 2222)
    XCTAssertEqual(portForward.guestPort, 22)
  }

  func testPortForwardRejectsMalformedSpecifications() {
    for argument in ["2222", "2222:", ":22", "0:22", "2222:0", "ssh:22", "70000:22", "2222:22:22", "-1:22"] {
      XCTAssertNil(PortForward(argument: argument), argument)
    }
  }

  func testRelaysDataInBothDirectionsAcrossHalfClosure() async throws {
    guard #available(macOS 14, *) else { throw XCTSkip("PortForwarder requires macOS 14") }

    // The echo server only replies after reading EOF, so the reply arrives
    // only if the forwarder relays the client's half-closure to the guest
    // and keeps relaying the guest's data back after it
    let echoServer = try EchoServer()
    let hostPort = try unusedPort()
    let forwarder = try await PortForwarder(XCTUnwrap(PortForward(argument: "\(hostPort):\(echoServer.port)"))) {
      IPv4Address("127.0.0.1")
    }
    let forwarding = Task { try await forwarder.run() }
    defer { forwarding.cancel() }

    let response = try await exchange(Data("hello from the host".utf8), port: hostPort)

    XCTAssertEqual(String(decoding: response, as: UTF8.self), "hello from the host")
  }

  func testClosesConnectionWhenGuestIPIsUnknown() async throws {
    guard #available(macOS 14, *) else { throw XCTSkip("PortForwarder requires macOS 14") }

    let hostPort = try unusedPort()
    let forwarder = try await PortForwarder(XCTUnwrap(PortForward(argument: "\(hostPort):22"))) {
      nil
    }
    let forwarding = Task { try await forwarder.run() }
    defer { forwarding.cancel() }

    let response = try await exchange(Data("hello".utf8), port: hostPort)

    XCTAssertEqual(response, Data())
  }

  func testFailsWhenHostPortIsAlreadyInUse() async throws {
    guard #available(macOS 14, *) else { throw XCTSkip("PortForwarder requires macOS 14") }

    let (blockingSocket, hostPort) = try listeningSocket(address: INADDR_ANY)
    defer { close(blockingSocket) }

    do {
      _ = try await PortForwarder(XCTUnwrap(PortForward(argument: "\(hostPort):22"))) {
        IPv4Address("127.0.0.1")
      }
      XCTFail("expected PortForwarder to fail when the host port is already in use")
    } catch {
      // expected
    }
  }
}

// Accepts connections on 127.0.0.1, reads each until EOF and then writes everything back
private final class EchoServer {
  let port: UInt16
  private let listeningFD: Int32

  init() throws {
    (listeningFD, port) = try listeningSocket(address: INADDR_LOOPBACK)

    let listeningFD = listeningFD
    Thread.detachNewThread {
      while true {
        let connectionFD = accept(listeningFD, nil, nil)
        if connectionFD < 0 {
          return
        }

        // Reply only after a clean EOF, never after a read timeout
        setTimeout(connectionFD)
        if let received = readUntilEOF(connectionFD) {
          writeAll(connectionFD, received)
        }
        close(connectionFD)
      }
    }
  }

  deinit {
    close(listeningFD)
  }
}

private struct SocketError: Error {
  let operation: String
  let code: Int32 = errno
}

private func listeningSocket(address: in_addr_t) throws -> (Int32, UInt16) {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw SocketError(operation: "socket") }

  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_addr.s_addr = address.bigEndian
  addr.sin_port = 0

  let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bound == 0, listen(fd, 16) == 0 else {
    close(fd)
    throw SocketError(operation: "bind/listen")
  }

  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let named = withUnsafeMutablePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getsockname(fd, $0, &length)
    }
  }
  guard named == 0 else {
    close(fd)
    throw SocketError(operation: "getsockname")
  }

  return (fd, UInt16(bigEndian: addr.sin_port))
}

private func unusedPort() throws -> UInt16 {
  let (fd, port) = try listeningSocket(address: INADDR_ANY)
  close(fd)

  return port
}

// Connects to 127.0.0.1:port, sends data, half-closes and reads the response until EOF
private func exchange(_ data: Data, port: UInt16) async throws -> Data {
  try await withCheckedThrowingContinuation { continuation in
    Thread.detachNewThread {
      continuation.resume(with: Result {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(operation: "socket") }
        defer { close(fd) }

        setTimeout(fd)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = port.bigEndian

        let connected = withUnsafePointer(to: &addr) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
        guard connected == 0 else { throw SocketError(operation: "connect") }

        writeAll(fd, data)
        shutdown(fd, SHUT_WR)

        guard let response = readUntilEOF(fd) else { throw SocketError(operation: "read") }

        return response
      })
    }
  }
}

// Bound blocking reads so that a forwarder that never relays EOF fails the test instead of hanging it
private func setTimeout(_ fd: Int32) {
  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

// Returns nil when the read fails or times out before EOF
private func readUntilEOF(_ fd: Int32) -> Data? {
  var received = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)

  while true {
    let count = read(fd, &buffer, buffer.count)
    if count == 0 {
      return received
    }
    if count < 0 {
      return nil
    }
    received.append(contentsOf: buffer[0..<count])
  }
}

private func writeAll(_ fd: Int32, _ data: Data) {
  data.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
      if written <= 0 {
        return
      }
      offset += written
    }
  }
}
