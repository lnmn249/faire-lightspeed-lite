<script setup>
import { ref } from 'vue'

const apiUrl = (window.__APP_CONFIG__ && window.__APP_CONFIG__.API_URL) || 'http://localhost:8080'
const refreshing = ref(false)
const messages = ref([])
const lastRefresh = ref('')

function timestamped(msg) {
  const now = new Date()
  const ts = now.toLocaleTimeString()   // local timezone
  return `[${ts}] ${msg}`
}

function refreshCatalog() {
  refreshing.value = true
  messages.value = []

  const es = new EventSource(apiUrl + '/catalog/refresh/stream')

  es.onmessage = (ev) => {
    messages.value.push(timestamped(ev.data))
    if (ev.data.startsWith('Done')) {
      es.close()
      loadLastRefresh()
      refreshing.value = false
    }
  }

  es.onerror = () => {
    messages.value.push(timestamped('Error'))
    es.close()
    refreshing.value = false
  }
}

async function loadLastRefresh() {
  const r = await fetch(apiUrl + '/catalog/last-refresh')
  const j = await r.json()
  lastRefresh.value = j.last_refresh_iso || '—'
}
</script>

<template>
  <section class="card row">
    <button class="btn" @click="refreshCatalog" :disabled="refreshing">
      {{ refreshing ? 'Refreshing…' : 'Update Catalog' }}
    </button>
    <span class="muted">Last refresh: {{ lastRefresh || '—' }}</span>
  </section>

  <section v-if="messages.length" class="card">
    <h3>Catalog Refresh Log</h3>
    <ul>
      <li v-for="(m,i) in messages" :key="i" class="mono">{{ m }}</li>
    </ul>
  </section>
</template>
