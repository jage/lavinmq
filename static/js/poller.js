const RATES = [5000, 10000, 30000, 60000]
const STORAGE_KEY = 'lmq.refreshInterval'
const PAUSED_KEY = 'lmq.refreshPaused'

const fns = new Set()
// Pollers registered while the tab was hidden; their initial fetch runs when
// the tab becomes visible (even while user-paused) so pages aren't blank
const pendingInitial = new Set()
let timer = null
// Pause follows along when navigating within the tab. Pages still fetch
// once on load so they aren't blank - this is not a data snapshot.
let userPaused = window.sessionStorage.getItem(PAUSED_KEY) === 'true'
// Hidden-tab and offline pauses are tracked separately so clearing one
// (e.g. an 'online' event in a hidden tab) can't cancel the other
let hiddenPaused = document.hidden
let offlinePaused = navigator.onLine === false
let inFlight = 0
let intervalMs = (() => {
  const stored = Number(window.localStorage.getItem(STORAGE_KEY))
  return RATES.includes(stored) ? stored : RATES[0]
})()

const events = new EventTarget()

function emit () {
  events.dispatchEvent(new CustomEvent('change', { detail: { paused: userPaused, intervalMs } }))
}

function anyPaused () {
  return userPaused || hiddenPaused || offlinePaused
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
// requests go out, so the sweep ring restarts on fresh data. The in-flight
// count also serializes timer ticks: a tick is skipped while a previous
// batch is still pending, so slow responses never pile up.
function settleBatch (pending) {
  inFlight++
  Promise.allSettled(pending).then(() => {
    inFlight--
    events.dispatchEvent(new CustomEvent('poll'))
  })
}

function runAll () {
  if (inFlight > 0) return
  const pending = []
  fns.forEach(fn => {
    const p = run(fn)
    if (p) pending.push(p)
  })
  settleBatch(pending)
}

function startTimer () {
  if (timer !== null || anyPaused()) return
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
  if (!anyPaused()) {
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
  if (!anyPaused()) {
    runAll()
    startTimer()
  }
  emit()
}

function getRate () {
  return intervalMs
}

function flushPendingInitial () {
  const deferred = [...pendingInitial]
  pendingInitial.clear()
  const pending = []
  deferred.forEach(fn => {
    const p = run(() => fn(true))
    if (p) pending.push(p)
  })
  if (deferred.length > 0) settleBatch(pending)
}

document.addEventListener('visibilitychange', () => {
  hiddenPaused = document.hidden
  if (hiddenPaused) {
    stopTimer()
  } else if (!anyPaused()) {
    pendingInitial.clear()
    runAll()
    startTimer()
  } else {
    flushPendingInitial()
  }
  emit()
})

window.addEventListener('online', () => {
  offlinePaused = false
  if (!anyPaused()) {
    runAll()
    startTimer()
  }
  emit()
})

window.addEventListener('offline', () => {
  offlinePaused = true
  stopTimer()
  emit()
})

// Whether any page code has registered to poll. Pages that register
// nothing (e.g. the 401/404 error pages) never auto-refresh, so the
// control shows a static state instead of a live-looking one.
function hasPollers () {
  return fns.size > 0
}

function start (fn) {
  fns.add(fn)
  emit() // a poller exists now; let the refresh control leave its static state
  if (hiddenPaused) {
    pendingInitial.add(fn)
    return
  }
  // The initial run gets a true flag so pages can render one-time details
  const p = run(() => fn(true))
  startTimer()
  settleBatch(p ? [p] : [])
}

export { start, pause, resume, isPaused, setRate, getRate, hasPollers, events }
