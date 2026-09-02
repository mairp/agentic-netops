import React from 'react'

export default function Sidebar() {
  return (
    <aside style={{ width: 260, borderRight: '1px solid #eee', padding: '1rem' }}>
      <div style={{ fontWeight: 600, marginBottom: 8 }}>Suggested prompts</div>
      <ul style={{ paddingLeft: 18, margin: 0 }}>
        <li>provision a VPWS between leaf01 client01 and leaf02 client02 for tenant ACME</li>
        <li>status of service svc-123456</li>
        <li>remove service with correlation deadbeefdeadbeef</li>
      </ul>
    </aside>
  )
}
