import Foundation

// stdio MCP is a main-thread, line-oriented protocol. The store is @MainActor, and
// top-level code runs on the main thread, so assume that isolation rather than
// spinning up an async runtime for a blocking read loop.
MainActor.assumeIsolated {
    MCPServer().run()
}
