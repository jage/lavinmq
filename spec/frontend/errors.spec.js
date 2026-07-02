import { test, expect } from './fixtures.js'

// clock.runFor advances mocked time instantly; request/route events still
// travel over CDP in real time, so settle before asserting nothing arrived
const settled = () => new Promise(resolve => setTimeout(resolve, 300))

test.describe('error handling', _ => {
  test('403 on a polled table stops auto-reload and shows an access message, no dialogs', async ({ page }) => {
    await page.clock.install()
    let requests = 0
    let dialogs = 0
    page.on('dialog', async dialog => { dialogs++; await dialog.dismiss() })
    page.on('request', req => { if (/\/api\/users(\?|$)/.test(req.url())) requests++ })
    await page.route(/\/api\/(users|permissions)(\?|$)/, route =>
      route.fulfill({ status: 403, json: { reason: 'Access refused' } }))
    await page.goto('/users')

    await expect(page.locator('#users-error')).toContainText(/Access refused|administrator role/)
    await page.clock.runFor(15_000)
    await settled()
    expect(requests).toBe(1)
    expect(dialogs).toBe(0)
  })

  test('5xx on a user action shows an error toast, not a dialog', async ({ page }) => {
    let dialogs = 0
    page.on('dialog', async dialog => { dialogs++; await dialog.dismiss() })
    await page.route(/\/api\/queues\/[^/]+\/spec-q$/, route =>
      route.fulfill({ status: 500, json: { reason: 'disk on fire' } }))
    await page.goto('/queues')

    await page.locator('#declare input[name="name"]').fill('spec-q')
    await page.locator('#declare button[type="submit"]').click()
    await expect(page.locator('.toast.error')).toContainText('disk on fire')
    expect(dialogs).toBe(0)
  })

  test('5xx table reload shows readable banner text', async ({ page }) => {
    await page.route(/\/api\/queues(\?|$)/, route =>
      route.fulfill({ status: 500, json: { reason: 'db on fire' } }))
    await page.goto('/queues')

    await expect(page.locator('#table-error')).toContainText('db on fire')
    await expect(page.locator('#table-error')).not.toContainText('object Object')
  })

  test('poll 5xx feeds the status tooltip with readable text', async ({ page }) => {
    await page.route(/\/api\/overview(\?|$)/, route =>
      route.fulfill({ status: 500, json: { reason: 'nope' } }))
    await page.goto('/')

    await expect(page.locator('#refresh-control')).toHaveAttribute('title', /Last error: .+/)
    await expect(page.locator('#refresh-control')).not.toHaveAttribute('title', /object Object/)
  })
})
