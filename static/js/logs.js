/* global localStorage */
import * as Poller from './poller.js'
import connectionStatus from './connection-status.js'

let shouldAutoScroll = true
const evtSource = new window.EventSource('api/livelog')
const livelog = document.getElementById('livelog')
const tbody = document.getElementById('livelog-body')
const btnToTop = document.getElementById('to-top')
const btnToBottom = document.getElementById('to-bottom')

// The stream is push-based: there is no poll cadence to sweep and no rate
// to pick, so the header control drops to a plain live/paused indicator
const refreshControl = document.getElementById('refresh-control')
if (refreshControl) refreshControl.classList.add('realtime')

// Lines received while paused, appended on resume so nothing is lost
const pendingRows = []

function appendRow (tr) {
  const row = tbody.appendChild(tr)
  if (shouldAutoScroll) row.scrollIntoView()
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

  if (Poller.isPaused()) pendingRows.push(tr)
  else appendRow(tr)
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
