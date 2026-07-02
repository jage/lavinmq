import * as helpers from './helpers.js'
import { test, expect } from './fixtures.js'

// clock.runFor advances mocked time instantly; request/route events still
// travel over CDP in real time, so settle before asserting nothing arrived
const settled = () => new Promise(resolve => setTimeout(resolve, 300))

test.describe('refresh control', _ => {
  test('selected rate is persisted across reload', async ({ page }) => {
    await page.goto('/')
    await page.locator('#refresh-rate').selectOption('30000')
    await expect(page.locator('#refresh-rate')).toHaveValue('30000')
    expect(await page.evaluate(() => window.localStorage.getItem('lmq.refreshInterval'))).toBe('30000')
    await page.reload()
    await expect(page.locator('#refresh-rate')).toHaveValue('30000')
  })

  test('pause stops polling and resume fetches immediately', async ({ page }) => {
    await page.clock.install()
    let requests = 0
    page.on('request', req => {
      if (req.url().includes('/api/overview')) requests++
    })
    await page.goto('/')
    await expect.poll(() => requests).toBeGreaterThan(0)

    await page.clock.runFor(12_000)
    await expect.poll(() => requests).toBeGreaterThan(2)

    await page.locator('#refresh-toggle').click()
    await expect(page.locator('#refresh-control')).toHaveAttribute('data-state', 'paused')
    await expect(page.locator('#refresh-toggle')).toHaveAttribute('aria-pressed', 'true')
    await expect(page.locator('#refresh-control')).toHaveAttribute('title', /Paused/)

    const pausedAt = requests
    await page.clock.fastForward(60_000)
    expect(requests).toBe(pausedAt)

    await page.locator('#refresh-toggle').click()
    await expect(page.locator('#refresh-control')).not.toHaveAttribute('data-state', 'paused')
    await expect.poll(() => requests).toBeGreaterThan(pausedAt)
  })

  test('pause follows along across page loads', async ({ page }) => {
    await page.clock.install()
    let requests = 0
    page.on('request', req => {
      if (req.url().includes('/api/overview')) requests++
    })
    await page.goto('/')
    await page.locator('#refresh-toggle').click()
    await page.reload()
    await expect(page.locator('#refresh-control')).toHaveAttribute('data-state', 'paused')
    // The page still fetches once on load so it isn't blank...
    await expect.poll(() => requests).toBeGreaterThan(1)
    // ...but polling stays off
    const afterLoad = requests
    await page.clock.runFor(12_000)
    expect(requests).toBe(afterLoad)
    await page.locator('#refresh-toggle').click()
    await page.reload()
    await expect(page.locator('#refresh-control')).not.toHaveAttribute('data-state', 'paused')
  })

  test('network reconnect while the tab is hidden does not resume polling', async ({ page, context }) => {
    await page.clock.install()
    let requests = 0
    page.on('request', req => {
      if (req.url().includes('/api/overview')) requests++
    })
    await page.goto('/')
    await expect.poll(() => requests).toBeGreaterThan(0)

    await helpers.setPageVisibility(page, false)
    const hiddenAt = requests
    // Connectivity comes back while the tab stays hidden
    await context.setOffline(true)
    await context.setOffline(false)
    await page.clock.runFor(30_000)
    await settled()
    expect(requests).toBe(hiddenAt)

    await helpers.setPageVisibility(page, true)
    await expect.poll(() => requests).toBeGreaterThan(hiddenAt)
  })

  test('page loaded hidden while paused fetches once when shown', async ({ page }) => {
    await page.clock.install()
    let requests = 0
    page.on('request', req => {
      if (req.url().includes('/api/overview')) requests++
    })
    await page.addInitScript(() => {
      window.sessionStorage.setItem('lmq.refreshPaused', 'true')
      Object.defineProperty(document, 'hidden', { value: true, configurable: true })
      Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    })
    await page.goto('/')
    await page.clock.runFor(6_000)
    await settled()
    expect(requests).toBe(0)

    // Shown: the deferred initial fetch happens so the page isn't blank...
    await helpers.setPageVisibility(page, true)
    await expect.poll(() => requests).toBe(1)
    // ...but the user pause still holds
    await page.clock.runFor(12_000)
    await settled()
    expect(requests).toBe(1)
  })

  test('page loaded while offline starts polling on reconnect', async ({ page }) => {
    await page.clock.install()
    let requests = 0
    page.on('request', req => {
      if (req.url().includes('/api/overview')) requests++
    })
    await page.addInitScript(() => {
      Object.defineProperty(navigator, 'onLine', { value: false, configurable: true })
    })
    await page.goto('/')
    // The initial fetch is attempted (feeds the status dot), but no polling
    await expect.poll(() => requests).toBe(1)
    await page.clock.runFor(15_000)
    await settled()
    expect(requests).toBe(1)

    await page.evaluate(() => {
      Object.defineProperty(navigator, 'onLine', { value: true, configurable: true })
      window.dispatchEvent(new Event('online'))
    })
    await expect.poll(() => requests).toBeGreaterThan(1)
  })

  test('a slow response is not overlapped by the next tick', async ({ page }) => {
    await page.clock.install()
    let total = 0
    let release
    const gate = new Promise(resolve => { release = resolve })
    await page.route(/\/api\/overview/, async route => {
      total++
      if (total === 1) await gate
      await route.fulfill({ json: { object_totals: {}, uptime: 0, message_stats: {}, queue_totals: {} } })
    })
    await page.goto('/')
    await expect.poll(() => total).toBe(1)

    // Three ticks pass while the first response is still in flight
    await page.clock.runFor(15_000)
    await settled()
    expect(total).toBe(1)

    release()
    await page.clock.runFor(5_000)
    await expect.poll(() => total).toBe(2)
  })

  test('pages that never auto-refresh show a static, inert control', async ({ page }) => {
    // Error pages include the header but register no poller, so the control
    // should say it won't refresh instead of looking live.
    await page.goto('/404.html')
    await expect(page.locator('#refresh-control')).toHaveAttribute('data-state', 'static')
    await expect(page.locator('#refresh-control')).toHaveAttribute('title', /doesn't auto-refresh/)
    await expect(page.locator('#refresh-rate')).toBeHidden()
    await expect(page.locator('#refresh-toggle')).toBeDisabled()
  })

  test('chart timestamp shows latest sample and pause state', async ({ page }) => {
    await page.goto('/')
    const legendTime = page.locator('.u-legend-time').first()
    await expect(legendTime).toBeAttached()
    await expect(legendTime).toHaveText(/^\d{2}:\d{2}:\d{2}$/)
    await page.locator('#refresh-toggle').click()
    await expect(legendTime).toContainText('Paused at')
    await page.locator('#refresh-toggle').click()
    await expect(legendTime).toHaveText(/^\d{2}:\d{2}:\d{2}$/)
  })
})
