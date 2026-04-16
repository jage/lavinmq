import * as ChartJS from './chart-chartjs.js'
import * as UPlot from './chart-uplot.js'

const useUPlot = new URLSearchParams(window.location.search).has('uplot') ||
  window.sessionStorage.getItem('uplot')
const impl = useUPlot ? UPlot : ChartJS

const render = impl.render
const update = impl.update

export {
  render, update
}
