/**
 * Intent-tier chat surface (feature 002) — Phase 1 scaffold.
 *
 * The streaming client (NDJSON over POST /agent/prompt/stream) arrives in a
 * later phase; this scaffold proves the app builds and exposes the
 * supervisor endpoint it will talk to. There is deliberately no WebSocket
 * client anywhere in this codebase (REVERSE.md correction 3).
 */
const supervisorApiUrl: string =
  import.meta.env.VITE_SUPERVISOR_API_URL ?? 'http://supervisor.ainetops-agents.svc:9090'

export default function App() {
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', margin: '2rem', maxWidth: '60rem' }}>
      <h1>AINETOPS Intent Tier</h1>
      <p>
        Describe a service in plain language and the supervisor routes it to the mapper,
        allocator, and deployer agents.
      </p>
      <section>
        <h2>Supervisor</h2>
        <code>{supervisorApiUrl}</code>
      </section>
      <section>
        <h2>Chat</h2>
        <input
          aria-label="Service request"
          placeholder="provision a point-to-point 1Gbps L2 service between leaf01 client01 and leaf02 client02 for tenant ACME"
          style={{ width: '100%', padding: '0.5rem' }}
          readOnly
        />
        <p>Chat streaming arrives in a later phase of this feature.</p>
      </section>
    </main>
  )
}
