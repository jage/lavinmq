/* global ResizeObserver MutationObserver */
import UPlot from './lib/uplot.esm.js'
import * as helpers from './helpers.js'
import * as Poller from './poller.js'

const chartColors = ['#54be7e', '#4589ff', '#d12771', '#d2a106', '#08bdba', '#bae6ff', '#ba4e00',
  '#d4bbff', '#8a3ffc', '#33b1ff', '#007d79', '#770f1c']

// Spacing of the server's *_log samples (stats_interval, 5s by default);
// independent of how often the client polls
const SAMPLE_INTERVAL = 5000

// All charts on the page, so pause/resume can refresh their legends
const handles = new Set()

Poller.events.addEventListener('change', () => {
  for (const h of handles) updateLegend(h, null)
})

function formatLabel (key) {
  const label = key.replace(/_/g, ' ').replace(/(rate|details|messages)/ig, '').trim()
    .replace(/^\w/, c => c.toUpperCase())
  return label || 'Total'
}

const SERIES_DESCRIPTIONS = {
  publish: 'Messages published into exchanges by clients',
  confirm: 'Publisher confirms — broker acks that publishes were accepted',
  deliver: 'Messages pushed to consumers (ack required)',
  deliver_no_ack: 'Messages pushed to consumers (no-ack mode)',
  get: 'Messages pulled via basic.get (ack required)',
  get_no_ack: 'Messages pulled via basic.get (no-ack mode)',
  deliver_get: 'Total outbound — all deliver + get variants including no-ack',
  ack: 'Consumer acknowledgments of delivered messages',
  redeliver: 'Messages redelivered (consumer disconnect or requeue)',
  reject: 'Messages rejected or nacked by consumers',
  return_unroutable: 'Publishes with no matching queue, returned to publisher',
  dedup: 'Duplicate publishes dropped by dedup',
  messages_ready: 'Messages waiting to be delivered',
  messages_unacked: 'Messages delivered but not yet acknowledged',
  send: 'Outbound bytes to clients',
  receive: 'Inbound bytes from clients'
}

function describeSeries (key) {
  const stripped = key.replace(/_details$|_log$/, '')
  return SERIES_DESCRIPTIONS[stripped] || ''
}

// Accepts numbers, numeric strings and details objects ({rate: n}),
// anything else becomes null so uplot renders a gap instead of NaN
function toPoint (v) {
  if (v == null) return null
  if (typeof v === 'object') v = v.rate
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

// Time of day only: the chart window spans minutes, the date is noise
// and a long label makes the card heading wrap
function fmtTimestamp (v) {
  if (v == null) return '--'
  return new Date(v * 1000).toLocaleTimeString('en-GB')
}

const preciseFormatter = new Intl.NumberFormat('en', { minimumFractionDigits: 1, maximumFractionDigits: 1, useGrouping: true })
const exactFormatter = new Intl.NumberFormat('en', { maximumFractionDigits: 20, useGrouping: true })
const BYTE_UNITS = ['B', 'KB', 'MB', 'GB', 'TB']

function scaleBytes (v) {
  const sign = v < 0 ? -1 : 1
  let val = Math.abs(v)
  let i = 0
  while (val >= 1024 && i < BYTE_UNITS.length - 1) {
    val /= 1024
    i++
  }
  return { value: sign * val, prefix: BYTE_UNITS[i] }
}

function formatLegendValue (v, unit, hideUnit) {
  if (v == null) return '--'
  if (unit === 'bytes' || unit === 'bytes/s') {
    const { value, prefix } = scaleBytes(v)
    const suffix = unit === 'bytes/s' ? '/s' : ''
    return preciseFormatter.format(value) + ' ' + prefix + suffix
  }
  const digits = preciseFormatter.format(v)
  if (hideUnit || !unit) return digits
  return digits + ' ' + unit
}

function formatLegendTitle (v, unit) {
  if (v == null) return ''
  const digits = (unit === 'bytes' || unit === 'bytes/s')
    ? Math.round(v).toLocaleString('en')
    : exactFormatter.format(v)
  return unit ? digits + ' ' + unit : digits
}

function buildLegend (handle) {
  const el = document.createElement('div')
  el.className = 'u-legend-custom'

  const timeSpan = document.createElement('span')
  timeSpan.className = 'u-legend-time'
  timeSpan.textContent = '\u00a0'

  // Place timestamp next to the h3 heading in the parent card
  const card = handle.el.closest('.card') || handle.el.parentElement
  const heading = card && card.querySelector('h3')
  if (heading) {
    heading.style.display = 'flex'
    heading.style.justifyContent = 'space-between'
    heading.style.alignItems = 'baseline'
    heading.append(timeSpan)
  } else {
    el.prepend(timeSpan)
  }

  const table = document.createElement('table')
  table.className = 'u-legend-table'
  const thead = document.createElement('thead')
  const unit = handle.config.unit
  // For byte units the prefix (MB, GB, ...) varies per row so we keep it
  // inline; for fixed units like "msgs/s" we hoist it to the header to
  // reduce per-row text churn.
  const showUnitInHeader = unit && unit !== 'bytes' && unit !== 'bytes/s'
  const unitSuffix = showUnitInHeader ? ` <span class="u-legend-th-unit">${unit}</span>` : ''
  handle.hideCellUnit = showUnitInHeader
  thead.innerHTML = `<tr><th></th><th class="u-legend-th-label">Metric</th><th class="u-legend-th-value">Current${unitSuffix}</th></tr>`
  const container = document.createElement('tbody')
  table.append(thead, container)
  el.append(table)

  handle.legendEl = el
  handle.legendGrid = container
  handle.legendTime = timeSpan
  handle.legendItems = []
}

function addLegendItem (handle, seriesIdx) {
  const color = chartColors[(seriesIdx - 1) % chartColors.length]
  const label = formatLabel(handle.seriesKeys[seriesIdx - 1])

  const item = document.createElement('tr')
  item.className = 'u-legend-item'
  item.style.cursor = 'pointer'
  const desc = describeSeries(handle.seriesKeys[seriesIdx - 1])
  if (desc) item.title = desc

  const marker = document.createElement('span')
  marker.className = 'u-legend-marker'
  marker.style.background = color

  const labelNode = document.createElement('td')
  labelNode.className = 'u-legend-label'
  labelNode.textContent = label

  const valueNode = document.createElement('td')
  valueNode.className = 'u-legend-value'
  valueNode.textContent = '--'

  const markerCell = document.createElement('td')
  markerCell.className = 'u-legend-marker-cell'
  markerCell.append(marker)
  item.append(markerCell, labelNode, valueNode)

  item.addEventListener('click', (e) => {
    if (!handle.uplot) return
    const series = handle.uplot.series
    if (e.shiftKey) {
      const show = !series[seriesIdx].show
      handle.uplot.setSeries(seriesIdx, { show })
      item.classList.toggle('u-legend-hidden', !show)
      return
    }
    const othersHidden = series.every((s, i) => i === 0 || i === seriesIdx || !s.show)
    const isolated = series[seriesIdx].show && othersHidden
    for (let i = 1; i < series.length; i++) {
      const show = isolated ? true : i === seriesIdx
      handle.uplot.setSeries(i, { show })
      const li = handle.legendItems[i]
      if (li) li.item.classList.toggle('u-legend-hidden', !show)
    }
  })
  item.addEventListener('mouseenter', () => {
    if (handle.uplot) handle.uplot.setSeries(seriesIdx, { focus: true })
  })
  item.addEventListener('mouseleave', () => {
    if (handle.uplot) handle.uplot.setSeries(null, { focus: true })
  })

  handle.legendGrid.append(item)
  handle.legendItems[seriesIdx] = { valueSpan: valueNode, item }
}

function updateLegend (handle, idx) {
  if (!handle.legendEl) return
  const data = handle.data
  const resolveIdx = idx != null ? idx : (data[0].length > 0 ? data[0].length - 1 : null)

  // Hovered point time, or the latest sample time ("Paused at" while
  // paused). Blank is a nbsp so the heading keeps a constant line box.
  if (resolveIdx == null) {
    handle.legendTime.textContent = '\u00a0'
  } else if (idx == null && Poller.isPaused()) {
    handle.legendTime.textContent = 'Paused at ' + fmtTimestamp(data[0][resolveIdx])
  } else {
    handle.legendTime.textContent = fmtTimestamp(data[0][resolveIdx])
  }

  const hideUnit = handle.hideCellUnit
  for (let i = 1; i <= handle.seriesKeys.length; i++) {
    const li = handle.legendItems[i]
    if (!li) continue
    const v = resolveIdx != null && data[i] ? data[i][resolveIdx] : null
    li.valueSpan.textContent = formatLegendValue(v, handle.config.unit, hideUnit)
    li.valueSpan.title = formatLegendTitle(v, handle.config.unit)
  }
}

function makeSeriesDef (key, color, filled) {
  return {
    label: formatLabel(key),
    stroke: color,
    width: 1.5,
    points: { show: false },
    fill: filled ? color + '40' : undefined
  }
}

function chartHeight (width) {
  return Math.round(width / 2.5)
}

// Align legend's left edge with the plot area so rows line up under the data
function alignLegend (handle) {
  if (!handle.uplot || !handle.legendEl) return
  const plotLeft = Math.round(handle.uplot.bbox.left / window.devicePixelRatio)
  handle.legendEl.style.paddingLeft = plotLeft + 'px'
}

function initChart (handle, filled) {
  const { el, config, seriesKeys, data } = handle
  const width = el.clientWidth || 400
  const height = chartHeight(width)

  const series = [{}]
  for (let i = 0; i < seriesKeys.length; i++) {
    const color = chartColors[i % chartColors.length]
    series.push(makeSeriesDef(seriesKeys[i], color, filled || config.fill))
  }

  function isDark () {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ||
      document.documentElement.classList.contains('theme-dark')
  }
  const gridColor = () => isDark() ? 'rgba(255,255,255,0.07)' : 'rgba(0,0,0,0.08)'
  const axisColor = () => isDark() ? '#777' : '#666'

  const opts = {
    width,
    height,
    padding: [null, null, null, 0],
    cursor: { show: true, drag: { x: false, y: false }, focus: { prox: 16 } },
    focus: { alpha: 0.25 },
    legend: { show: false },
    hooks: {
      setLegend: [(u) => {
        updateLegend(handle, u.legend.idx)
      }]
    },
    series,
    axes: [
      {
        stroke: axisColor,
        grid: { stroke: gridColor, dash: [2, 4] },
        ticks: { stroke: gridColor },
        space: 80,
        incrs: [1, 5, 10, 15, 30, 60, 120, 300, 600],
        values: (u, vals) => vals.map(v => new Date(v * 1000).toLocaleTimeString('en-GB'))
      },
      {
        stroke: axisColor,
        grid: { stroke: gridColor, dash: [2, 4] },
        ticks: { stroke: gridColor, size: 3 },
        values: (u, vals) => vals.map(helpers.nFormatter),
        size: 32,
        gap: 2
      }
    ],
    scales: {
      y: {
        range: (u, min, max) => [0, max > 0 ? max * 1.1 : 10]
      }
    }
  }

  if (!handle.legendEl) {
    buildLegend(handle)
    for (let i = 1; i <= seriesKeys.length; i++) {
      addLegendItem(handle, i)
    }
  }

  handle.uplot = new UPlot(opts, data, el)
  el.append(handle.legendEl)
  alignLegend(handle)

  // Observers outlive uplot instances, register them once per handle
  if (!handle.observersInit) {
    handle.observersInit = true
    initChartObservers(handle)
  }
}

function initChartObservers (handle) {
  const el = handle.el
  let lastWidth = el.clientWidth
  const ro = new ResizeObserver(() => {
    const newWidth = el.clientWidth
    if (newWidth > 0 && newWidth !== lastWidth && handle.uplot) {
      lastWidth = newWidth
      handle.uplot.setSize({ width: newWidth, height: chartHeight(newWidth) })
      alignLegend(handle)
    }
  })
  ro.observe(el)

  const redraw = () => handle.uplot && handle.uplot.redraw()
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', redraw)
  if (!window.__chartThemeObserver) {
    window.__chartThemeObserver = true
    const cbs = []
    window.__chartThemeRedrawCbs = cbs
    new MutationObserver(() => cbs.forEach(fn => fn())).observe(
      document.documentElement, { attributes: true, attributeFilter: ['class'] }
    )
  }
  window.__chartThemeRedrawCbs.push(redraw)
}

function render (id, unit, fill = false) {
  const el = document.getElementById(id)
  const graphContainer = document.createElement('div')
  graphContainer.classList.add('graph')
  el.append(graphContainer)

  const handle = {
    el: graphContainer,
    uplot: null,
    legendEl: null,
    seriesKeys: [],
    data: [[]],
    config: { unit, fill }
  }
  handles.add(handle)
  return handle
}

function logFor (data, key) {
  return data[key + '_log'] || (data[key] && data[key].log) || []
}

// Rebuild every series from the server's *_log arrays. Each poll backfills
// the full window, so chart resolution stays at the server's sample interval
// no matter how often the client polls, and a pause leaves no gap on resume.
function rebuildFromLogs (handle, data) {
  const now = Date.now() / 1000
  const logs = handle.seriesKeys.map(k => logFor(data, k))
  const maxLen = Math.max(logs.reduce((m, l) => Math.max(m, l.length), 0), 1)

  const timestamps = []
  for (let i = 0; i < maxLen; i++) {
    timestamps.push(now - (SAMPLE_INTERVAL / 1000) * (maxLen - 1 - i))
  }
  handle.data = [timestamps]

  handle.seriesKeys.forEach((key, i) => {
    const log = logs[i]
    const series = log.map(toPoint)
    // No log for this series: only the current value at the last sample
    if (log.length === 0) series.push(toPoint(data[key]))
    while (series.length < maxLen) series.unshift(null)
    handle.data.push(series)
  })
}

function update (handle, data, filled = false) {
  const allKeys = Object.keys(data)
  const hasDetails = allKeys.some(key => key.endsWith('_details'))
  const activeKeys = allKeys.filter(key => {
    if (key.endsWith('_log')) return false
    if (hasDetails && !key.endsWith('_details')) return false
    return true
  })

  let newSeriesAdded = false

  for (const key of activeKeys) {
    if (handle.seriesKeys.indexOf(key) !== -1) continue
    newSeriesAdded = true
    handle.seriesKeys.push(key)
    if (handle.legendEl) addLegendItem(handle, handle.seriesKeys.length)
  }

  rebuildFromLogs(handle, data)

  if (!handle.uplot) {
    initChart(handle, filled)
  } else if (newSeriesAdded) {
    const shown = handle.uplot.series.map(s => s.show !== false)
    handle.uplot.destroy()
    handle.uplot = null
    initChart(handle, filled)
    for (let i = 1; i < shown.length; i++) {
      if (!shown[i]) handle.uplot.setSeries(i, { show: false })
    }
  }
  handle.uplot.setData(handle.data)
  updateLegend(handle, null)
}

export {
  render, update
}
