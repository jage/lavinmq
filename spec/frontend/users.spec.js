import * as helpers from './helpers.js'
import { test, expect } from './fixtures.js'

test.describe('users', _ => {
  test('are loaded', async ({ page, baseURL }) => {
    const apiUsersRequest = helpers.waitForPathRequest(page, '/api/users')
    await page.goto('/users')
    await expect(apiUsersRequest).toBeRequested()
  })

  test('are refreshed automatically', async ({ page, apimap }) => {
    apimap.get('/api/permissions', [])
    apimap.get('/api/users', [])
    await page.clock.install()
    await page.goto('/users')
    // Verify repeated requests are made over time
    for (let i = 0; i < 3; i++) {
      const apiUsersRequest = helpers.waitForPathRequest(page, '/api/users')
      await page.clock.runFor(10000) // advance time by 10 seconds
      await expect(apiUsersRequest).toBeRequested()
    }
  })
})
