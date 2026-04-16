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
  return Math.round(width / 1.6)
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

  const opts = {
    width,
    height,
    cursor: { show: true, drag: { x: false, y: false } },
    legend: { show: true },
    series,
    axes: [
      {
        stroke: '#888',
        grid: { stroke: '#2D2C2C', dash: [2, 4] },
        ticks: { stroke: '#2D2C2C' },
        values: (u, vals) => vals.map(v => {
          const d = new Date(v * 1000)
          const h = String(d.getHours()).padStart(2, '0')
          const m = String(d.getMinutes()).padStart(2, '0')
          const s = String(d.getSeconds()).padStart(2, '0')
          return h + ':' + m + ':' + s
        })
      },
      {
        stroke: '#888',
        grid: { stroke: '#2D2C2C', dash: [2, 4] },
        ticks: { stroke: '#2D2C2C' },
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

  handle.uplot = new UPlot(opts, data, el)

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

  // Determine stacking order
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
    seriesKeys: [],
    data: [[]],
    config: { unit, fill, stacked, reverseStack }
  }
}

function update (handle, data, filled = false) {
  const now = Date.now() / 1000

  // Parse keys — same logic as Chart.js version
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

    const log = data[key + '_log'] || (data[key] && data[key].log) || []

    // First series with log data sets up the timestamp axis
    if (handle.data[0].length === 0 && log.length > 0) {
      for (let i = 0; i < log.length; i++) {
        handle.data[0].push(now - (POLLING_RATE / 1000) * (log.length - i))
      }
      // Pad any earlier series to match
      for (let s = 1; s < handle.data.length; s++) {
        while (handle.data[s].length < handle.data[0].length) {
          handle.data[s].unshift(null)
        }
      }
    }

    // Build backfilled series data
    const seriesData = []
    for (let i = 0; i < log.length; i++) {
      const v = log[i]
      seriesData.push(typeof v === 'object' ? value(v) : Number(v))
    }
    // Pad to match existing timestamp length
    while (seriesData.length < handle.data[0].length) {
      seriesData.unshift(null)
    }
    handle.data.push(seriesData)
  }

  // Gap detection — insert null point if gap >= 2x polling rate
  if (handle.data[0].length > 0) {
    const lastTime = handle.data[0][handle.data[0].length - 1]
    if ((now - lastTime) >= (POLLING_RATE / 1000) * 2) {
      handle.data[0].push(now - POLLING_RATE / 1000)
      for (let s = 1; s < handle.data.length; s++) {
        handle.data[s].push(null)
      }
    }
  }

  // Push new timestamp
  handle.data[0].push(now)

  // Push new value for each series
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

  // Trim to MAX_TICKS
  while (handle.data[0].length > MAX_TICKS) {
    for (let s = 0; s < handle.data.length; s++) {
      handle.data[s].shift()
    }
  }

  // Apply stacking — accumulate values bottom to top
  const plotData = handle.config.stacked ? stackData(handle) : handle.data

  // Initialize or update chart
  if (!handle.uplot) {
    initChart(handle, filled)
  } else if (newSeriesAdded) {
    handle.uplot.destroy()
    handle.uplot = null
    initChart(handle, filled)
  }
  handle.uplot.setData(plotData)
}

export {
  render, update
}
