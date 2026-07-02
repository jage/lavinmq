import status from './connection-status.js'
import * as DOM from './dom.js'

function request (method, path, options = {}) {
  const body = options.body
  const headers = options.headers || new window.Headers()
  const opts = {
    method,
    headers
  }
  if (body instanceof window.FormData) {
    headers.delete('Content-Type') // browser will set to multipart with boundary
    opts.body = body
  } else if (body) {
    headers.append('Content-Type', 'application/json')
    opts.body = JSON.stringify(body)
  }
  return window.fetch(path, opts)
    .then(response => {
      updateVersionFromResponse(response)
      updateStatsIntervalFromResponse(response)
      if (response.status >= 500) {
        status.recordError({ status: response.status, reason: response.statusText })
      } else if (response.status !== 401) {
        status.recordSuccess()
      }
      if (!response.ok) {
        const error = { status: response.status, reason: response.statusText, is_error: true }
        return response.json()
          .then(json => { if (json && json.reason) error.reason = json.reason; return error }, () => error)
          .finally(() => { standardErrorHandler(error) })
      } else { return response.json().catch(() => null) }
    }, err => {
      status.recordError(err)
      throw err
    })
}

// The server advertises its version via the `LavinMQ-Version` header on every
// response. Pick it up here so the UI shows the current version (cached in
// sessionStorage, displayed by inline script in header.shtml) without an extra request.
function updateVersionFromResponse (response) {
  const version = response.headers.get('LavinMQ-Version')
  if (!version) return
  window.sessionStorage.setItem('lavinmq_version', version)
  const el = document.getElementById('version')
  if (el) {
    if (el.textContent === '') {
      el.textContent = version
    } else if (el.textContent !== version) {
      window.location.reload() // if new version then html/js might have changed too
    }
  }
}

// Spacing of the server's *_log samples; advertised per response so charts
// can place historical points correctly under any stats_interval config
let statsIntervalMs = 5000

function updateStatsIntervalFromResponse (response) {
  const ms = Number(response.headers.get('LavinMQ-Stats-Interval'))
  if (ms > 0) statsIntervalMs = ms
}

function statsInterval () {
  return statsIntervalMs
}

// One toast per throttle window: polling would otherwise refresh an error
// toast every tick during an outage, drowning out everything else
let lastServerErrorToast = 0

function standardErrorHandler (e) {
  if (e.status >= 500) {
    console.error(`Server error ${e.status}: ${e.reason}`)
    const now = Date.now()
    if (now - lastServerErrorToast > 10000) {
      lastServerErrorToast = now
      DOM.toast.error(e.reason || `Server error ${e.status}`)
    }
    throw e
  } else if (e.status === 404) {
    console.warn(`Not found: ${e.message}`)
  } else if (e.status === 401) {
    return window.location.assign('login')
  } else if (e.body || e.message || e.reason) {
    return DOM.toast.error(e.body || e.message || e.reason)
  } else {
    console.error(e)
  }
  throw e
}

function url (strings, ...params) {
  return params.reduce(
    (res, param, i) => {
      if (param instanceof NoUrlEscapeString) {
        return res + param.toString() + strings[i + 1]
      } else {
        return res + encodeURIComponent(param) + strings[i + 1]
      }
    },
    strings[0])
}

class NoUrlEscapeString {
  constructor (value) {
    this.value = value
  }

  toString () {
    return this.value
  }
}

function noencode (v) {
  return new NoUrlEscapeString(v)
}

export {
  request,
  url,
  noencode,
  statsInterval
}
