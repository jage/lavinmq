/* Dev toolbar for chart A/B comparison — remove before shipping */
(function () {
  const defaults = {
    engine: 'chartjs',
    legendPosition: 'above',
    rateGrouping: 'split'
  }

  function get (key) {
    return window.sessionStorage.getItem('chart-dev-' + key) || defaults[key]
  }

  function set (key, val) {
    window.sessionStorage.setItem('chart-dev-' + key, val)
  }

  // Expose settings for chart.js bridge
  window.__chartDev = { get, set }

  // Set uplot flag for the bridge module
  if (get('engine') === 'uplot') {
    window.sessionStorage.setItem('uplot', '1')
  } else {
    window.sessionStorage.removeItem('uplot')
  }

  // Build toolbar after DOM is ready
  document.addEventListener('DOMContentLoaded', buildToolbar)

  function buildToolbar () {
    const bar = document.createElement('div')
    bar.id = 'chart-dev-toolbar'
    bar.innerHTML = [
      '<strong>Charts</strong>',
      makeToggle('engine', ['chartjs', 'uplot']),
      makeToggle('legendPosition', ['above', 'below', 'table']),
      makeToggle('rateGrouping', ['combined', 'split'])
    ].join('')
    document.body.append(bar)

    bar.addEventListener('click', function (e) {
      const btn = e.target.closest('[data-key]')
      if (!btn) return
      const key = btn.dataset.key
      const val = btn.dataset.val
      set(key, val)
      window.location.reload()
    })
  } // end buildToolbar

  function makeToggle (key, options) {
    const current = get(key)
    const label = key.replace(/([A-Z])/g, ' $1').toLowerCase()
    let html = '<span class="cdt-group"><span class="cdt-label">' + label + ':</span>'
    for (const opt of options) {
      const active = opt === current ? ' cdt-active' : ''
      html += '<button class="cdt-btn' + active + '" data-key="' + key + '" data-val="' + opt + '">' + opt + '</button>'
    }
    html += '</span>'
    return html
  }
})()
