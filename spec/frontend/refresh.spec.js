import { test, expect } from './fixtures.js'

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
