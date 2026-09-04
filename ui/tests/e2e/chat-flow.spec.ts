import { test, expect } from '@playwright/test'

// These tests are non-networked UI behavior checks using stubbed UI state.
// They assert that the Chat surface renders stages, confirmations, decline
// cancellation, progress, and failure cards with correlation id chips.

function injectEvents(page) {
  return page.addInitScript(() => {
    (window as any).__injectEvents = (evts: any[]) => {
      const listeners: any[] = []
      const origAddEventListener = document.addEventListener.bind(document)
      document.addEventListener = ((type: string, listener: any, opts?: any) => {
        if (type === 'DOMContentLoaded') {
          listeners.push(listener)
        }
        return origAddEventListener(type, listener, opts)
      }) as any
      // Monkey-patch fetch to feed our NDJSON lines into the Chat hook
      const origFetch = window.fetch.bind(window)
      window.fetch = (input: RequestInfo | URL, init?: RequestInit): any => {
        if (typeof input === 'string' && input.includes('/agent/prompt/stream')) {
          const encoder = new TextEncoder()
          const data = evts.map(e => JSON.stringify(e)).join('\n') + '\n'
          const stream = new ReadableStream({
            start(controller) {
              controller.enqueue(encoder.encode(data))
              controller.close()
            }
          })
          return Promise.resolve(new Response(stream, { headers: { 'Content-Type': 'application/x-ndjson' } }))
        }
        return origFetch(input as any, init)
      }
    }
  })
}

test('happy path: interpretation, allocation, deployment outcome', async ({ page }) => {
  await injectEvents(page)
  await page.goto('http://localhost:3000')
  await page.evaluate(() => (window as any).__injectEvents([
    { type: 'status', status: 'RECEIVED_REQUEST', thread_id: 't1', correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    { type: 'stage', stage: 'mapper', status: 'MAPPED', payload: { serviceType: 'VPWS' }, correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    { type: 'confirmation_request', stage: 'mapper', prompt: 'Confirm?', refusable: true, correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    { type: 'stage', stage: 'allocator', status: 'ALLOCATED', payload: { rdRt: { rd: '1:1', rt: '1:1' } }, correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    { type: 'confirmation_request', stage: 'allocator', prompt: 'Deploy?', refusable: true, correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    { type: 'stage', stage: 'deployer', status: 'COMPLETED', payload: { submitted: [{ kind: 'Network', name: 'net-svc-alpha' }], convergence: [{ resource: 'Network/net-svc-alpha', outcome: 'ready', ready: true, detail: 'applied and verified on all nodes' }] }, correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    { type: 'progress', stage: 'deployer', status: 'COMPLETED', message: 'Network/net-svc-alpha converged: applied and verified on all nodes', correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    { type: 'final', status: 'COMPLETED', message: 'Deployed. 1 resource(s) reached Ready on the fabric.', correlation_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
  ]))
  await page.getByLabel('Service request').fill('provision service')
  await page.keyboard.press('Enter')
  await expect(page.getByText('VPWS')).toBeVisible()
  await expect(page.getByLabel('confirm-mapper')).toBeVisible()
  await expect(page.getByLabel('decline-mapper')).toBeVisible()
  await expect(page.getByText('rd')).toBeVisible()
  await expect(page.getByLabel('confirm-allocator')).toBeVisible()
  await expect(page.getByLabel('decline-allocator')).toBeVisible()
  // The conversation's last word is the OUTCOME, not "in progress".
  await expect(page.getByLabel('deployment-outcome')).toHaveText(/Deployed — 1 resource verified Ready/)
  await expect(page.getByLabel('convergence-outcomes')).toContainText('applied and verified on all nodes')
  await expect(page.getByText('Deployed. 1 resource(s) reached Ready on the fabric.')).toBeVisible()
})

test('a submission still converging is not reported as deployed', async ({ page }) => {
  await injectEvents(page)
  await page.goto('http://localhost:3000')
  await page.evaluate(() => (window as any).__injectEvents([
    { type: 'status', status: 'RECEIVED_REQUEST', thread_id: 't1b', correlation_id: 'ffffffffffffffffffffffffffffffff' },
    { type: 'stage', stage: 'deployer', status: 'PROVISIONING', payload: { submitted: [{ kind: 'Network', name: 'net-svc-alpha' }], convergence: [{ resource: 'Network/net-svc-alpha', outcome: 'timeout', ready: null, detail: 'convergence timeout after 90s' }] }, correlation_id: 'ffffffffffffffffffffffffffffffff' },
    { type: 'final', status: 'PROVISIONING', correlation_id: 'ffffffffffffffffffffffffffffffff' }
  ]))
  await page.getByLabel('Service request').fill('provision service')
  await page.keyboard.press('Enter')
  await expect(page.getByLabel('deployment-outcome')).toContainText('still converging')
  await expect(page.getByLabel('deployment-outcome')).toContainText('Ask for the status of the deployment')
})

test('a failed convergence is reported as a failure, not as progress', async ({ page }) => {
  await injectEvents(page)
  await page.goto('http://localhost:3000')
  await page.evaluate(() => (window as any).__injectEvents([
    { type: 'status', status: 'RECEIVED_REQUEST', thread_id: 't1c', correlation_id: '11111111111111111111111111111111' },
    { type: 'stage', stage: 'deployer', status: 'FAILED', payload: { submitted: [{ kind: 'Network', name: 'net-svc-alpha' }], convergence: [{ resource: 'Network/net-svc-alpha', outcome: 'failed', ready: false, detail: 'ApplyFailed: leaf2 rejected the VRF binding' }] }, correlation_id: '11111111111111111111111111111111' },
    { type: 'error', stage: 'deployer', status: 'FAILED', reason: 'deployer submitted Network/net-svc-alpha but convergence failed', correlation_id: '11111111111111111111111111111111' },
    { type: 'final', status: 'FAILED', correlation_id: '11111111111111111111111111111111' }
  ]))
  await page.getByLabel('Service request').fill('provision service')
  await page.keyboard.press('Enter')
  await expect(page.getByLabel('deployment-outcome')).toContainText('Deployment failed')
  await expect(page.getByLabel('convergence-outcomes')).toContainText('leaf2 rejected the VRF binding')
  await expect(page.getByLabel('failure-reason')).toBeVisible()
})

test('decline renders cancellation state and preserves thread id', async ({ page }) => {
  await injectEvents(page)
  await page.goto('http://localhost:3000')
  await page.evaluate(() => (window as any).__injectEvents([
    { type: 'status', status: 'RECEIVED_REQUEST', thread_id: 't2', correlation_id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
    { type: 'stage', stage: 'mapper', status: 'MAPPED', payload: { serviceType: 'L3VPN' }, correlation_id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
    { type: 'confirmation_request', stage: 'mapper', prompt: 'Confirm?', refusable: true, correlation_id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
    { type: 'error', stage: 'supervisor', status: 'FAILED', reason: 'mapper: declined', correlation_id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
    { type: 'final', status: 'FAILED', correlation_id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
  ]))
  await page.getByLabel('Service request').fill('provision service')
  await page.keyboard.press('Enter')
  await expect(page.getByText('Request cancelled')).toBeVisible()
  // Amend and continue: thread id chip shows persisted id prefix
  await expect(page.getByText('Thread:')).toBeVisible()
})

test('failure card renders operator-readable reason and correlation chip', async ({ page }) => {
  await injectEvents(page)
  await page.goto('http://localhost:3000')
  await page.evaluate(() => (window as any).__injectEvents([
    { type: 'status', status: 'RECEIVED_REQUEST', thread_id: 't3', correlation_id: 'cccccccccccccccccccccccccccccccc' },
    { type: 'error', stage: 'allocator', status: 'FAILED', reason: 'allocator payload out of contract: missing fields', correlation_id: 'cccccccccccccccccccccccccccccccc' },
    { type: 'final', status: 'FAILED', correlation_id: 'cccccccccccccccccccccccccccccccc' }
  ]))
  await page.getByLabel('Service request').fill('provision service')
  await page.keyboard.press('Enter')
  await expect(page.getByLabel('failure-reason')).toContainText('allocator payload out of contract')
  // Correlation chip shows a shortened id; clicking should not throw
  await page.getByTitle('Copy correlation id').click()
})

// Remove-service: confirmation actions are rendered on a deployer confirmation_request
// and completion/failure states render via deployer-tools stage and error cards.

test('remove-service confirmation actions render', async ({ page }) => {
  await injectEvents(page)
  await page.goto('http://localhost:3000')
  await page.evaluate(() => (window as any).__injectEvents([
    { type: 'status', status: 'RECEIVED_REQUEST', thread_id: 't4', correlation_id: 'dddddddddddddddddddddddddddddddd' },
    { type: 'confirmation_request', stage: 'deployer', prompt: 'Confirm remove?', refusable: true, correlation_id: 'dddddddddddddddddddddddddddddddd' },
    { type: 'final', status: 'PENDING', correlation_id: 'dddddddddddddddddddddddddddddddd' }
  ]))
  await page.getByLabel('Service request').fill('remove service')
  await page.keyboard.press('Enter')
  await expect(page.getByLabel('confirm-deployer')).toBeVisible()
  await expect(page.getByLabel('decline-deployer')).toBeVisible()
})

test('remove-service completion and failure states render', async ({ page }) => {
  await injectEvents(page)
  await page.goto('http://localhost:3000')
  await page.evaluate(() => (window as any).__injectEvents([
    { type: 'status', status: 'RECEIVED_REQUEST', thread_id: 't5', correlation_id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' },
    { type: 'stage', stage: 'deployer-tools', status: 'TOOLS', tool: 'remove', result: { removed: { selector: 'agentic-netops.io/correlation-id=eeeeeeeeeeeeeeee', deleted: 2 } }, correlation_id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' },
    { type: 'error', stage: 'deployer', status: 'FAILED', reason: 'remove failed on cluster permission', correlation_id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' },
    { type: 'final', status: 'FAILED', correlation_id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
  ]))
  await page.getByLabel('Service request').fill('remove service')
  await page.keyboard.press('Enter')
  await expect(page.getByLabel('tools-result-json')).toContainText('removed')
  await expect(page.getByLabel('failure-reason')).toContainText('remove failed')
})
