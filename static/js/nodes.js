import * as HTTP from './http.js'
import * as Chart from './chart.js'
import * as Helpers from './helpers.js'
import * as Table from './table.js'
import * as DOM from './dom.js'
import * as Poller from './poller.js'
import { DataSource } from './datasource.js'

const numFormatter = new Intl.NumberFormat()
let url = 'api/nodes'
const vhost = window.sessionStorage.getItem('vhost')
if (vhost && vhost !== '_all') {
  url += HTTP.url`?vhost=${vhost}`
}

function update (cb) {
  return HTTP.request('GET', url).then((response) => {
    render(response)
    if (cb) {
      cb(response)
    }
  })
}

function render (data) {
  document.querySelector('#version').textContent = data[0].applications[0].version
  for (const node of data) {
    updateDetails(node)
    updateStats(node)
  }
}

function start (cb) {
  Poller.start(() => update(cb))
}

const gcStatsFields = [
  { heading: 'GC cycles', key: 'gc_no', info: 'Garbage collection cycle number. The value may wrap.' },
  { heading: 'Heap size', key: 'heap_size', bytes: true, info: 'Heap size in bytes (including the area unmapped to OS).' },
  { heading: 'Free bytes', key: 'free_bytes', bytes: true, info: 'Total bytes contained in free and unmapped blocks.' },
  { heading: 'Unmapped bytes', key: 'unmapped_bytes', bytes: true, info: 'Amount of memory unmapped to the OS.' },
  { heading: 'Allocated since last GC', key: 'bytes_since_gc', bytes: true, info: 'Number of bytes allocated since the recent collection.' },
  { heading: 'Allocated before last GC', key: 'bytes_before_gc', bytes: true, info: 'Number of bytes allocated before the recent garbage collection. The value may wrap.' },
  { heading: 'Non GC bytes', key: 'non_gc_bytes', bytes: true, info: 'Number of bytes not considered candidates for garbage collection.' },
  { heading: 'Marker threads', key: 'markers_m1', info: 'Number of marker threads (excluding the initiating one), or 0 if single-threaded.' },
  { heading: 'Reclaimed since last GC', key: 'bytes_reclaimed_since_gc', bytes: true, info: 'Approximate number of reclaimed bytes after the recent garbage collection.' },
  { heading: 'Reclaimed before last GC', key: 'reclaimed_bytes_before_gc', bytes: true, info: 'Approximate number of bytes reclaimed before the recent garbage collection. The value may wrap.' },
  { heading: 'Explicitly freed since last GC', key: 'expl_freed_bytes_since_gc', bytes: true, info: 'Number of bytes freed explicitly since the recent garbage collection.' },
  { heading: 'Obtained from OS', key: 'obtained_from_os_bytes', bytes: true, info: 'Total amount of memory obtained from the OS, in bytes.' }
]

const renderGCStats = (gc) => {
  const table = document.getElementById('gc-stats-table')
  if (!table || gc === undefined) return
  while (table.firstChild) {
    table.firstChild.remove()
  }
  for (const field of gcStatsFields) {
    const value = gc[field.key]
    if (value === undefined) continue
    const row = document.createElement('tr')
    const th = document.createElement('th')
    const tooltip = document.createElement('a')
    tooltip.className = 'prop-tooltip'
    tooltip.append(document.createTextNode(field.heading))
    const icon = document.createElement('span')
    icon.className = 'tooltip-icon'
    icon.textContent = '?'
    const text = document.createElement('span')
    text.className = 'prop-tooltiptext'
    text.textContent = field.info
    tooltip.append(icon, text)
    th.append(tooltip)
    const td = document.createElement('td')
    td.textContent = field.bytes ? Helpers.formatBytes(value) : numFormatter.format(value)
    row.append(th, td)
    table.append(row)
  }
}

const refreshGCStats = () => {
  return HTTP.request('GET', 'api/nodes/gc_stats').then(renderGCStats)
}

const gcRefreshBtn = document.getElementById('gc-refresh-btn')
if (gcRefreshBtn) {
  gcRefreshBtn.addEventListener('click', () => {
    gcRefreshBtn.disabled = true
    refreshGCStats().finally(() => { gcRefreshBtn.disabled = false })
  })
}

const gcBtn = document.getElementById('gc-btn')
if (gcBtn) {
  gcBtn.addEventListener('click', () => {
    gcBtn.disabled = true
    HTTP.request('POST', 'api/nodes/gc_collect')
      .then(() => {
        DOM.toast('Garbage collection triggered')
        return refreshGCStats()
      })
      .finally(() => { gcBtn.disabled = false })
  })
  // Only admins may read GC stats; the gc-btn element is in the DOM for all
  // users (require-administrator only hides it via CSS), so fetching here
  // unconditionally would 403 for non-admins and pop up an error. Gate the
  // initial load on the (persisted, synchronously applied) admin role class;
  // afterwards fetch only on demand.
  if (Helpers.stateClasses.has('user-is-administrator')) {
    refreshGCStats()
  }
}

// Filled bar with a text line under it; the optional watermark renders as
// a tick on the bar and turns the fill red once usage passes it
const usageMeter = (used, total, text, watermark) => {
  const meter = document.createElement('div')
  meter.className = 'usage-meter'
  const bar = document.createElement('div')
  bar.className = 'usage-bar'
  const fill = document.createElement('div')
  fill.className = 'usage-bar-fill'
  const fraction = total > 0 ? Math.min(used / total, 1) : 0
  fill.style.width = (fraction * 100).toFixed(2) + '%'
  bar.append(fill)
  if (watermark && total > 0 && watermark.at <= total) {
    const mark = document.createElement('span')
    mark.className = 'usage-bar-mark'
    mark.style.left = (watermark.at / total * 100).toFixed(2) + '%'
    mark.title = watermark.title
    bar.append(mark)
  }
  if (watermark && used >= watermark.at) meter.dataset.severity = 'alarm'
  else if (fraction >= 0.9) meter.dataset.severity = 'high'
  const label = document.createElement('small')
  label.textContent = text
  meter.append(bar, label)
  return meter
}

const pcnt = (fraction) => (fraction * 100).toFixed(1) + '%'

const updateDetails = (nodeStats) => {
  document.getElementById('tr-name').textContent = nodeStats.name
  document.getElementById('tr-uptime').textContent = Helpers.duration((nodeStats.uptime / 1000).toFixed(0))
  document.getElementById('tr-vcpu').textContent = nodeStats.processors || 'N/A'
  let memUsage = 'N/A'
  let cpuUsage = 'N/A'
  let diskUsage = 'N/A'

  if (nodeStats.mem_used !== undefined) {
    // mem_limit is the memory watermark: cgroup limit or physical memory
    const text = `${Helpers.formatBytes(nodeStats.mem_used)} of ${Helpers.formatBytes(nodeStats.mem_limit)} watermark (${pcnt(nodeStats.mem_used / nodeStats.mem_limit)})`
    memUsage = usageMeter(nodeStats.mem_used, nodeStats.mem_limit, text)
  }
  document.getElementById('tr-memory').replaceChildren(memUsage)
  if (nodeStats.cpu_user_time !== undefined) {
    cpuUsage = pcnt((nodeStats.cpu_user_time + nodeStats.cpu_sys_time) / nodeStats.uptime)
  }
  document.getElementById('tr-cpu').textContent = cpuUsage
  if (nodeStats.disk_total !== undefined) {
    const used = nodeStats.disk_total - nodeStats.disk_free
    let text = `${Helpers.formatBytes(used)} of ${Helpers.formatBytes(nodeStats.disk_total)} (${pcnt(used / nodeStats.disk_total)}), ${Helpers.formatBytes(nodeStats.disk_free)} free`
    let watermark
    if (nodeStats.disk_free_limit !== undefined) {
      text += `, watermark ${Helpers.formatBytes(nodeStats.disk_free_limit)}`
      watermark = {
        at: nodeStats.disk_total - nodeStats.disk_free_limit,
        title: `Flow stops when free space drops below ${Helpers.formatBytes(nodeStats.disk_free_limit)}`
      }
    }
    diskUsage = usageMeter(used, nodeStats.disk_total, text, watermark)
  }
  document.getElementById('tr-disk').replaceChildren(diskUsage)
}

const stats = [
  {
    heading: 'Connection',
    content: [
      {
        heading: 'Created',
        key: 'connection_created'
      },
      {
        heading: 'Closed',
        key: 'connection_closed'
      }
    ]
  },
  {
    heading: 'Channels',
    content: [
      {
        heading: 'Created',
        key: 'channel_created'
      },
      {
        heading: 'Closed',
        key: 'channel_closed'
      }
    ]
  },
  {
    heading: 'Queues',
    content: [
      {
        heading: 'Declared',
        key: 'queue_declared'
      },
      {
        heading: 'Deleted',
        key: 'queue_deleted'
      }
    ]
  },
  {
    heading: 'File descriptors',
    content: [
      {
        heading: 'Used',
        key: 'fd_used'
      },
      {
        heading: 'Total',
        key: 'fd_total'
      }
    ]
  },
  {
    heading: 'Messages',
    content: [
      {
        heading: 'Ready',
        key: 'messages_ready'
      },
      {
        heading: 'Unacknowledged',
        key: 'messages_unacknowledged'
      }
    ]
  }
]

const updateStats = (nodeStats) => {
  const table = document.getElementById('stats-table')
  while (table.firstChild) {
    table.firstChild.remove()
  }

  for (const rowStats of stats) {
    const row = document.createElement('tr')
    const th = document.createElement('th')
    th.textContent = rowStats.heading
    row.append(th)
    let metrics = 0
    for (const items of rowStats.content) {
      if (nodeStats[items.key] !== undefined) {
        const td = document.createElement('td')
        td.textContent = items.heading + ': ' + numFormatter.format(nodeStats[items.key])
        row.append(td)
        metrics += 1
      }
    }
    if (metrics > 0) {
      table.append(row)
    }
  }
}
const memoryChart = Chart.render('memoryChart', 'bytes', true)
const diskChart = Chart.render('diskChart', 'bytes', true)
const ioChart = Chart.render('ioChart', 'ops')
const cpuChart = Chart.render('cpuChart', '%', true)
const connectionChurnChart = Chart.render('connectionChurnChart', '/s')
const channelChurnChart = Chart.render('channelChurnChart', '/s')
const queueChurnChart = Chart.render('queueChurnChart', '/s')

const followersDataSource = new (class extends DataSource {
  constructor () { super({ autoReload: false, useQueryState: false }) }
  update (items) { this.items = items }
  reload () { }
})()
const followersTableOpts = {
  dataSource: followersDataSource,
  keyColumns: ['id'],
  countId: 'followers-count'
}
Table.renderTable('followers', followersTableOpts, (tr, item, firstRender) => {
  if (firstRender) {
    Table.renderCell(tr, 0, item.id)
  }
  Table.renderCell(tr, 1, item.remote_address)
  Table.renderCell(tr, 2, Helpers.formatBytes(item.sent_bytes), 'right')
  Table.renderCell(tr, 3, Helpers.formatBytes(item.acked_bytes), 'right')
  Table.renderCell(tr, 4, Helpers.formatBytes(item.sent_bytes - item.acked_bytes), 'right')
})

function updateCharts (response) {
  if (response[0].mem_used !== undefined) {
    const memoryStats = {
      mem_used_details: response[0].mem_used,
      mem_used_details_log: response[0].mem_used_details.log
    }
    Chart.setScale(memoryChart, { refMax: response[0].mem_limit })
    Chart.update(memoryChart, memoryStats)
  }
  if (response[0].disk_total !== undefined) {
    const totalLog = response[0].disk_total_details.log
    const freeLog = response[0].disk_free_details.log
    const diskStats = {
      disk_used_details: response[0].disk_total - response[0].disk_free,
      disk_used_details_log: freeLog.map((free, i) => (totalLog[i] ?? response[0].disk_total) - free)
    }
    Chart.setScale(diskChart, { refMax: response[0].disk_total })
    Chart.update(diskChart, diskStats)
  }
  if (response[0].io_write_details !== undefined) {
    const ioStats = {
      io_write_details: response[0].io_write_details.log.slice(-1)[0],
      io_write_details_log: response[0].io_write_details.log,
      io_read_details: response[0].io_read_details.log.slice(-1)[0],
      io_read_details_log: response[0].io_read_details.log
    }
    Chart.update(ioChart, ioStats)
  }

  if (response[0].cpu_user_details !== undefined) {
    const cpuStats = {
      user_time_details: response[0].cpu_user_details.log.slice(-1)[0] * 100,
      system_time_details: response[0].cpu_sys_details.log.slice(-1)[0] * 100,
      user_time_details_log: response[0].cpu_user_details.log.map(x => x * 100),
      system_time_details_log: response[0].cpu_sys_details.log.map(x => x * 100)
    }
    // Fixed to total CPU capacity (cores × 100%) so usage reads relative to
    // the machine; user+sys is per-core, so it can climb toward this ceiling.
    Chart.setScale(cpuChart, { fixedMax: (response[0].processors || 1) * 100 })
    Chart.update(cpuChart, cpuStats, true)
  }

  if (response[0].connection_created_details !== undefined) {
    const connectionChurnStats = {
      connection_created_details: response[0].connection_created_details.rate,
      connection_closed_details: response[0].connection_closed_details.rate,
      connection_created_details_log: response[0].connection_created_details.log,
      connection_closed_details_log: response[0].connection_closed_details.log
    }
    Chart.update(connectionChurnChart, connectionChurnStats)
  }
  if (response[0].channel_created_details !== undefined) {
    const channelChurnStats = {
      channel_created_details: response[0].channel_created_details.rate,
      channel_closed_details: response[0].channel_closed_details.rate,
      channel_created_details_log: response[0].channel_created_details.log,
      channel_closed_details_log: response[0].channel_closed_details.log
    }
    Chart.update(channelChurnChart, channelChurnStats)
  }
  if (response[0].queue_declared_details !== undefined) {
    const queueChurnStats = {
      queue_declared_details: response[0].queue_declared_details.rate,
      queue_deleted_details: response[0].queue_deleted_details.rate,
      queue_declared_details_log: response[0].queue_declared_details.log,
      queue_deleted_details_log: response[0].queue_deleted_details.log
    }
    Chart.update(queueChurnChart, queueChurnStats)
  }
  followersDataSource.update(response[0].followers)
}

start(updateCharts)
