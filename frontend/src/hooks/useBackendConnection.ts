import { useEffect, useRef } from 'react'

/**
 * Hook that triggers a callback when the backend connection is established.
 * Useful for refetching data after the app reconnects to the backend.
 */
export function useOnBackendConnected(callback: () => void) {
  const callbackRef = useRef(callback)

  // Keep callback ref up to date
  useEffect(() => {
    callbackRef.current = callback
  }, [callback])

  useEffect(() => {
    const handleConnected = () => {
      callbackRef.current()
    }

    window.addEventListener('backend-connected', handleConnected)
    return () => {
      window.removeEventListener('backend-connected', handleConnected)
    }
  }, [])
}

/**
 * Hook that triggers a callback when the connected board's catalog
 * (patterns/playlists) is re-synced by the backend — fired off the status
 * stream's `catalog_version`. Use to refetch lists without a page reload.
 */
export function useOnCatalogChanged(callback: () => void) {
  const callbackRef = useRef(callback)

  useEffect(() => {
    callbackRef.current = callback
  }, [callback])

  useEffect(() => {
    const handleChanged = () => {
      callbackRef.current()
    }

    window.addEventListener('catalog-changed', handleChanged)
    return () => {
      window.removeEventListener('catalog-changed', handleChanged)
    }
  }, [])
}

/**
 * Hook that returns a function wrapped to also be called on backend reconnection.
 * Automatically calls the function on mount and whenever backend reconnects.
 */
export function useFetchOnConnect<T extends (...args: unknown[]) => unknown>(fetchFn: T): T {
  const fetchRef = useRef(fetchFn)

  useEffect(() => {
    fetchRef.current = fetchFn
  }, [fetchFn])

  // Call on backend connect
  useOnBackendConnected(() => {
    fetchRef.current()
  })

  return fetchFn
}
