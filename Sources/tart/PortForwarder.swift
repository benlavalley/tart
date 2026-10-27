import ArgumentParser
import Foundation
import Network
import os.log
import NIO
import NIOPosix

struct PortForward: ExpressibleByArgument {
  let hostPort: UInt16
  let guestPort: UInt16

  init?(argument: String) {
    let ports = argument.split(separator: ":", omittingEmptySubsequences: false)

    guard ports.count == 2,
          let hostPort = UInt16(ports[0]), hostPort != 0,
          let guestPort = UInt16(ports[1]), guestPort != 0 else {
      return nil
    }

    self.hostPort = hostPort
    self.guestPort = guestPort
  }
}

// Relays TCP connections accepted on a host port to a port on the VM's IP address
@available(macOS 14, *)
class PortForwarder {
  typealias ServerChannel = NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>

  let portForward: PortForward
  let resolveGuestIP: @Sendable () async throws -> IPv4Address?
  let eventLoopGroup: MultiThreadedEventLoopGroup
  let serverChannel: ServerChannel
  let logger: os.Logger = os.Logger(subsystem: "org.cirruslabs.tart.port-forwarder", category: "network")

  init(_ portForward: PortForward, resolveGuestIP: @escaping @Sendable () async throws -> IPv4Address?) async throws {
    self.portForward = portForward
    self.resolveGuestIP = resolveGuestIP
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.eventLoopGroup = eventLoopGroup

    do {
      self.serverChannel = try await ServerBootstrap(group: eventLoopGroup)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(.allowRemoteHalfClosure, value: true)
        .bind(host: "0.0.0.0", port: Int(portForward.hostPort)) { childChannel in
          childChannel.eventLoop.makeCompletedFuture {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
              wrappingChannelSynchronously: childChannel,
              configuration: .init(isOutboundHalfClosureEnabled: true)
            )
          }
        }
    } catch {
      try? await eventLoopGroup.shutdownGracefully()
      throw RuntimeError.PortForwardingFailed("failed to listen on port \(portForward.hostPort): \(error)")
    }
  }

  func run() async throws {
    try await withThrowingDiscardingTaskGroup { group in
      try await serverChannel.executeThenClose { serverInbound in
        for try await clientChannel in serverInbound {
          group.addTask {
            await self.handleClient(clientChannel)
          }
        }
      }
    }
  }

  func handleClient(_ clientChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
    let hostPort = portForward.hostPort
    let guestPort = portForward.guestPort

    do {
      try await clientChannel.executeThenClose { clientInbound, clientOutbound in
        guard let guestIP = try await resolveGuestIP() else {
          throw RuntimeError.NoIPAddressFound("no IP address found for the VM")
        }

        let guestAddress = "\(guestIP)"
        self.logger.info("forwarding connection on port \(hostPort) to \(guestAddress):\(guestPort)")

        let guestChannel = try await ClientBootstrap(group: eventLoopGroup)
          .channelOption(.allowRemoteHalfClosure, value: true)
          .connect(host: guestAddress, port: Int(guestPort)) { channel in
            channel.eventLoop.makeCompletedFuture {
              try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: channel,
                configuration: .init(isOutboundHalfClosureEnabled: true)
              )
            }
          }

        try await guestChannel.executeThenClose { guestInbound, guestOutbound in
          try await withThrowingDiscardingTaskGroup { group in
            // Proxy data from a client to a VM, then relay the client's half-closure
            group.addTask {
              for try await data in clientInbound {
                try await guestOutbound.write(data)
              }
              guestOutbound.finish()
            }

            // Proxy data from a VM to a client, then relay the VM's half-closure
            group.addTask {
              for try await data in guestInbound {
                try await clientOutbound.write(data)
              }
              clientOutbound.finish()
            }
          }
        }
      }
    } catch {
      logger.error("forwarding connection on port \(hostPort) failed: \(error)")
    }
  }
}
