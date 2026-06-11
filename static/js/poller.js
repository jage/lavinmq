const RATES = [5000, 10000, 30000, 60000]
const STORAGE_KEY = 'lmq.refreshInterval'
const PAUSED_KEY = 'lmq.refreshPaused'

const fns = new Set()
let timer = null
// Pause follows along when navigating within the tab. Pages still fetch
// once on load so they aren't blank - this is not a data snapshot.
let userPaused = window.sessionStorage.getItem(PAUSED_KEY) === 'true'
let autoPaused = false
let intervalMs = (() => {
  const stored = Number(window.localStorage.getItem(STORAGE_KEY))
  return RATES.includes(stored) ? stored : RATES[0]
})()

const events = new EventTarget()

function emit () {
  events.dispatchEvent(new CustomEvent('change', { detail: { paused: userPaused, intervalMs } }))
}

function run (fn) {
  try {
    const result = fn()
    if (result instanceof Promise) {
      return result.catch(e => console.warn('Poll failed:', e.message || e.reason || e))
    }
  } catch (e) {
    console.error(e)
  }
}

// The poll event fires when the responses have settled, not when the
// requests go out, so the sweep ring restarts on fresh data
function emitPollSettled (pending) {
  Promise.allSettled(pending).then(() => {
    events.dispatchEvent(new CustomEvent('poll'))
  })
}

function runAll () {
  const pending = []
  fns.forEach(fn => {
    const p = run(fn)
    if (p) pending.push(p)
  })
  emitPollSettled(pending)
}

function startTimer () {
  if (timer !== null || userPaused || autoPaused) return
  timer = window.setInterval(runAll, intervalMs)
}

function stopTimer () {
  if (timer === null) return
  window.clearInterval(timer)
  timer = null
}

// Only user-initiated pause is public state; auto-pause (hidden tab,
// browser offline) is an internal scheduling detail
function isPaused () {
  return userPaused
}

function pause () {
  if (userPaused) return
  userPaused = true
  window.sessionStorage.setItem(PAUSED_KEY, 'true')
  stopTimer()
  emit()
}

function resume () {
  if (!userPaused) return
  userPaused = false
  window.sessionStorage.removeItem(PAUSED_KEY)
  if (!autoPaused) {
    runAll()
    startTimer()
  }
  emit()
}

function setRate (ms) {
  if (!RATES.includes(ms) || ms === intervalMs) return
  intervalMs = ms
  window.localStorage.setItem(STORAGE_KEY, String(ms))
  stopTimer()
  if (!userPaused && !autoPaused) {
    runAll()
    startTimer()
  }
  emit()
}

function getRate () {
  return intervalMs
}

function autoPause () {
  if (autoPaused) return
  autoPaused = true
  stopTimer()
  emit()
}

function autoResume () {
  if (!autoPaused) return
  autoPaused = false
  if (!userPaused) {
    runAll()
    startTimer()
  }
  emit()
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) autoPause()
  else autoResume()
})
window.addEventListener('online', autoResume)
window.addEventListener('offline', autoPause)

function start (fn) {
  fns.add(fn)
  if (document.hidden) {
    autoPaused = true
    return
  }
  const p = run(fn)
  startTimer()
  emitPollSettled(p ? [p] : [])
}

export { start, pause, resume, isPaused, setRate, getRate, events }
