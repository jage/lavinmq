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

// Spelled-out names where the metric key is abbreviated
const SERIES_NAMES = {
  mem_used: 'Memory used',
  io_write: 'Write',
  io_read: 'Read'
}

function formatLabel (key) {
  const stripped = key.replace(/_details$|_log$/, '')
  if (SERIES_NAMES[stripped]) return SERIES_NAMES[stripped]
  const label = stripped.replace(/_/g, ' ').replace(/(rate|messages)/ig, '').trim()
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
  messages_unacknowledged: 'Messages delivered but not yet acknowledged',
  mem_used: 'Resident memory used by the LavinMQ process',
  disk_used: 'Disk space used on the data directory filesystem',
  io_read: 'Blocks read from disk by the process (filesystem input)',
  io_write: 'Blocks written to disk by the process (filesystem output)',
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
// IEC units (1024-based) all the way, matching the rest of the UI
const BYTE_UNITS = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB']

function byteUnitIndex (v) {
  let val = Math.abs(v)
  let i = 0
  while (val >= 1024 && i < BYTE_UNITS.length - 1) {
    val /= 1024
    i++
  }
  return i
}

// Pass unitIdx to force a prefix so all rows of a legend share one scale
function scaleBytes (v, unitIdx) {
  const i = unitIdx != null ? unitIdx : byteUnitIndex(v)
  return { value: v / 1024 ** i, prefix: BYTE_UNITS[i] }
}

function isByteUnit (unit) {
  return unit === 'bytes' || unit === 'bytes/s'
}

// Integers print bare (a count can't be half a message), fractions get one
// steady decimal
function formatDigits (v) {
  return Number.isInteger(v) ? exactFormatter.format(v) : preciseFormatter.format(v)
}

function formatLegendValue (v, unit, byteIdx) {
  if (v == null) return '--'
  if (isByteUnit(unit)) {
    const { value, prefix } = scaleBytes(v, byteIdx)
    const suffix = unit === 'bytes/s' ? '/s' : ''
    // A shared prefix can shrink small values: give them extra precision
    const digits = value !== 0 && Math.abs(value) < 1 ? value.toFixed(2) : formatDigits(value)
    return digits + ' ' + prefix + suffix
  }
  const digits = formatDigits(v)
  if (!unit) return digits
  // No space before units that read as part of the number ("12.3%", "0.6/s")
  const sep = (unit === '%' || unit.startsWith('/')) ? '' : ' '
  return digits + sep + unit
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
  const container = document.createElement('tbody')
  table.append(container)
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

  // All rows share the prefix of the largest current value, so 2.2 KiB/s
  // and 43 B/s read as 2.2 and 0.04 KiB/s - same scale, directly comparable
  let byteIdx = null
  if (isByteUnit(handle.config.unit) && resolveIdx != null) {
    let maxV = 0
    for (let i = 1; i <= handle.seriesKeys.length; i++) {
      const v = data[i] ? data[i][resolveIdx] : null
      if (v != null) maxV = Math.max(maxV, Math.abs(v))
    }
    byteIdx = byteUnitIndex(maxV)
  }

  for (let i = 1; i <= handle.seriesKeys.length; i++) {
    const li = handle.legendItems[i]
    if (!li) continue
    const v = resolveIdx != null && data[i] ? data[i][resolveIdx] : null
    li.valueSpan.textContent = formatLegendValue(v, handle.config.unit, byteIdx)
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

// Y max snaps up to a coarse "nice" step and only shrinks once the data has
// stayed well below the scale for several polls: a spike grows the axis
// instantly, but the scale neither wobbles with every sample nor snaps back
// the moment the spike slides out of the window.
const SCALE_STEPS = [1, 1.5, 2, 3, 5, 7.5, 10]
const SHRINK_RATIO = 0.6
const SHRINK_POLLS = 5

function niceCeil (v) {
  const mag = 10 ** Math.floor(Math.log10(v))
  return SCALE_STEPS.find(s => v <= s * mag) * mag
}

function stableMaxRange (handle) {
  return (u, min, max) => {
    // A fixed max (e.g. CPU at cores×100%) pins the axis so usage reads
    // relative to capacity, but still grows if a sample ever exceeds it.
    if (handle.fixedMax > 0) {
      return [0, max > handle.fixedMax ? niceCeil(max * 1.05) : handle.fixedMax]
    }
    // Once usage passes half the capacity, expand the axis to the capacity so
    // the limit line and remaining headroom come into view; below that, stay
    // zoomed to the data for detail.
    const cap = handle.refMax
    let target = max > 0 ? niceCeil(max * 1.05) : 0
    if (cap > 0 && max > cap / 2) target = niceCeil(cap)
    let scaleMax = handle.scaleMax || 0
    if (target > scaleMax) {
      scaleMax = target
      handle.shrinkCount = 0
    } else if (target < scaleMax * SHRINK_RATIO) {
      if (++handle.shrinkCount >= SHRINK_POLLS) {
        scaleMax = target
        handle.shrinkCount = 0
      }
    } else {
      handle.shrinkCount = 0
    }
    handle.scaleMax = scaleMax
    return [0, scaleMax > 0 ? scaleMax : 10]
  }
}

function prefersDark () {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ||
    document.documentElement.classList.contains('theme-dark')
}

// Pin a fixed axis max (CPU) or a capacity reference line (memory, disk).
// Set before each update; the following setData picks them up on redraw.
function setScale (handle, { fixedMax = null, refMax = null } = {}) {
  handle.fixedMax = fixedMax
  handle.refMax = refMax
}

// Dashed line at a capacity (memory limit, disk total). The axis stays zoomed
// to the data for detail, so the line only comes into view as usage climbs
// toward the limit - which is exactly when the headroom matters.
function drawRefLine (u, handle) {
  const v = handle.refMax
  if (!(v > 0) || v > u.scales.y.max) return
  const ctx = u.ctx
  const dpr = window.devicePixelRatio
  const y = Math.round(u.valToPos(v, 'y', true)) + 0.5
  const left = u.bbox.left
  const right = u.bbox.left + u.bbox.width
  ctx.save()
  ctx.strokeStyle = prefersDark() ? 'rgba(255,120,120,0.75)' : 'rgba(200,40,40,0.6)'
  ctx.lineWidth = dpr
  ctx.setLineDash([4 * dpr, 4 * dpr])
  ctx.beginPath()
  ctx.moveTo(left, y)
  ctx.lineTo(right, y)
  ctx.stroke()
  ctx.setLineDash([])
  ctx.fillStyle = ctx.strokeStyle
  ctx.font = `${10 * dpr}px sans-serif`
  ctx.textAlign = 'right'
  ctx.textBaseline = 'bottom'
  ctx.fillText('limit', right - 4 * dpr, y - 2 * dpr)
  ctx.restore()
}

// Align legend's left edge with the plot area so rows line up under the data.
// Re-checked on every draw since the y-axis width adapts to its tick labels.
function alignLegend (handle) {
  if (!handle.uplot || !handle.legendEl) return
  const plotLeft = Math.round(handle.uplot.bbox.left / window.devicePixelRatio)
  if (plotLeft !== handle.legendPad) {
    handle.legendPad = plotLeft
    handle.legendEl.style.paddingLeft = plotLeft + 'px'
  }
}

// Fit the y-axis to its widest tick label so idle charts ("0", "10") give the
// width back to the plot and busy ones ("999.5K") don't clip. Quantized to
// 8px steps so the plot edge doesn't wobble on every scale change.
function yAxisSize (u, values, axisIdx, cycleNum) {
  const axis = u.axes[axisIdx]
  if (cycleNum > 1) return axis._size
  let textWidth = 0
  if (values) {
    u.ctx.font = axis.font[0]
    for (const v of values) {
      textWidth = Math.max(textWidth, u.ctx.measureText(v).width)
    }
  }
  const size = axis.ticks.size + axis.gap + textWidth / window.devicePixelRatio
  return Math.max(24, Math.ceil(size / 8) * 8)
}

// Byte axes split on powers of two so tick labels come out round in IEC
// units (32 MiB, 64 MiB) instead of decimal-round raw bytes (47.7 MiB)
const BYTE_INCRS = (() => {
  const incrs = []
  for (let p = 0; p < 5; p++) {
    for (const m of [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]) {
      incrs.push(m * 1024 ** p)
    }
  }
  return incrs
})()

function fmtAxisBytes (v, perSec) {
  if (v === 0) return '0'
  const { value, prefix } = scaleBytes(v)
  const digits = value % 1 === 0 ? String(value) : preciseFormatter.format(value)
  return digits + ' ' + prefix + (perSec ? '/s' : '')
}

// X tick labels are centered on their gridline; with zero right padding the
// plot reaches the card edge, so hide any label that would clip at a canvas
// edge (its gridline stays). A tick entering from the right shows its label
// once it has slid far enough left to fit.
function xAxisValues (u, vals) {
  const dpr = window.devicePixelRatio
  const plotWidth = u.bbox.width / dpr
  const leftRoom = u.bbox.left / dpr
  u.ctx.font = u.axes[0].font[0]
  return vals.map(v => {
    const label = new Date(v * 1000).toLocaleTimeString('en-GB')
    const half = u.ctx.measureText(label).width / dpr / 2
    const pos = u.valToPos(v, 'x')
    if (pos - half < -leftRoom || pos + half > plotWidth) return null
    return label
  })
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

  const gridColor = () => prefersDark() ? 'rgba(255,255,255,0.07)' : 'rgba(0,0,0,0.08)'
  const axisColor = () => prefersDark() ? '#777' : '#666'

  const opts = {
    width,
    height,
    // Zero side padding: the plot spans the full card width, edge tick
    // labels are filtered in xAxisValues instead
    padding: [null, 0, null, 0],
    cursor: { show: true, drag: { x: false, y: false }, focus: { prox: 16 } },
    focus: { alpha: 0.25 },
    legend: { show: false },
    hooks: {
      setLegend: [(u) => {
        updateLegend(handle, u.legend.idx)
      }],
      draw: [() => alignLegend(handle), (u) => drawRefLine(u, handle)]
    },
    series,
    axes: [
      {
        stroke: axisColor,
        grid: { stroke: gridColor, dash: [2, 4] },
        ticks: { stroke: gridColor },
        space: 80,
        incrs: [1, 5, 10, 15, 30, 60, 120, 300, 600],
        values: xAxisValues
      },
      {
        stroke: axisColor,
        grid: { stroke: gridColor, dash: [2, 4] },
        ticks: { stroke: gridColor, size: 3 },
        ...(isByteUnit(config.unit) && { incrs: BYTE_INCRS }),
        values: isByteUnit(config.unit)
          ? (u, vals) => vals.map(v => fmtAxisBytes(v, config.unit === 'bytes/s'))
          : (u, vals) => vals.map(helpers.nFormatter),
        size: yAxisSize,
        gap: 2
      }
    ],
    scales: {
      y: {
        range: stableMaxRange(handle)
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
    scaleMax: 0,
    shrinkCount: 0,
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
  render, update, setScale
}
