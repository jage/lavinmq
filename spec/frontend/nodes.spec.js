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

  test('render memory and disk usage details', async ({ page }) => {
    const node = {
      name: 'spec-node',
      uptime: 60000,
      processors: 2,
      applications: [{ version: '0.0.0' }],
      mem_used: 512 * 1024 ** 2, // 512 MiB
      mem_limit: 2 * 1024 ** 3, // 2 GiB capacity
      disk_total: 10 * 1024 ** 3, // 10 GiB
      disk_free: 8 * 1024 ** 3, // 8 GiB free -> 2 GiB used
      followers: []
    }
    const apiNodesRequest = helpers.waitForPathRequest(page, '/api/nodes', { response: [node] })
    await page.goto('/nodes')
    await expect(apiNodesRequest).toBeRequested()

    await expect(page.locator('#tr-memory')).toHaveText('512 MiB of 2 GiB (25.0%)')
    await expect(page.locator('#tr-disk')).toHaveText('2 GiB of 10 GiB (20.0%), 8 GiB free')
  })
})
