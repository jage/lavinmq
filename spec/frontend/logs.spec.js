import * as helpers from './helpers.js'
import { test, expect } from './fixtures.js'

test.describe('logs', _ => {
  test('are loaded', async ({ page, baseURL }) => {
    const apiLogsRequest = page.waitForRequest(/\/api\/livelog$/)
    await page.goto('/logs')
    await expect(apiLogsRequest).toBeRequested()
  })

  // Lines paint as they arrive; the shared refresh control keeps its
  // regular look on the logs page and pause/resume freeze/flush the view.
  test('lines paint immediately, pause buffers them', async ({ page }) => {
    const sse = (...events) => events.map(([id, line]) =>
      `id: ${id}\ndata: ${JSON.stringify(['INFO', 'lmq.spec', line])}\n\n`).join('')
    // EventSource reconnects when a fulfilled body ends (retry: 100ms). The
    // second connection is gated so line three arrives only once paused.
    let releaseBatch2
    const batch2Released = new Promise(resolve => { releaseBatch2 = resolve })
    let connections = 0
    await page.route(/\/api\/livelog$/, async route => {
      connections++
      let body = ''
      if (connections === 1) {
        body = 'retry: 100\n\n' + sse([1000, 'line one'], [2000, 'line two'])
      } else if (connections === 2) {
        await batch2Released
        body = sse([3000, 'line three'])
      }
      return route.fulfill({ status: 200, contentType: 'text/event-stream', body })
    })
    await page.goto('/logs')

    // The control keeps its layout (rate selector included) but switches to
    // stream mode: stream wording, no sweep. The connected state ("Live
    // stream") isn't asserted here - the mocked stream closes after each
    // batch, so it immediately reads as reconnecting.
    await expect(page.locator('#refresh-control')).toHaveClass(/realtime/)
    await expect(page.locator('#refresh-rate')).toBeVisible()
    await expect(page.locator('#refresh-toggle')).toHaveAttribute('aria-label', 'Pause log stream')
    await expect(page.locator('#refresh-toggle')).not.toHaveClass(/sweep/)

    // First batch paints as it arrives, no poll tick needed
    await expect(page.locator('#livelog-body tr')).toHaveCount(2)

    // Paused: the stream delivers line three, but nothing paints
    await page.locator('#refresh-toggle').click()
    await expect(page.locator('#refresh-control')).toHaveAttribute('title', /buffered/)
    const batch2Consumed = page.waitForRequest(/\/api\/livelog$/) // reconnect after batch 2 closes
    releaseBatch2()
    await batch2Consumed
    await expect(page.locator('#livelog-body tr')).toHaveCount(2)

    // Resume flushes the buffered line immediately
    await page.locator('#refresh-toggle').click()
    await expect(page.locator('#livelog-body tr')).toHaveCount(3)
    await expect(page.locator('#livelog-body tr').nth(2)).toContainText('line three')
  })
})
