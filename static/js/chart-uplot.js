/* global ResizeObserver */
import UPlot from './lib/uplot.esm.js'
import * as helpers from './helpers.js'

const chartColors = ['#54be7e', '#4589ff', '#d12771', '#d2a106', '#08bdba', '#bae6ff', '#ba4e00',
  '#d4bbff', '#8a3ffc', '#33b1ff', '#007d79', '#770f1c']

const POLLING_RATE = 5000
const X_AXIS_LENGTH = 600000 // 10 min
const MAX_TICKS = X_AXIS_LENGTH / POLLING_RATE

function formatLabel (key) {
  const label = key.replace(/_/g, ' ').replace(/(rate|details|messages)/ig, '').trim()
    .replace(/^\w/, c => c.toUpperCase())
  return label || 'Total'
}

function value (data) {
  return (data.rate === undefined) ? data : data.rate
}

function fmtTimestamp (v) {
  if (v == null) return '--'
  const d = new Date(v * 1000)
  const date = d.toLocaleDateString('en-GB', { year: 'numeric', month: 'short', day: 'numeric' })
  return date + ', ' + d.toLocaleTimeString('en-GB')
}

function fmtValue (v) {
  return v != null ? helpers.nFormatter(v) : '--'
}

function buildLegend (handle) {
  const el = document.createElement('div')
  el.className = 'u-legend-custom'

  const timeSpan = document.createElement('span')
  timeSpan.className = 'u-legend-time'

  const itemsGrid = document.createElement('div')
  itemsGrid.className = 'u-legend-items'

  el.append(timeSpan, itemsGrid)
  handle.legendEl = el
  handle.legendGrid = itemsGrid
  handle.legendTime = timeSpan
  handle.legendItems = []
}

function addLegendItem (handle, seriesIdx) {
  const color = chartColors[(seriesIdx - 1) % chartColors.length]
  const label = formatLabel(handle.seriesKeys[seriesIdx - 1])

  const item = document.createElement('span')
  item.className = 'u-legend-item'
  item.style.cursor = 'pointer'

  const marker = document.createElement('span')
  marker.className = 'u-legend-marker'
  marker.style.background = color

  const labelSpan = document.createElement('span')
  labelSpan.className = 'u-legend-label'
  labelSpan.textContent = label + ':'

  const valueSpan = document.createElement('span')
  valueSpan.className = 'u-legend-value'
  valueSpan.textContent = '--'

  item.append(marker, labelSpan, valueSpan)
  item.addEventListener('click', () => {
    if (!handle.uplot) return
    const show = !handle.uplot.series[seriesIdx].show
    handle.uplot.setSeries(seriesIdx, { show })
    item.classList.toggle('u-legend-hidden', !show)
  })

  handle.legendGrid.append(item)
  handle.legendItems[seriesIdx] = { valueSpan, item }
}

function updateLegend (handle, idx) {
  if (!handle.legendEl) return
  const data = handle.data
  const resolveIdx = idx != null ? idx : (data[0].length > 0 ? data[0].length - 1 : null)

  handle.legendTime.textContent = resolveIdx != null ? fmtTimestamp(data[0][resolveIdx]) : '--'

  for (let i = 1; i <= handle.seriesKeys.length; i++) {
    const li = handle.legendItems[i]
    if (!li) continue
    const v = resolveIdx != null && data[i] ? data[i][resolveIdx] : null
    li.valueSpan.textContent = fmtValue(v)
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
  return Math.round(width / 3.5)
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

  const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches ||
    document.documentElement.classList.contains('theme-dark')
  const gridColor = isDark ? 'rgba(255,255,255,0.07)' : 'rgba(0,0,0,0.08)'
  const axisColor = isDark ? '#777' : '#666'

  const opts = {
    width,
    height,
    cursor: { show: true, drag: { x: false, y: false } },
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
        space: 60,
        incrs: [1, 5, 10, 15, 30, 60],
        values: (u, vals) => vals.map(v => new Date(v * 1000).toLocaleTimeString('en-GB'))
      },
      {
        stroke: axisColor,
        grid: { stroke: gridColor, dash: [2, 4] },
        ticks: { stroke: gridColor },
        label: config.unit,
        values: (u, vals) => vals.map(helpers.nFormatter),
        size: 55
      }
    ],
    scales: {
      y: {
        range: (u, min, max) => [0, max > 0 ? max * 1.1 : 10]
      }
    }
  }

  if (config.stacked) {
    opts.bands = []
    for (let i = 1; i < series.length; i++) {
      series[i].fill = (chartColors[(i - 1) % chartColors.length]) + '40'
    }
  }

  if (!handle.legendEl) {
    buildLegend(handle)
    for (let i = 1; i <= seriesKeys.length; i++) {
      addLegendItem(handle, i)
    }
  }

  const legendBelow = window.__chartDev && window.__chartDev.get('legendPosition') === 'below'
  if (!legendBelow) el.prepend(handle.legendEl)
  handle.uplot = new UPlot(opts, data, el)
  if (legendBelow) el.append(handle.legendEl)

  let lastWidth = width
  const ro = new ResizeObserver(() => {
    const newWidth = el.clientWidth
    if (newWidth > 0 && newWidth !== lastWidth) {
      lastWidth = newWidth
      handle.uplot.setSize({ width: newWidth, height: chartHeight(newWidth) })
    }
  })
  ro.observe(el)
}

function stackData (handle) {
  const len = handle.data[0].length
  const seriesCount = handle.seriesKeys.length

  const indices = Array.from({ length: seriesCount }, (_, i) => i + 1)
  if (handle.config.reverseStack) indices.reverse()

  const stacked = new Array(seriesCount + 1)
  stacked[0] = handle.data[0]

  const running = new Array(len).fill(0)
  for (const idx of indices) {
    const acc = new Array(len)
    for (let j = 0; j < len; j++) {
      const v = handle.data[idx] ? handle.data[idx][j] : null
      if (v != null) {
        running[j] += v
        acc[j] = running[j]
      } else {
        acc[j] = null
      }
    }
    stacked[idx] = acc
  }
  return stacked
}

function render (id, unit, fill = false, stacked = false, reverseStack = false) {
  const el = document.getElementById(id)
  const graphContainer = document.createElement('div')
  graphContainer.classList.add('graph')
  el.append(graphContainer)

  return {
    el: graphContainer,
    uplot: null,
    legendEl: null,
    seriesKeys: [],
    data: [[]],
    config: { unit, fill, stacked, reverseStack }
  }
}

function update (handle, data, filled = false) {
  const now = Date.now() / 1000

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

    const log = data[key + '_log'] || (data[key] && data[key].log) || []

    if (handle.data[0].length === 0 && log.length > 0) {
      for (let i = 0; i < log.length; i++) {
        handle.data[0].push(now - (POLLING_RATE / 1000) * (log.length - i))
      }
      for (let s = 1; s < handle.data.length; s++) {
        while (handle.data[s].length < handle.data[0].length) {
          handle.data[s].unshift(null)
        }
      }
    }

    const seriesData = []
    for (let i = 0; i < log.length; i++) {
      const v = log[i]
      seriesData.push(typeof v === 'object' ? value(v) : Number(v))
    }
    while (seriesData.length < handle.data[0].length) {
      seriesData.unshift(null)
    }
    handle.data.push(seriesData)
  }

  if (handle.data[0].length > 0) {
    const lastTime = handle.data[0][handle.data[0].length - 1]
    if ((now - lastTime) >= (POLLING_RATE / 1000) * 2) {
      handle.data[0].push(now - POLLING_RATE / 1000)
      for (let s = 1; s < handle.data.length; s++) {
        handle.data[s].push(null)
      }
    }
  }

  handle.data[0].push(now)

  for (let i = 0; i < handle.seriesKeys.length; i++) {
    const key = handle.seriesKeys[i]
    const dataIdx = i + 1
    if (activeKeys.indexOf(key) !== -1) {
      const v = value(data[key])
      handle.data[dataIdx].push(typeof v === 'object' ? Number(v) : v)
    } else {
      handle.data[dataIdx].push(null)
    }
  }

  while (handle.data[0].length > MAX_TICKS) {
    for (let s = 0; s < handle.data.length; s++) {
      handle.data[s].shift()
    }
  }

  const plotData = handle.config.stacked ? stackData(handle) : handle.data

  if (!handle.uplot) {
    initChart(handle, filled)
  } else if (newSeriesAdded) {
    handle.uplot.destroy()
    handle.uplot = null
    initChart(handle, filled)
  }
  handle.uplot.setData(plotData)
  updateLegend(handle, null)
}

export {
  render, update
}
