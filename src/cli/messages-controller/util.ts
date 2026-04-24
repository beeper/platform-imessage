type Awaitable<T> = T | Promise<T>

export function measure<T>(fn: () => Promise<T>): Promise<[T, number]>
export function measure<T>(fn: () => T): [T, number]
export function measure<T>(fn: () => Awaitable<T>): Promise<[T, number]> | [T, number] {
  const start = performance.now()
  const work = fn()

  if (typeof work === 'object' && work !== null && 'then' in work) {
    return work.then(result => {
      const end = performance.now()
      return [result, end - start]
    })
  }

  const end = performance.now()
  return [work, end - start]
}
