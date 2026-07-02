class ConnectionStatus extends EventTarget {
  constructor () {
    super()
    this.state = 'unknown'
    this.lastSuccess = null
    this.lastError = null
    this.failures = 0
  }

  recordSuccess () {
    this.failures = 0
    this.lastSuccess = Date.now()
    this.setState('connected')
  }

  recordError (err) {
    this.failures++
    const message = (err && (err.message || err.reason)) ||
      (err && err.status ? `HTTP ${err.status}` : String(err))
    this.lastError = { at: Date.now(), message }
    this.setState(this.failures >= 2 ? 'offline' : 'reconnecting')
  }

  setState (s) {
    if (s === this.state) return
    this.state = s
    this.dispatchEvent(new CustomEvent('change', { detail: { state: s } }))
  }
}

const status = new ConnectionStatus()
window.addEventListener('offline', () => status.setState('offline'))

export default status
