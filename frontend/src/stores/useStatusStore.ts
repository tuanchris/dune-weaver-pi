import { create } from 'zustand'
import { apiClient } from '@/lib/apiClient'

export interface StatusData {
  current_file: string | null
  is_paused: boolean
  is_running: boolean
  is_alarm: boolean
  is_homing: boolean
  is_clearing: boolean
  sensor_homing_failed: boolean
  progress: {
    current: number
    total: number
    remaining_time: number | null
    elapsed_time: number
    percentage: number
    last_completed_time?: {
      actual_time_seconds: number
      actual_time_formatted: string
      timestamp: string
    }
  } | null
  playlist: {
    current_index: number
    total_files: number
    mode: string
    next_file: string | null
    // Just-finished pattern = what is drawn on the table now. Only meaningful
    // (and only shown) during the between-patterns pause. null = unknown.
    last_file: string | null
    files: string[]
    name: string | null
    // Firmware-side shuffle: the played order is unknown to the host, so the
    // queue list shows contents, not order.
    shuffled?: boolean
  } | null
  speed: number
  pause_time_remaining: number
  original_pause_time: number | null
  connection_status: boolean
  current_theta: number
  current_rho: number
  firmware_version: string | null
  table_type: string | null
  // Bumped by the backend whenever the connected board's cached catalog
  // (patterns/playlists) is re-synced. The frontend watches it to refetch the
  // lists without a manual page reload.
  catalog_version?: number
  // Board health telemetry from /sand_status (firmware API.md). Fields are
  // null on older firmware that doesn't report them.
  health?: {
    heap: number | null
    heap_min: number | null
    heap_largest: number | null
    last_reset: string | null
    sd_ok: boolean | null
    uptime: number | null
  } | null
}

interface StatusStore {
  isBackendConnected: boolean
  connectionAttempts: number
  status: StatusData | null
}

export const useStatusStore = create<StatusStore>()(() => ({
  isBackendConnected: false,
  connectionAttempts: 0,
  status: null,
}))

// --- Module-level WebSocket lifecycle (singleton, outside React) ---

let ws: WebSocket | null = null
let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
let isStopped = false
// Last catalog_version seen on the status stream. When it changes the board's
// pattern/playlist catalog was (re)synced, so pages refetch. null = not yet
// seen (also reset on table switch) so the first value never looks like a change.
let lastCatalogVersion: number | null = null

function connectWebSocket() {
  if (isStopped) return

  // Don't interrupt an existing connection that's still connecting
  if (ws) {
    if (ws.readyState === WebSocket.CONNECTING) return
    if (ws.readyState === WebSocket.OPEN) ws.close()
    ws = null
  }

  const socket = new WebSocket(apiClient.getWebSocketUrl('/ws/status'))
  ws = socket

  socket.onopen = () => {
    if (isStopped) {
      socket.close()
      return
    }
    useStatusStore.setState({ isBackendConnected: true, connectionAttempts: 0 })
    window.dispatchEvent(new CustomEvent('backend-connected'))
  }

  socket.onmessage = (event) => {
    if (isStopped) return
    try {
      const data = JSON.parse(event.data)
      if (data.type === 'status_update' && data.data) {
        useStatusStore.setState({ status: data.data })
        const version = data.data.catalog_version
        if (typeof version === 'number') {
          // Refetch when the catalog changed. On the FIRST observation, a
          // non-zero version means a sync already completed — possibly after
          // the connect-time fetch read an empty catalog — so refetch to be
          // safe; a zero baseline (no sync yet) just primes and the later
          // 0 -> 1 bump fires.
          const changed =
            lastCatalogVersion === null ? version > 0 : version !== lastCatalogVersion
          lastCatalogVersion = version
          if (changed) {
            window.dispatchEvent(new CustomEvent('catalog-changed'))
          }
        }
      }
    } catch {
      // Ignore parse errors
    }
  }

  socket.onclose = () => {
    if (isStopped) return
    ws = null
    useStatusStore.setState((prev) => ({
      isBackendConnected: false,
      connectionAttempts: prev.connectionAttempts + 1,
    }))
    reconnectTimeout = setTimeout(connectWebSocket, 3000)
  }

  socket.onerror = () => {
    if (isStopped) return
    useStatusStore.setState({ isBackendConnected: false })
  }
}

// Reconnect on table switch
apiClient.onBaseUrlChange(() => {
  useStatusStore.setState({ status: null, isBackendConnected: false })
  if (reconnectTimeout) {
    clearTimeout(reconnectTimeout)
    reconnectTimeout = null
  }
  // Close existing and reconnect
  if (ws) {
    if (ws.readyState === WebSocket.OPEN) ws.close()
    ws = null
  }
  connectWebSocket()
})

// Start connection immediately at module load
connectWebSocket()

// --- Playback transition detection ---

let wasPlaying: boolean | null = null

useStatusStore.subscribe((state) => {
  const s = state.status
  if (!s) return

  const isPlaying =
    Boolean(s.current_file) ||
    Boolean(s.is_running) ||
    Boolean(s.is_paused) ||
    (s.pause_time_remaining ?? 0) > 0

  // Skip first message (page refresh) - only react to transitions
  if (wasPlaying !== null) {
    if (isPlaying && !wasPlaying) {
      window.dispatchEvent(new CustomEvent('playback-started'))
    }
  }
  wasPlaying = isPlaying
})

// Reset wasPlaying on table switch so we don't fire false transitions
apiClient.onBaseUrlChange(() => {
  wasPlaying = null
})

// Reset the catalog baseline on table switch: the new board's version is
// unrelated to the old one, so re-prime rather than fire a spurious change.
apiClient.onBaseUrlChange(() => {
  lastCatalogVersion = null
})

// For HMR / cleanup in tests
export function _stopStatusWebSocket() {
  isStopped = true
  if (reconnectTimeout) clearTimeout(reconnectTimeout)
  if (ws && ws.readyState === WebSocket.OPEN) ws.close()
  ws = null
}
