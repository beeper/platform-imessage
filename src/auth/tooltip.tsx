import {
  useMemo,
  useState,
  useRef,
  useCallback,
  useEffect,
  CSSProperties,
} from 'react'
import { createPortal } from 'react-dom'
import cn from 'clsx'
import { throttle } from 'lodash'

function useDebouncedCallback<T extends (...args: any[]) => any>(
  callback: T,
  delay: number,
  options: { maxWait?: number, leading?: boolean } = {}): [T, () => void, () => void] {
  const { maxWait } = options
  const maxWaitHandler = useRef(null)
  const maxWaitArgs: { current: any[] } = useRef([])

  const { leading } = options
  const wasLeadingCalled: { current: boolean } = useRef(false)

  const functionTimeoutHandler = useRef(null)
  const isComponentUnmounted: { current: boolean } = useRef(false)

  const debouncedFunction = useRef(callback)
  debouncedFunction.current = callback

  const cancelDebouncedCallback: () => void = useCallback(() => {
    clearTimeout(functionTimeoutHandler.current as any)
    clearTimeout(maxWaitHandler.current as any)
    maxWaitHandler.current = null
    maxWaitArgs.current = []
    functionTimeoutHandler.current = null
    wasLeadingCalled.current = false
  }, [])

  useEffect(
    () => () => {
      // we use flag, as we allow to call callPending outside the hook
      isComponentUnmounted.current = true
    },
    [],
  )

  const debouncedCallback = useCallback(
    (...args) => {
      maxWaitArgs.current = args
      clearTimeout(functionTimeoutHandler.current as any)

      if (
        !functionTimeoutHandler.current
        && leading
        && !wasLeadingCalled.current
      ) {
        debouncedFunction.current(...args)
        wasLeadingCalled.current = true
        return
      }

      (functionTimeoutHandler.current as any) = setTimeout(() => {
        cancelDebouncedCallback()

        if (!isComponentUnmounted.current) {
          debouncedFunction.current(...args)
        }
      }, delay)

      if (maxWait && !maxWaitHandler.current) {
        (maxWaitHandler.current as any) = setTimeout(() => {
          const _args = maxWaitArgs.current
          cancelDebouncedCallback()

          if (!isComponentUnmounted.current) {
            debouncedFunction.current.apply(null, _args)
          }
        }, maxWait)
      }
    },
    [maxWait, delay, cancelDebouncedCallback, leading],
  )

  const callPending = () => {
    // Call pending callback only if we have anything in our queue
    if (!functionTimeoutHandler.current) {
      return
    }

    debouncedFunction.current.apply(null, maxWaitArgs.current)
    cancelDebouncedCallback()
  }

  // At the moment, we use 3 args array so that we save backward compatibility
  return [debouncedCallback as T, cancelDebouncedCallback, callPending]
}

let i = 0
const genId = () => ++i

const useID = (prefix?: string) => {
  const [id, setId] = useState('')
  useEffect(() => setId(`${prefix || ''}${genId()}`), [prefix])
  return id
}

export type Position = 'top' | 'bottom' | 'left' | 'right'

interface TooltipProps {
  content: React.ReactNode
  position?: Position
  maxWidth?: number
  wrap?: boolean
  delay?: boolean
  delayTime?: number
  center?: boolean
  cursor?: CSSProperties['cursor']
  padding?: string | number
  tip?: boolean
  style?: CSSProperties
  shown?: number
  disableHover?: boolean
  className?: string
}

const rootStore = (window as any).rs

const Tooltip: React.FC<TooltipProps> = ({
  content,
  position = 'top',
  tip = true,
  delay = true,
  delayTime = 0,
  center = true,
  cursor,
  wrap = true,
  maxWidth = 200,
  padding,
  style,
  shown = 0,
  disableHover,
  className,
  children,
}) => {
  const { layoutStore } = rootStore
  // visible is 2-bit number: <focused><hovered>
  const [visible, setVisible] = useState(shown)
  const [coordinates, setCoordinates] = useState({
    top: 0,
    left: 0,
    width: 0,
    height: 0,
  })
  const tooltipRef = useRef<HTMLSpanElement>(null)

  // Unique ID for a11y attributes
  const id = `tooltip-${useID()}`

  const calculateSize = useCallback(() => {
    if (tooltipRef && tooltipRef.current) {
      const c = tooltipRef.current.getBoundingClientRect()
      const { height, width } = c
      let { top, left } = c

      top += window.scrollY
      left += window.scrollX

      const leftEdge = left - maxWidth
      const leftEdgeOverflow = leftEdge < layoutStore.viewportSize.width ? leftEdge : 0
      const rightEdge = (left + maxWidth)
      const rightEdgeOverflow = rightEdge > layoutStore.viewportSize.width ? rightEdge - layoutStore.viewportSize.width : 0

      let leftPosition = left

      if (['right', 'bottom', 'top'].includes(position)) {
        if (rightEdgeOverflow > 0) {
          leftPosition = (left - rightEdgeOverflow / 2)
        }
        if (leftEdgeOverflow < 0) {
          leftPosition = (left - leftEdgeOverflow / 2)
        }
      }

      setCoordinates({
        // eslint-disable-next-line no-nested-ternary
        top: position === 'bottom' && tip
          ? top - 5
          : top,
        left: leftPosition,
        height,
        width,
      })
    }
  }, [setCoordinates])

  const show = useCallback(
    t => {
      calculateSize()
      setVisible(v => v | t)
    },
    [calculateSize],
  )

  const [debouncedShow, cancelShow] = useDebouncedCallback(show, delayTime)

  const hide = useCallback(
    t => {
      cancelShow()
      setVisible(v => v & ~t)
    },
    [cancelShow],
  )

  const onKeyDown = useCallback(
    e => {
      if (e.key === 'Escape') {
        // dismiss both
        hide(3)
      }
    },
    [hide],
  )

  const onResize = useCallback(throttle(calculateSize, 150), [calculateSize])

  useEffect(() => {
    const cleanup = () => {
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('resize', onResize)
    }

    if (visible > 0) {
      window.addEventListener('keydown', onKeyDown)
      window.addEventListener('resize', onResize)
    } else {
      cleanup()
    }

    return cleanup
  }, [onKeyDown, onResize, visible])

  const transform = useMemo(() => {
    switch (position) {
      case 'top':
        return `translate(
          calc(-50% + ${Math.ceil(coordinates.width / 2)}px),
          calc(-100% - 10px)
        )`
      case 'bottom':
        return `translate(
          calc(-50% + ${Math.ceil(coordinates.width / 2)}px),
          calc(${~~coordinates.height}px)
        )`
      case 'left':
        return `translate(
          calc(-100% - 10px),
          calc(-50% + ${Math.ceil(coordinates.height / 2)}px)
        )`
      case 'right':
        return `translate(
          calc(${Math.ceil(coordinates.width)}px + 10px),
          calc(-50% + ${Math.ceil(coordinates.height / 2)}px)
        )`
      default:
        return ''
    }
  }, [position, coordinates])

  return (
    <span
      onMouseEnter={delayTime ? () => debouncedShow(1) : () => show(1)}
      onFocus={ev => {
        // some other element inside the tooltip was focused
        // but it won't trigger the blur event so it should be ignored
        if (ev.target !== tooltipRef.current) {
          return
        }
        show(2)
      }}
      onMouseLeave={() => hide(1)}
      onBlur={() => hide(2)}
      ref={tooltipRef}
      aria-describedby={visible ? id : undefined}
      className={cn('tooltip-wrapper', className)}
      style={{ cursor, ...style }}
    >
      {visible > 0 && (
        createPortal(
          <div
            className={cn(
              'tooltip',
              {
                'tooltip-top': position === 'top',
                'tooltip-left': position === 'left',
                'tooltip-right': position === 'right',
                'tooltip-bottom': position === 'bottom',
                'tooltip-delay': delay,
                'tooltip-tip': tip,
                'tooltip-wrap': wrap,
                'tooltip-center': center,
              },
            )}
            role="tooltip"
            id={id}
            style={{
              padding,
              maxWidth,
              transform,
              top: coordinates.top,
              left: coordinates.left,
              pointerEvents: disableHover ? 'none' : 'all',
            }}
          >
            {tip && <i className="triangle" />}
            {content}
          </div>,
          rootStore.layoutStore.portalRoot,
        )
      )}
      {children}
    </span>
  )
}

export default Tooltip
