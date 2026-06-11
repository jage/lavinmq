import * as Auth from './auth.js'
import * as Helpers from './helpers.js'
import * as Poller from './poller.js'
import connectionStatus from './connection-status.js'

Auth.whoAmI().catch(() => Auth.logout())

document.getElementById('username').textContent = Auth.getUsername()

const refreshControl = document.getElementById('refresh-control')
const refreshToggle = document.getElementById('refresh-toggle')
const refreshRate = document.getElementById('refresh-rate')
const refreshStatus = document.getElementById('refresh-status')
function renderRefreshControl () {
  if (!refreshControl) return
  const paused = Poller.isPaused()
  const lastSuccess = connectionStatus.lastSuccess
  const lastTime = lastSuccess ? new Date(lastSuccess).toLocaleTimeString() : null
  let state
  let label
  if (paused) {
    state = 'paused'
    label = lastTime ? 'Paused ' + lastTime : 'Paused'
  } else if (connectionStatus.state === 'connected') {
    state = 'running'
    label = lastTime || 'Connected'
  } else if (connectionStatus.state === 'reconnecting') {
    // A single failed poll: keep the label calm, the pulsing dot says enough
    state = 'reconnecting'
    label = lastTime || 'Connecting…'
  } else if (connectionStatus.state === 'offline') {
    state = 'stale'
    label = lastTime ? 'Stale since ' + lastTime : 'No data'
  } else {
    state = 'unknown'
    label = 'Connecting…'
  }
  refreshControl.dataset.state = state
  refreshStatus.querySelector('.status-label').textContent = label
  const tip = []
  if (lastTime) tip.push('Last update: ' + lastTime)
  if (connectionStatus.lastError) tip.push('Last error: ' + connectionStatus.lastError.message)
  refreshStatus.title = tip.join('\n') || 'Waiting for first response'
  refreshToggle.setAttribute('aria-pressed', String(paused))
  const toggleLabel = paused ? 'Resume auto-refresh' : 'Pause auto-refresh'
  refreshToggle.title = toggleLabel
  refreshToggle.setAttribute('aria-label', toggleLabel)
}
if (refreshControl) {
  const statusDot = refreshStatus.querySelector('.status-dot')
  // Ring around the dot sweeps clockwise over one poll interval,
  // restarted on every poll so it always points at the next refresh
  function restartSweep () {
    statusDot.style.setProperty('--refresh-interval', Poller.getRate() + 'ms')
    statusDot.classList.remove('sweep')
    statusDot.getBoundingClientRect() // force reflow so the animation restarts
    statusDot.classList.add('sweep')
  }
  refreshRate.value = String(Poller.getRate())
  refreshRate.addEventListener('change', () => Poller.setRate(Number(refreshRate.value)))
  refreshToggle.addEventListener('click', () => {
    if (Poller.isPaused()) Poller.resume()
    else Poller.pause()
  })
  Poller.events.addEventListener('poll', restartSweep)
  Poller.events.addEventListener('change', () => {
    if (Poller.isPaused()) statusDot.classList.remove('sweep')
    renderRefreshControl()
  })
  connectionStatus.addEventListener('change', renderRefreshControl)
  window.setInterval(renderRefreshControl, 5000)
  renderRefreshControl()
}

const menuButton = document.getElementById('menu-button')
const menuContent = document.getElementById('menu-content')

menuButton.addEventListener('click', (e) => {
  menuButton.classList.toggle('open-menu')
  menuContent.classList.toggle('show-menu')
})

Helpers.addVhostOptions('user-vhost', { addAll: true }).then(() => {
  const vhost = window.sessionStorage.getItem('vhost')
  if (vhost) {
    const opt = document.querySelector('#userMenuVhost option[value="' + vhost + '"]')
    if (opt) {
      document.querySelector('#userMenuVhost').value = vhost
      window.sessionStorage.setItem('vhost', vhost)
    }
  } else {
    window.sessionStorage.setItem('vhost', '_all')
  }
})

document.getElementById('userMenuVhost').addEventListener('change', (e) => {
  window.sessionStorage.setItem('vhost', e.target.value)
  window.location.reload()
})

document.getElementById('signoutLink').addEventListener('click', () => {
  Auth.logout()
})

const usermenuButton = document.getElementById('usermenu-button')
const usermenuContent = document.getElementById('user-menu')

usermenuButton.addEventListener('click', (e) => {
  usermenuButton.classList.toggle('open-menu')
  usermenuContent.classList.toggle('visible')
})

// Theme switcher functionality
class ThemeSwitcher {
  constructor () {
    this.currentTheme = 'system'
    if (!Helpers.stateClasses.has('system')) {
      if (Helpers.stateClasses.has('theme-light')) {
        this.currentTheme = 'light'
      } else if (Helpers.stateClasses.has('theme-dark')) {
        this.currentTheme = 'dark'
      }
    }
    this.init()
  }

  #setSystemColor (mql) {
    if (mql.matches) {
      this.systemColor = 'dark'
    } else {
      this.systemColor = 'light'
    }
    if (this.currentTheme === 'system') {
      this.applyTheme('system') // make sure right system class is used
    }
  }

  init () {
    const mql = window.matchMedia('(prefers-color-scheme: dark)')
    this.#setSystemColor(mql)
    mql.addEventListener('change', mql => this.#setSystemColor(mql))
    // Add event listeners to theme buttons
    document.querySelectorAll('#theme-switcher button').forEach(button => {
      button.addEventListener('click', _ => this.setTheme(button.dataset.theme))
    })

    // Set initial active button
    this.updateActiveButton()
  }

  setTheme (theme) {
    this.currentTheme = theme
    this.applyTheme(theme)
    this.updateActiveButton()
  }

  applyTheme (theme) {
    if (theme === 'system') {
      Helpers.stateClasses.add('system')
      theme = this.systemColor
    } else {
      Helpers.stateClasses.remove('system')
    }
    if (theme === 'light') {
      Helpers.stateClasses.add('theme-light')
      Helpers.stateClasses.remove('theme-dark')
    } else {
      Helpers.stateClasses.add('theme-dark')
      Helpers.stateClasses.remove('theme-light')
    }
  }

  updateActiveButton () {
    document.querySelectorAll('#theme-switcher button').forEach(button => {
      button.classList.remove('active')
    })

    const activeButton = document.querySelector(`#theme-switcher button[data-theme="${this.currentTheme}"]`)
    if (activeButton) {
      activeButton.classList.add('active')
    }
  }
}

// Initialize theme switcher when DOM is loaded
window.themeSwitcher = new ThemeSwitcher()

// Check if sidebar is collapsed or expanded
document.addEventListener('DOMContentLoaded', () => {
  const sidebarCollapsed = Helpers.stateClasses.has('menu-collapsed')
  const toggleLabel = document.querySelector('.toggle-menu-label')

  if (sidebarCollapsed) {
    toggleLabel.textContent = 'Expand sidebar'
  }
})

document.getElementById('toggle-menu').addEventListener('click', () => {
  const added = Helpers.stateClasses.toggle('menu-collapsed')
  const toggleLabel = document.querySelector('.toggle-menu-label')

  // Save state
  if (added) {
    toggleLabel.textContent = 'Expand sidebar'
    updateMenuTooltips()
  } else {
    toggleLabel.textContent = 'Collapse sidebar'
  }
})

const sidebarMenu = document.getElementById('menu')
const menuItems = document.querySelectorAll('#menu-content li a.menu-tooltip')

function updateMenuTooltips () {
  menuItems.forEach(item => {
    const tooltip = item.querySelector('.menu-tooltip-label')
    if (tooltip) {
      const rect = item.getBoundingClientRect()
      tooltip.style.top = rect.top + (rect.height / 2) + 'px'
    }
  })
}

// Update tooltip positions on scroll
let ticking = false

sidebarMenu.addEventListener('scroll', (e) => {
  if (!ticking) {
    window.requestAnimationFrame(() => {
      updateMenuTooltips()
      ticking = false
    })
    ticking = true
  }
})

updateMenuTooltips()
