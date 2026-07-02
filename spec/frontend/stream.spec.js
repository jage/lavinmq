import { test, expect } from './fixtures.js'

test.describe('stream', _ => {
  const streamName = 'foo-stream'
  const streamVhost = '/'

  const consumers = [
    { queue: { name: streamName, vhost: streamVhost }, consumer_tag: 'stream_consumer', exclusive: false, ack_required: true, prefetch_count: 1000, priority: 0, channel_details: { peer_host: '127.0.0.1', peer_port: 56861, connection_name: 'conn_name', user: 'guest', number: 1, name: 'channel_name' } }
  ]

  const emptyStat = { rate: 0.0, log: [] }
  const messageStats = Object.fromEntries(
    ['ack', 'deliver', 'deliver_get', 'confirm', 'get', 'get_no_ack', 'publish', 'redeliver', 'reject', 'return_unroutable', 'dedup'].flatMap(k =>
      [[k, 0], [`${k}_details`, emptyStat]]
    )
  )

  const streamResponse = {
    name: streamName,
    durable: true,
    exclusive: false,
    auto_delete: false,
    arguments: { 'x-queue-type': 'stream' },
    consumers: 1,
    vhost: streamVhost,
    messages: 132,
    total_bytes: 4224,
    messages_persistent: 132,
    ready: 132,
    messages_ready: 132,
    messages_ready_details: { log: [120, 128, 132] },
    ready_bytes: 4224,
    message_bytes_ready: 4224,
    ready_avg_bytes: 32,
    unacked: 0,
    messages_unacknowledged: 0,
    messages_unacknowledged_details: { log: [0, 0, 0] },
    unacked_bytes: 0,
    message_bytes_unacknowledged: 0,
    unacked_avg_bytes: 0,
    state: 'running',
    effective_policy_definition: {},
    message_stats: messageStats,
    effective_arguments: [],
    consumer_details: consumers
  }

  const bindingResponse = {
    items: [],
    filtered_count: 0,
    item_count: 0,
    page: 1,
    page_count: 1,
    page_size: 100,
    total_count: 0
  }

  test.beforeEach(async ({ apimap, page }) => {
    const streamLoaded = apimap.get(`/api/queues/${encodeURIComponent(streamVhost)}/${streamName}`, streamResponse)
    const bindingsLoaded = apimap.get(`/api/queues/${encodeURIComponent(streamVhost)}/${streamName}/bindings`, bindingResponse)
    await page.goto(`/stream#vhost=${encodeURIComponent(streamVhost)}&name=${streamName}`)
    await Promise.all([streamLoaded, bindingsLoaded])
  })

  test('stream is loaded', async ({ page }) => {
    await expect(page.locator('#pagename-label')).toHaveText(new RegExp(`${streamName} .* ${streamVhost}`))
    await expect(page.locator('#q-total')).toHaveText('132')
  })

  test('messages in stream chart shows current count', async ({ page }) => {
    const legend = page.locator('#msgChart .u-legend-item')
    await expect(legend).toHaveCount(1)
    await expect(legend).toContainText('Total')
    await expect(legend).toContainText('132 msgs')
  })
})
