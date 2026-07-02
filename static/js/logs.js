/* global localStorage */
import * as Poller from './poller.js'
import connectionStatus from './connection-status.js'

let shouldAutoScroll = true
const evtSource = new window.EventSource('api/livelog')
const livelog = document.getElementById('livelog')
const tbody = document.getElementById('livelog-body')
const btnToTop = document.getElementById('to-top')
const btnToBottom = document.getElementById('to-bottom')

// The stream is push-based: there is no poll cadence to sweep, so the header
// control shows a steady ring while the stream is open (see layout.js). The
// rate dropdown stays so the header doesn't shift between pages.
const refreshControl = document.getElementById('refresh-control')
if (refreshControl) refreshControl.classList.add('realtime')

// Lines paint as they arrive, but batched per animation frame: the SSE
// backlog is ~1k messages in one burst, and appending + scrolling per row
// forces a layout each time, locking the main thread for hundreds of ms
// (delaying e.g. the vhost selector). While paused, lines stay pending and
// resume paints them.
const pending = []
let paintScheduled = false

evtSource.onopen = () => connectionStatus.recordSuccess()

evtSource.onmessage = (event) => {
  connectionStatus.recordSuccess()
  pending.push(event)
  schedulePaint()
}

function paint () {
  paintScheduled = false
  if (Poller.isPaused() || pending.length === 0) return
  const rows = document.createDocumentFragment()
  for (const event of pending.splice(0)) {
    rows.appendChild(buildRow(event))
  }
  tbody.appendChild(rows)
  if (shouldAutoScroll) livelog.scrollTop = livelog.scrollHeight
}

function schedulePaint () {
  if (paintScheduled) return
  paintScheduled = true
  window.requestAnimationFrame(paint)
}

function buildRow (event) {
  const timestamp = new Date(parseInt(event.lastEventId))
  const [severity, source, message] = JSON.parse(event.data)

  const tdTs = document.createElement('td')
  tdTs.textContent = timestamp.toLocaleString()
  const tdSev = document.createElement('td')
  tdSev.textContent = severity
  const tdSrc = document.createElement('td')
  tdSrc.title = source
  tdSrc.textContent = source
  const preMsg = document.createElement('pre')
  preMsg.textContent = message
  const tdMsg = document.createElement('td')
  tdMsg.appendChild(preMsg)

  const tr = document.createElement('tr')
  tr.append(tdTs, tdSev, tdSrc, tdMsg)
  return tr
}

// Registering keeps the header refresh control in its regular live state,
// and Poller.resume runs all pollers immediately, so resuming paints what
// arrived while paused without waiting a tick
Poller.start(schedulePaint)

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
