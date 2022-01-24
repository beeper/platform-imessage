import { useState, useCallback, useEffect } from 'react'

// from https://usehooks.com/
const useAsync = <T>(asyncFunction: (...args: any[]) => Promise<T>, immediate = true) => {
  const [pending, setPending] = useState(false)
  const [value, setValue] = useState<T>(null)
  const [error, setError] = useState<Error>(null)

  // The execute function wraps asyncFunction and
  // handles setting state for pending, value, and error.
  // useCallback ensures the below useEffect is not called
  // on every render, but only if asyncFunction changes.
  const execute = useCallback((...args) => {
    setPending(true)
    setValue(null)
    setError(null)
    return asyncFunction(...args)
      .then((response: any) => setValue(response))
      .catch((err: Error) => setError(err))
      .finally(() => setPending(false))
  }, [asyncFunction])

  // Call execute if we want to fire it right away.
  // Otherwise execute can be called later, such as
  // in an onClick handler.
  useEffect(() => {
    if (immediate) {
      execute()
    }
  }, [execute, immediate])

  return { execute, pending, value, error }
}

export default useAsync
