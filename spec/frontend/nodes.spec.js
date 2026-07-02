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
      mem_used_details: { log: [400 * 1024 ** 2, 512 * 1024 ** 2] },
      mem_limit: 2 * 1024 ** 3, // 2 GiB capacity
      disk_total: 10 * 1024 ** 3, // 10 GiB
      disk_total_details: { log: [10 * 1024 ** 3, 10 * 1024 ** 3] },
      disk_free: 8 * 1024 ** 3, // 8 GiB free -> 2 GiB used
      disk_free_details: { log: [9 * 1024 ** 3, 8 * 1024 ** 3] },
      followers: []
    }
    const apiNodesRequest = helpers.waitForPathRequest(page, '/api/nodes', { response: [node] })
    await page.goto('/nodes')
    await expect(apiNodesRequest).toBeRequested()

    await expect(page.locator('#tr-memory')).toHaveText('512 MiB of 2 GiB (25.0%)')
    await expect(page.locator('#tr-disk')).toHaveText('2 GiB of 10 GiB (20.0%), 8 GiB free')

    // The charts consume the same response; their legends carry the values
    const memLegend = page.locator('#memoryChart .u-legend-item')
    await expect(memLegend).toHaveCount(1)
    await expect(memLegend).toContainText('512 MiB')
    const diskLegend = page.locator('#diskChart .u-legend-item')
    await expect(diskLegend).toHaveCount(1)
    await expect(diskLegend).toContainText('2 GiB')
  })
})
