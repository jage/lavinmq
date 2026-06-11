function start (fn, intervalMs = 5000) {
  let timer = null
  const run = () => {
    try {
      const result = fn()
      if (result instanceof Promise) {
        result.catch(e => console.warn('Poll failed:', e.message || e))
      }
    } catch (e) {
      console.error(e)
    }
  }
  const resume = () => {
    if (timer !== null) return
    run()
    timer = window.setInterval(run, intervalMs)
  }
  const pause = () => {
    if (timer === null) return
    window.clearInterval(timer)
    timer = null
  }
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) pause()
    else resume()
  })
  window.addEventListener('online', resume)
  window.addEventListener('offline', pause)
  if (!document.hidden) resume()
}

export { start }
