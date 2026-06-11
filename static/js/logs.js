/* global localStorage */
import * as Poller from './poller.js'
import connectionStatus from './connection-status.js'

let shouldAutoScroll = true
const evtSource = new window.EventSource('api/livelog')
const livelog = document.getElementById('livelog')
const lines = document.getElementById('livelog-lines')
const btnToTop = document.getElementById('to-top')
const btnToBottom = document.getElementById('to-bottom')

const SEVERITIES = ['debug', 'info', 'notice', 'warning', 'error', 'fatal']

const pad = (n) => String(n).padStart(2, '0')

// Fixed-width local time so the column never shifts: YYYY-MM-DD HH:MM:SS
function fmtTimestamp (d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}

// The stream is push-based: there is no poll cadence to sweep and no rate
// to pick, so the header control drops to a plain live/paused indicator
const refreshControl = document.getElementById('refresh-control')
if (refreshControl) refreshControl.classList.add('realtime')

// Lines received while paused, appended on resume so nothing is lost
const pendingRows = []

function appendRow (line) {
  lines.appendChild(line)
  // Scroll the container, not the row: following the tail must not move
  // the horizontal position in unwrapped mode
  if (shouldAutoScroll) livelog.scrollTop = livelog.scrollHeight
}

Poller.events.addEventListener('change', () => {
  if (Poller.isPaused()) return
  while (pendingRows.length > 0) appendRow(pendingRows.shift())
})

evtSource.onopen = () => connectionStatus.recordSuccess()

evtSource.onmessage = (event) => {
  connectionStatus.recordSuccess()
  const timestamp = new Date(parseInt(event.lastEventId))
  const [severity, source, message] = JSON.parse(event.data)
  const sev = String(severity).toLowerCase()

  const line = document.createElement('div')
  line.className = 'log-line' + (SEVERITIES.includes(sev) ? ' log-' + sev : '')

  const ts = document.createElement('span')
  ts.className = 'log-ts'
  ts.textContent = fmtTimestamp(timestamp)
  const sevSpan = document.createElement('span')
  sevSpan.className = 'log-sev'
  // Space-padded (not CSS columns) so a copied line keeps its alignment
  sevSpan.textContent = sev.padEnd(7)
  const src = document.createElement('span')
  src.className = 'log-src'
  src.textContent = source
  const msg = document.createElement('span')
  msg.className = 'log-msg'
  msg.textContent = message

  line.append(ts, ' ', sevSpan, ' ', src, ' ', msg)
  if (Poller.isPaused()) pendingRows.push(line)
  else appendRow(line)
}

evtSource.onerror = () => {
  connectionStatus.recordError(new Error('log stream disconnected'))
  window.fetch('api/whoami')
    .then(response => response.json())
    .then(whoami => {
      if (!whoami.tags.includes('administrator')) {
        forbidden()
      }
    })
}

function forbidden () {
  const tblError = document.getElementById('table-error')
  tblError.textContent = 'Access denied, administator access required'
  tblError.style.display = 'block'
}

// Scrolling
function setScrollMode (toBottom) {
  shouldAutoScroll = toBottom
  localStorage.setItem('lmq.logScrollMode', toBottom ? 'bottom' : 'top')
  btnToBottom.setAttribute('aria-pressed', String(toBottom))
  btnToTop.setAttribute('aria-pressed', String(!toBottom))
}

// Initialize from saved preference, default to newest
const savedMode = localStorage.getItem('lmq.logScrollMode')
const initialMode = savedMode ? savedMode === 'bottom' : true
setScrollMode(initialMode)

// Single line per entry by default; wrapping is a persisted preference
const btnWrap = document.getElementById('toggle-wrap')
function setWrapMode (wrap) {
  livelog.classList.toggle('wrap', wrap)
  btnWrap.setAttribute('aria-pressed', String(wrap))
  localStorage.setItem('lmq.logWrap', String(wrap))
}
setWrapMode(localStorage.getItem('lmq.logWrap') === 'true')
btnWrap.addEventListener('click', () => setWrapMode(!livelog.classList.contains('wrap')))

btnToTop.addEventListener('click', () => {
  setScrollMode(false)
  livelog.scrollTop = 0
})

btnToBottom.addEventListener('click', () => {
  setScrollMode(true)
  livelog.scrollTop = livelog.scrollHeight
})

let lastScrollTop = livelog.pageYOffset || livelog.scrollTop
livelog.addEventListener('scroll', event => {
  const { scrollHeight, scrollTop, clientHeight } = event.target
  const st = livelog.pageYOffset || livelog.scrollTop
  if (st > lastScrollTop && shouldAutoScroll === false) {
    shouldAutoScroll = (Math.abs(scrollHeight - clientHeight - scrollTop) < 3)
  } else if (st < lastScrollTop) {
    shouldAutoScroll = false
  }
  lastScrollTop = st <= 0 ? 0 : st
})

window.addEventListener('beforeunload', () => evtSource.close())
