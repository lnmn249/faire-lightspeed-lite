import { createApp } from 'vue'
import App from './App.vue'

const runtime = window.RUNTIME_CONFIG?.API_URL
const baked   = import.meta.env.VITE_API_URL
const apiUrl  = runtime ?? baked ?? (location.hostname==='localhost' ? 'http://localhost:8081' : location.origin)

const app = createApp(App)
app.provide('API_URL', apiUrl)               
app.mount('#app')

// import { createApp } from 'vue'
// import App from './App.vue'

// // set global API url
// const apiUrl =
//   window.RUNTIME_CONFIG?.API_URL ||
//   import.meta.env.VITE_API_URL ||
//   "http://localhost:8080";

// const app = createApp(App)

// // make available to all components as this.$apiUrl
// app.config.globalProperties.$apiUrl = apiUrl

// app.mount('#app')
