import * as helpers from './helpers.js'
import { test, expect } from './fixtures.js'

test.describe('nodes', _ => {
  test('are loaded', async ({ page, baseURL }) => {
    const apiNodesRequest = helpers.waitForPathRequest(page, '/api/nodes')
    await page.goto('/nodes')
    await expect(apiNodesRequest).toBeRequested()
  })

  test('are refreshed automatically', async ({ page }) => {
    await page.clock.install()
    await page.goto('/nodes')
    // Verify that at least 3 requests are made
    for (let i = 0; i < 3; i++) {
      const apiNodesRequest = helpers.waitForPathRequest(page, '/api/nodes')
      await page.clock.runFor(10000) // advance time by 10 seconds
      await expect(apiNodesRequest).toBeRequested()
    }
  })

  test('render memory and disk usage meters with watermark', async ({ page }) => {
    const node = {
      name: 'spec-node',
      uptime: 60000,
      processors: 2,
      applications: [{ version: '0.0.0' }],
      mem_used: 512 * 1024 ** 2, // 512 MiB
      mem_limit: 2 * 1024 ** 3, // 2 GiB watermark
      disk_total: 10 * 1024 ** 3, // 10 GiB
      disk_free: 8 * 1024 ** 3, // 8 GiB free -> 2 GiB used
      disk_free_limit: 1024 ** 3, // 1 GiB watermark
      followers: []
    }
    const apiNodesRequest = helpers.waitForPathRequest(page, '/api/nodes', { response: [node] })
    await page.goto('/nodes')
    await expect(apiNodesRequest).toBeRequested()

    const memory = page.locator('#tr-memory')
    await expect(memory.locator('.usage-meter small')).toHaveText('512 MiB of 2 GiB watermark (25.0%)')
    await expect(memory.locator('.usage-bar-fill')).toHaveCSS('width', /px/)

    const disk = page.locator('#tr-disk')
    await expect(disk.locator('.usage-meter small')).toHaveText('2 GiB of 10 GiB (20.0%), 8 GiB free, watermark 1 GiB')
    // Watermark tick sits where free space would hit the limit: 9/10 of the bar
    await expect(disk.locator('.usage-bar-mark')).toHaveAttribute('style', /left: 90(\.0+)?%/)
  })
})
