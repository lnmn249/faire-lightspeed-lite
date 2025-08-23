<template>
  <div class="app">
    <header class="row">
      <h2 class="h2">Faire → Lightspeed (Lite)</h2>
      <span class="pill mono">API: {{ apiUrl }}</span>
    </header>

    <main>
      <!-- <section class="card row">
        <button class="btn" @click="refreshCatalog" :disabled="refreshing">
          {{ refreshing ? 'Refreshing…' : 'Update Catalog' }}
        </button>

        <label class="row" style="gap:6px;align-items:center">
          <span class="muted">Page size</span>
          <input type="number" min="50" step="50" v-model.number="pageSize" class="input" style="width:120px" />
        </label>

        <span class="muted">
          Last refresh:
          {{ (lastRefresh && !Number.isNaN(Date.parse(lastRefresh)))
              ? new Date(lastRefresh).toLocaleString()
              : '—' }}
        </span>

        <span v-if="progress" class="pill">{{ progress }}</span>
      </section> -->

      <!-- Upload -->
      <section class="card">
        <h3 class="section-title">1) Upload Faire CSV</h3>
        <label for="csv" class="drop" @dragover.prevent @drop.prevent="onDrop">
          <input id="csv" type="file" accept=".csv" @change="onFile" />
          <div>Drop CSV here or click to choose</div>
        </label>
      </section>

      <!-- Preview -->
      <section class="card_a" v-if="preview">
        <h3 class="section-title">2) Preview</h3>

        <div class="row">
          <span class="pill">Matched: {{ (preview.matched || []).length }}</span>
          <span class="pill">Missing: {{ (preview.missing || []).length }}</span>
        </div>

        <!-- Matched -->
        <details class="details" open>
          <summary>Matched</summary>
          <div class="table-wrap">
            <table v-if="(preview.matched || []).length" class="grid-table">
              <thead>
                <tr>
                  <th>Select</th><th>SKU</th><th>Brand</th><th>Qty</th><th>Product</th><th>Wholesale Price</th><th>Supplier Code</th>
                </tr>
              </thead>
              <tbody>
                <!-- <tr v-for="(m,i) in preview.matched" :key="`mat-${i}-${m.sku||''}-${m.brand_name||''}`"> -->
                  <tr v-for="(m,i) in preview.matched" :key="i">
                  <td><input type="checkbox" v-model="m.selected" /></td>
                  <td class="mono">{{ m.sku || '—' }}</td>
                  <td>{{ m.brand.name }}</td>
                  <td>{{ m.quantity_f }}</td>
                  <td>
                    {{ m.product_name || m.product || m.name || '—' }}
                    <span class="muted mono" v-if="m.sku">({{ m.sku }})</span>
                  </td>
                  <td class="mono">{{ m.wholesale_price_f || '—' }}</td>
                  <td>{{ m.supplier_code || '—' }}</td>
                </tr>
              </tbody>
            </table>
            <div v-else class="muted">None.</div>
          </div>
        </details>

        <!-- Missing (editable) -->
        <details class="details" open>
          <summary>Missing (editable)</summary>
          <div class="table-wrap">
            <table v-if="(preview.missing || []).length" class="grid-table">
              <thead>
                <tr>
                  <th>Select</th><th>SKU</th><th>Brand</th><th>Qty</th><th>Product</th><th>Wholesale Price</th><th>Supplier Code</th>
                </tr>
              </thead>
              <tbody>
                <!-- <tr v-for="(m,i) in preview.missing" :key="`miss-${i}-${m.sku||''}-${m.brand_name||''}`"> -->
                  <tr v-for="(m,i) in preview.missing" :key="i">

                  <td><input type="checkbox" v-model="m.selected" /></td>

                  <!-- SKU -->
                  <td>
                    <input
                      class="cell-input mono autosize"
                      :style="autoWidthStyle(m.sku, 14, 26)"
                      v-model="m.sku"
                      :placeholder="m.sku ? '' : '(Auto Gen)'"
                      autocomplete="off"
                      spellcheck="false"
                    />
                  </td>

                  <!-- Brand -->
                  <td>
                    <input
                      class="cell-input autosize"
                      :style="autoWidthStyle(m.brand_name_f, 10, 32)"
                      v-model="m.brand_name_f"
                      placeholder="Brand"
                      autocomplete="off"
                      spellcheck="false"
                    />
                  </td>

                  <!-- Qty -->
                  <td>
                    <input
                      class="cell-input mono autosize"
                      :style="autoWidthStyle(String(m.quantity_f ?? ''), 3, 8)"
                      type="number"
                      min="0"
                      step="1"
                      v-model.number="m.quantity_f"
                      placeholder="Qty"
                    />
                  </td>

                  <!-- Product -->
                  <td class="wide">
                    <input
                      class="cell-input autosize"
                      :style="autoWidthStyle(m.product_name_f, 4,64)"
                      v-model="m.product_name_f"
                      placeholder="Product name"
                      autocomplete="off"
                      spellcheck="false"
                    />
                  </td>

                  <!-- Wholesale -->
                  <td>
                    <input
                      class="cell-input mono autosize"
                      :style="autoWidthStyle(formatMoney(m.wholesale_price_f), 6, 16)"
                      inputmode="decimal"
                      v-model="m.wholesale_price_f"
                      placeholder="0.00"
                      @blur="m.wholesale_price_f = formatMoney(m.wholesale_price)"
                    />
                  </td>

                  <!-- Supplier Code Upper Case SKU is from faire-->
                  <td>
                    <input
                      class="cell-input autosize"
                      :style="autoWidthStyle(m.SKU, 8, 32)" 
                      v-model="m.SKU"
                      placeholder="Supplier code"
                      autocomplete="off"
                      spellcheck="false"
                    />
                  </td>
                </tr>
              </tbody>
            </table>
            <div v-else class="muted">None.</div>
          </div>
        </details>

        <div class="row foot">
          <label class="muted"><input type="checkbox" v-model="autoCreate" /> Auto-create missing on submit</label>
          <button class="btn subtle" @click="submit" :disabled="submitting">{{ submitting ? 'Submitting…' : '3) Submit Order' }}</button>
        </div>
      </section>
    </main>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { inject } from 'vue'
const apiUrl = inject('API_URL')


// const apiUrl = (window.__APP_CONFIG__ && window.__APP_CONFIG__.API_URL) || 'http://localhost:8080'
// const apiUrl = getCurrentInstance().appContext.config.globalProperties.$apiUrl
const lastRefresh = ref(null)
const refreshing = ref(false)
const progress = ref('')
const preview = ref(null)
const autoCreate = ref(true)
const submitting = ref(false)
const pageSize = ref(60000)


let esRef = null

function refreshCatalog() {
  refreshing.value = true
  progress.value = ''
  const es = new EventSource(`${apiUrl}/catalog/refresh/stream?page_size=${encodeURIComponent(pageSize.value)}`)
  esRef = es

  es.addEventListener('progress', (e) => { progress.value = e.data })
  es.addEventListener('last_refresh', (e) => {
    try { lastRefresh.value = JSON.parse(e.data).iso || null } catch {}
  })
  es.addEventListener('done', () => { es.close(); esRef = null; refreshing.value = false })
  es.addEventListener('error', () => { es.close(); esRef = null; refreshing.value = false })
}

async function loadLastRefresh() {
  const r = await fetch(`${apiUrl}/catalog/last-refresh`)
  const j = await r.json()
  lastRefresh.value = j?.last_refresh?.iso || null
}

onMounted(loadLastRefresh)
onBeforeUnmount(() => { try { esRef?.close() } catch {} esRef = null })

function onDrop(e) {
  const f = e.dataTransfer.files?.[0]
  if (f) previewCsv(f)
}
function onFile(e) {
  const f = e.target.files?.[0]
  if (f) previewCsv(f)
}

async function previewCsv(file) {
  const form = new FormData()
  form.append('file', file, file.name)

  let j
  try {
    const r = await fetch(`${apiUrl}/orders/preview-csv`, { method: 'POST', body: form })
    j = await r.json()
  } catch (e) {
    console.error('Bad JSON from /orders/preview-csv', e)
    alert('Preview failed: invalid response')
    return
  }

  ;(j.matched ?? []).forEach(x => x.selected = true)
  ;(j.missing ?? []).forEach(x => x.selected = true)

  preview.value = j
  console.log('[previewCsv] matched:', j.matched)
  console.log('[previewCsv] missing:', j.missing)
}


function productName(row) {
  return row?.product_name || row?.product || row?.name || ''
}
function formatMoney(v) {
  if (v === null || v === undefined || v === '') return ''
  const num = parseFloat(String(v).replace(/[^0-9.-]+/g, ''))
  if (Number.isNaN(num)) return String(v)
  return num.toFixed(2)
}
function autoWidthStyle(val, minCh = 4, maxCh = 60) {
  const len = String(val ?? '').length || 0
  const ch = Math.max(minCh, Math.min(maxCh, len + 1))
  return { width: ch + 'ch' }
}

async function submit() {
  if (!preview.value) return
  submitting.value = true
  try {
    const items = [...(preview.value.matched || []), ...(preview.value.missing || [])]
      .filter(x => x.selected)
      .map(x => ({
        sku: x.sku ?? null,
        supplier_code: x.SKU != null ? String(x.SKU) : null,
        brand_name: x.brand_name_f ?? null,
        product_id: x.product_id || x.id || null,
        product_name: x.product_name_f ?? null,
        supplier_id: x.supplier_id || null,
        supplier_name: x.brand_name_f || null,
        quantity: x.quantity_f ?? null,
        order_number: x.order_number || null,
        wholesale_price: x.wholesale_price_f
          ? parseFloat(String(x.wholesale_price_f).replace(/[^0-9.-]+/g, ""))
          : null
      }))

    const payload = { items, auto_create_missing: autoCreate.value }
    const r = await fetch(apiUrl + '/orders/submit', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload)
    })

    if (!r.ok) {
      let msg = "Unknown error submitting order";
      try {
        const err = await r.json();
        msg = err.detail || msg;
      } catch {
        const txt = await r.text();
        msg = txt || msg;
      }
      alert(msg);   // 👈 user-facing popup
      console.error("Submit failed:", msg);
      return;
    }

    const j = await r.json()
    console.log("Submitted:", j)
    alert("Order submitted successfully!")   // optional success popup
  } catch (e) {
    console.error("Submit error:", e)
    alert("Network or JS error submitting order")
  } finally {
    submitting.value = false
  }
}

</script>

<style scoped>
/* ===== Base Dark Theme ===== */
.app {
  background: #0b0f14;  /* deep slate */
  color: #e5e7eb;
  min-height: 100%;
  padding: 8px;
}
.h2 { margin:0; font-weight:700; }
.row { display:flex; gap:12px; align-items:center; flex-wrap:wrap; }

.card {
  background: #0f1620;
  border: 1px solid #1f2937;
  border-radius: 12px;
  padding: 16px;
  box-shadow: 0 2px 0 rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.02);
}
.card_a {
  background: #0f1620;
  border: 1px solid #1f2937;
  border-radius: 12px;
  padding: 16px;
  box-shadow: 0 2px 0 rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.02);
  display:inline-flex;
  flex-direction:column;
  align-items:stretch;
  height:auto; 
}
/* section headings */
.section-title {
  margin: 0 0 10px 0;
  font-weight: 700;
  color: #cbd5e1;
}

/* Pills / badges */
.pill {
  display:inline-flex; align-items:center; gap:6px;
  background:#0b1220;
  border: 1px solid #263347;
  border-radius: 999px;
  padding: 4px 10px;
  font-size: 12px;
  color:#d1d5db;
}

/* Muted text */
.muted { color:#9aa4b2; }

/* Inputs (light on dark) */
.input, .cell-input {
  height: 34px;
  border: 1px solid #d1d5db;
  border-radius: 10px;
  padding: 0 10px;
  background: #ffffff;
  color: #0b0f14;
  font-size: 13px;
  outline: none;
  transition: box-shadow .15s, border-color .15s;
}
.cell-input:focus, .input:focus {
  border-color:#60a5fa;
  box-shadow: 0 0 0 3px rgba(96,165,250,.25);
}
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; }
.autosize { max-width: 100%; }

/* Buttons */
.btn {
  appearance: none;
  border: 1px solid #2b3648;
  background:#111827;
  color:#fff;
  padding: 8px 14px;
  border-radius: 10px;
  cursor:pointer;
  font-weight:700;
}
.btn:hover { background:#1b2433; }
.btn:disabled { opacity:.6; cursor:not-allowed; }
.btn.subtle { background:#0f172a; border-color:#283143; }
.btn.subtle:hover { background:#152037; }

/* Upload box */
.drop {
  display:block;
  border:1px dashed #2b3a4f;
  border-radius: 12px;
  padding: 32px;
  text-align:center;
  cursor:pointer;
  color:#a7b3c4;
  background: #0b1220;
}
.drop > input { display:none; }

/* Details headings to match screenshot */
.details > summary {
  cursor: pointer;
  font-weight: 700;
  color: #cbd5e1;
  padding: 6px 0;
  list-style: none;
}
.details > summary::-webkit-details-marker { display:none; }
.details[open] > summary { color:#e5e7eb; }

/* Table container uses flex (grows with inputs) */
/* .table-wrap {
  display:flex; align-items:stretch; overflow:auto;
  border-top: 1px solid #1e293b; margin-top:8px;
} */
.table-wrap {
  display: flex;
  align-items: stretch;
  overflow: visible;          /* was: overflow: auto */
  border-top: 1px solid #1e293b;
  margin-top: 8px;
}

/* Table aesthetic */
.grid-table {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
}
.grid-table thead th {
  position: sticky; top: 0;
  background: #0b1220;
  color:#a7b3c4;
  text-align:left; font-weight:700; font-size:13px;
  border-bottom: 1px solid #1f2a3b;
  padding:12px 10px;
  white-space:nowrap;
}
.grid-table tbody td {
  border-bottom: 1px solid #162233;
  padding:10px;
  vertical-align: middle;
  white-space: nowrap;
}
.grid-table tbody tr:hover td { background:#0f1728; }
.grid-table td.wide { min-width: 420px; }

/* Footer row spacing */
.foot { margin-top:12px; justify-content: space-between; width:100%; }

/* Checkboxes look nicer on dark */
input[type="checkbox"] {
  width: 16px; height: 16px;
}

</style>
