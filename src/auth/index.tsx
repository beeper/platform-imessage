import path from 'path'
import url from 'url'
import React, { useState, useEffect, useRef, useCallback } from 'react'
import { Helmet } from 'react-helmet'
import cn from 'clsx'
import { AuthProps, texts } from '@textshq/platform-sdk'
import type { AuthType } from 'node-mac-permissions'
import type PAPI from '../api'

import { BINARIES_DIR_PATH, IS_BIG_SUR_OR_UP, IS_MOJAVE_OR_UP, IS_VENTURA_OR_UP } from '../constants'
import useAsync from './use-async'

const sleep = (ms: number) => new Promise(resolve => { setTimeout(resolve, ms) })

const sysPrefsAppName = IS_VENTURA_OR_UP ? 'System Settings' : 'System Preferences'

const staticPrefix = window.location.protocol === 'file:'
  ? url.pathToFileURL(BINARIES_DIR_PATH).href
  : './platform-imessage'
const cssPath = path.join(staticPrefix, 'imessage-auth.css')

const openSecuritySystemPrefs = (prefPath: string) =>
  window.open('x-apple.systempreferences:com.apple.preference.security?' + prefPath)

const openContactsPrefs = () => openSecuritySystemPrefs('Privacy_Contacts')

const openAXPrefs = () => openSecuritySystemPrefs('Privacy_Accessibility')

const openAutomationPrefs = () => openSecuritySystemPrefs('Privacy_Automation')

type AnyFunction = (...args: any[]) => any
type Async<F extends AnyFunction> = ReturnType<F> extends Promise<any>
  ? F
  : (...args: Parameters<F>) => Promise<ReturnType<F>>

type Promisified<T> = { [K in keyof T]: T[K] extends AnyFunction ? Async<T[K]> : never }

type NMP = Promisified<typeof import('node-mac-permissions')>

type CallProxiedFn = <ReturnType>(fnName: keyof PAPI['proxiedAuthFns']) => Promise<ReturnType>
type Props = AuthProps & {
  nmp?: NMP
  canAccessMessagesDir: () => Promise<boolean>
  callProxiedFn: CallProxiedFn
  open?: boolean
}

const useNMP = (nmp: NMP, authType: AuthType) => {
  const isAuthorized = useCallback(() => nmp.getAuthStatus(authType).then(res => res === 'authorized'), [])
  const { execute: refreshAuthorization, value: authorized, pending, error } = useAsync(isAuthorized)
  if (error) throw error
  useEffect(() => {
    window.addEventListener('focus', refreshAuthorization)
    return () => window.removeEventListener('focus', refreshAuthorization)
  }, [refreshAuthorization])
  useEffect(() => {
    let timeout: ReturnType<typeof setTimeout>
    async function checkIfAuthorized() {
      if (await isAuthorized()) {
        refreshAuthorization()
      } else {
        timeout = setTimeout(checkIfAuthorized, 1_000)
      }
    }
    checkIfAuthorized()
    return () => clearTimeout(timeout)
  }, [])
  console.log(authType, 'authorized', authorized)
  return { refreshAuthorization, authorized, pending }
}

const RevokeFDASection: React.FC<{ nmp: NMP, callProxiedFn: CallProxiedFn }> = ({ nmp, callProxiedFn }) => {
  const [hidden, setHidden] = useState(false)
  const isSIPEnabled = useCallback(() => callProxiedFn<boolean>('isSIPEnabled'), [])
  const isAuthorized = useCallback(() => nmp.getAuthStatus('full-disk-access').then(res => res === 'authorized'), [])
  const { execute: refreshAuthorization, value: authorized, pending } = useAsync(isAuthorized)
  const { value: sipEnabled } = useAsync(isSIPEnabled)
  // no FDA in 10.13 or earlier
  if (!IS_MOJAVE_OR_UP || !authorized || pending || !(sipEnabled ?? true) || hidden) return null
  const onClick = async () => {
    if (!await callProxiedFn('revokeFDA')) return
    setTimeout(() => {
      refreshAuthorization()
      if (texts.IS_DEV) setHidden(true)
    }, 100)
  }
  return (
    <details open>
      <summary><h4>Revoke Full Disk Access</h4></summary>
      <div className="imessage-auth-well">
        <div>Texts has Full Disk Access. It's no longer required and you're recommended to revoke it.</div>
        <br />
        <div>
          <button className="primary" onClick={onClick}>Revoke Full Disk Access</button>
        </div>
      </div>
    </details>
  )
}

const SetupMessagesSection: React.FC<{ callProxiedFn: CallProxiedFn }> = ({ callProxiedFn }) => {
  const isMessagesAppSetup = useCallback(() => callProxiedFn('isMessagesAppSetup'), [])
  const { value: isSetup, pending } = useAsync(isMessagesAppSetup)
  if (pending || isSetup) return null
  return (
    <details open>
      <summary><h4>Setup Messages.app</h4></summary>
      <div className="imessage-auth-well">
        <div>Messages.app isn't setup. Texts requires Messages.app to be setup first to connect iMessage.</div>
        <br />
        <div>
          <button className="primary" onClick={() => window.open('imessage://')}>Open Messages.app</button>
        </div>
      </div>
    </details>
  )
}
// const NotificationsIcon = (
//   <svg width="46" height="43" viewBox="0 0 46 43" fill="none">
//     <path d="M13.163 42.731C14.168 42.731 14.865 42.198 16.116 41.091L23.191 34.795H36.3571C42.4681 34.795 45.75 31.411 45.75 25.402V9.69299C45.75 3.68499 42.4681 0.300995 36.3571 0.300995H9.94299C3.83199 0.300995 0.549988 3.66399 0.549988 9.69299V25.403C0.549988 31.432 3.83199 34.795 9.94299 34.795H10.927V40.127C10.927 41.707 11.727 42.731 13.163 42.731V42.731ZM14.003 38.979V33.031C14.003 31.924 13.573 31.493 12.465 31.493H9.94299C5.79999 31.493 3.85303 29.381 3.85303 25.382V9.69299C3.85303 5.69399 5.79999 3.603 9.94299 3.603H36.3571C40.4791 3.603 42.447 5.69399 42.447 9.69299V25.382C42.447 29.381 40.4791 31.493 36.3571 31.493H23.068C21.92 31.493 21.345 31.657 20.566 32.457L14.004 38.979H14.003ZM23.15 21.239C24.134 21.239 24.709 20.686 24.73 19.619L25.016 8.791C25.036 7.766 24.216 6.966 23.129 6.966C22.022 6.966 21.243 7.746 21.263 8.771L21.53 19.619C21.55 20.665 22.125 21.239 23.15 21.239V21.239ZM23.15 27.904C24.34 27.904 25.365 26.981 25.365 25.771C25.365 24.582 24.36 23.659 23.15 23.659C21.94 23.659 20.935 24.603 20.935 25.771C20.935 26.961 21.961 27.904 23.15 27.904Z" fill="#EBA04F" />
//   </svg>
// )

const CompletedCheckIcon = (
  <svg width="1em" height="1em" viewBox="0 0 24 24" fill="none">
    <path d="M20.285 2L9 13.567L3.714 8.556L0 12.272L9 21L24 5.715L20.285 2Z" fill="white" />
  </svg>
)
const InfoIcon = (
  <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
    <path opacity="0.498" d="M6.10205 12.822C9.41205 12.822 12.1541 10.086 12.1541 6.76999C12.1541 3.45899 9.41195 0.71701 6.09595 0.71701C2.78595 0.71701 0.0489502 3.45899 0.0489502 6.76999C0.0489502 10.086 2.79105 12.822 6.10205 12.822ZM5.96704 7.98801C5.59204 7.98801 5.38696 7.807 5.38696 7.461V7.396C5.38696 6.84 5.70298 6.52901 6.13098 6.22501C6.65198 5.86701 6.90405 5.68 6.90405 5.293C6.90405 4.883 6.57598 4.59601 6.08398 4.59601C5.72098 4.59601 5.439 4.76601 5.229 5.10001L5.13501 5.229C5.07895 5.30847 5.0042 5.37292 4.91736 5.41669C4.83051 5.46046 4.73419 5.48222 4.63696 5.48001C4.57407 5.48135 4.51157 5.47005 4.45312 5.44678C4.39468 5.42351 4.34152 5.38875 4.29675 5.34454C4.25199 5.30034 4.21651 5.24757 4.1925 5.18942C4.1685 5.13127 4.15643 5.06892 4.15698 5.00601C4.15698 4.88901 4.17997 4.78899 4.21497 4.68399C4.40797 4.11499 5.11103 3.64099 6.16003 3.64099C7.24403 3.64099 8.15796 4.21501 8.15796 5.23401C8.15796 5.94401 7.76597 6.29401 7.16797 6.68201C6.76997 6.93901 6.55803 7.15001 6.53503 7.46701V7.53699C6.51803 7.78899 6.30104 7.98801 5.96704 7.98801V7.98801ZM5.95496 9.85199C5.56796 9.85199 5.23999 9.56399 5.23999 9.18399C5.23999 8.80299 5.56196 8.51001 5.95496 8.51001C6.35396 8.51001 6.67505 8.79699 6.67505 9.18399C6.67505 9.56999 6.34796 9.85199 5.95496 9.85199Z" fill="currentColor" />
  </svg>
)

type ChecklistItemProps = {
  title: string
  info: string
  completed: boolean
  action: () => void | Promise<void>
  icon: React.ReactNode
  more: React.ReactNode
  showMore?: boolean
}

const ChecklistItem = ({
  icon,
  title,
  completed,
  info,
  action,
  more,
  showMore,
  Tooltip,
}: ChecklistItemProps & { Tooltip: React.FC<any> }) => (
  <article>
    <div onClick={() => action()}>
      <span>
        {icon}
        {title}
      </span>
      <Tooltip
        position="top"
        tip={false}
        maxWidth={420}
        content={info}
      >
        <span className="info-icon">{InfoIcon}</span>
      </Tooltip>
      <div className={cn('check', { completed })}>{completed && CompletedCheckIcon}</div>
    </div>
    {showMore && <div className="more">{more}</div>}
  </article>
)

const ChecklistPage: React.FC<Props> = props => {
  const { nmp, callProxiedFn, canAccessMessagesDir, login } = props
  const { execute: refreshMessageDirAuthorization, value: messageDirAuthorized } = useAsync(canAccessMessagesDir)
  const askedContacts = useRef(false)
  const { authorized: contactsAuthorized, refreshAuthorization: refreshContactsAuthorization } = useNMP(nmp, 'contacts')
  const { authorized: axAuthorized, refreshAuthorization: refreshAXAuthorization } = useNMP(nmp, 'accessibility')
  const [automationAuthorized, setAutomationAuthorized] = useState(false)
  const [calledAutomationOnce, setCalledAutomationOnce] = useState(false)
  const [showMore, setShowMore] = useState(false)

  const authorizeContacts = async () => {
    if (askedContacts.current) return openContactsPrefs()
    if (axAuthorized) setTimeout(() => callProxiedFn('confirmUNCPrompt'), 1)
    await nmp.askForContactsAccess()
    askedContacts.current = true
  }

  const authorizeMessagesDir = async () => {
    await callProxiedFn('askForMessagesDirAccess')
    await refreshMessageDirAuthorization()
  }

  const authorizeAutomation = async () => {
    if (calledAutomationOnce) return openAutomationPrefs()
    if (axAuthorized) callProxiedFn('confirmUNCPrompt')
    setAutomationAuthorized(await callProxiedFn('askForAutomationAccess'))
    setCalledAutomationOnce(true)
  }

  const authorizeAX = () => {
    openAXPrefs()
    if (!axAuthorized && IS_BIG_SUR_OR_UP) callProxiedFn('startSysPrefsOnboarding')
  }

  // const revokeAll = () => {
  //   callProxiedFn('revokeAll')
  //   // prompt for app relaunch
  // }

  const checklistItems: ChecklistItemProps[] = [
    IS_BIG_SUR_OR_UP && {
      icon: <svg className="icon" viewBox="0 0 16 16" height="1em" width="1em"><path d="M8 4.143A1.071 1.071 0 1 0 8 2a1.071 1.071 0 0 0 0 2.143Zm-4.668 1.47 3.24.316v2.5l-.323 4.585A.383.383 0 0 0 7 13.14l.826-4.017c.045-.18.301-.18.346 0L9 13.139a.383.383 0 0 0 .752-.125L9.43 8.43v-2.5l3.239-.316a.38.38 0 0 0-.047-.756H3.379a.38.38 0 0 0-.047.756Z" /><path d="M8 0a8 8 0 1 0 0 16A8 8 0 0 0 8 0ZM1 8a7 7 0 1 1 14 0A7 7 0 0 1 1 8Z" /></svg>,
      title: 'Accessibility',
      completed: axAuthorized,
      action: authorizeAX,
      info: 'Required to power most iMessage functionality.',
      more: <div onClick={openAXPrefs}>Try: add <strong>Texts.app</strong> manually by clicking the + button and selecting <strong>Texts.app</strong> from your Applications folder &rarr;</div>,
      showMore,
    },
    {
      icon: <svg className="icon" viewBox="0 0 496 512" height="1em" width="1em"><path d="M248 104c-53 0-96 43-96 96s43 96 96 96 96-43 96-96-43-96-96-96zm0 144c-26.5 0-48-21.5-48-48s21.5-48 48-48 48 21.5 48 48-21.5 48-48 48zm0-240C111 8 0 119 0 256s111 248 248 248 248-111 248-248S385 8 248 8zm0 448c-49.7 0-95.1-18.3-130.1-48.4 14.9-23 40.4-38.6 69.6-39.5 20.8 6.4 40.6 9.6 60.5 9.6s39.7-3.1 60.5-9.6c29.2 1 54.7 16.5 69.6 39.5-35 30.1-80.4 48.4-130.1 48.4zm162.7-84.1c-24.4-31.4-62.1-51.9-105.1-51.9-10.2 0-26 9.6-57.6 9.6-31.5 0-47.4-9.6-57.6-9.6-42.9 0-80.6 20.5-105.1 51.9C61.9 339.2 48 299.2 48 256c0-110.3 89.7-200 200-200s200 89.7 200 200c0 43.2-13.9 83.2-37.3 115.9z" /></svg>,
      title: 'Contacts',
      completed: contactsAuthorized,
      action: authorizeContacts,
      info: 'Required to show names instead of phone numbers.',
      more: <div onClick={openContactsPrefs}>Try: open {sysPrefsAppName} and manually check <strong>Texts.app</strong> in the list &rarr;</div>,
      showMore,
    },
    IS_MOJAVE_OR_UP && {
      icon: <svg className="icon" viewBox="0 0 16 16" height="1em" width="1em"><path d="M3.904 1.777C4.978 1.289 6.427 1 8 1s3.022.289 4.096.777C13.125 2.245 14 2.993 14 4s-.875 1.755-1.904 2.223C11.022 6.711 9.573 7 8 7s-3.022-.289-4.096-.777C2.875 5.755 2 5.007 2 4s.875-1.755 1.904-2.223Z" /><path d="M2 6.161V7c0 1.007.875 1.755 1.904 2.223C4.978 9.71 6.427 10 8 10s3.022-.289 4.096-.777C13.125 8.755 14 8.007 14 7v-.839c-.457.432-1.004.751-1.49.972C11.278 7.693 9.682 8 8 8s-3.278-.307-4.51-.867c-.486-.22-1.033-.54-1.49-.972Z" /><path d="M2 9.161V10c0 1.007.875 1.755 1.904 2.223C4.978 12.711 6.427 13 8 13s3.022-.289 4.096-.777C13.125 11.755 14 11.007 14 10v-.839c-.457.432-1.004.751-1.49.972-1.232.56-2.828.867-4.51.867s-3.278-.307-4.51-.867c-.486-.22-1.033-.54-1.49-.972Z" /><path d="M2 12.161V13c0 1.007.875 1.755 1.904 2.223C4.978 15.711 6.427 16 8 16s3.022-.289 4.096-.777C13.125 14.755 14 14.007 14 13v-.839c-.457.432-1.004.751-1.49.972-1.232.56-2.828.867-4.51.867s-3.278-.307-4.51-.867c-.486-.22-1.033-.54-1.49-.972Z" /></svg>,
      title: 'Messages Data',
      completed: messageDirAuthorized,
      action: authorizeMessagesDir,
      info: 'Required to fetch and display threads and messages.',
      more: <div onClick={() => nmp.askForFullDiskAccess()}>Try: give <strong>Texts.app</strong> Full Disk Access in {sysPrefsAppName} &rarr;</div>,
      showMore,
    },
    IS_MOJAVE_OR_UP && {
      icon: <svg className="icon" viewBox="0 0 16 16" height="1em" width="1em"><path d="M9.405 1.05c-.413-1.4-2.397-1.4-2.81 0l-.1.34a1.464 1.464 0 0 1-2.105.872l-.31-.17c-1.283-.698-2.686.705-1.987 1.987l.169.311c.446.82.023 1.841-.872 2.105l-.34.1c-1.4.413-1.4 2.397 0 2.81l.34.1a1.464 1.464 0 0 1 .872 2.105l-.17.31c-.698 1.283.705 2.686 1.987 1.987l.311-.169a1.464 1.464 0 0 1 2.105.872l.1.34c.413 1.4 2.397 1.4 2.81 0l.1-.34a1.464 1.464 0 0 1 2.105-.872l.31.17c1.283.698 2.686-.705 1.987-1.987l-.169-.311a1.464 1.464 0 0 1 .872-2.105l.34-.1c1.4-.413 1.4-2.397 0-2.81l-.34-.1a1.464 1.464 0 0 1-.872-2.105l.17-.31c.698-1.283-.705-2.686-1.987-1.987l-.311.169a1.464 1.464 0 0 1-2.105-.872l-.1-.34zM8 10.93a2.929 2.929 0 1 1 0-5.86 2.929 2.929 0 0 1 0 5.858z" /></svg>,
      title: 'Automation',
      completed: automationAuthorized,
      action: authorizeAutomation,
      info: 'Required to send messages.',
      more: <div onClick={openAutomationPrefs}>Try: open {sysPrefsAppName} and manually check <strong>Texts.app</strong> in the list &rarr;</div>,
      showMore,
    },
  ].filter(Boolean)

  const allAuthorized = checklistItems.every(i => i.completed)
  const nextUncompletedItem = checklistItems.find(i => !i.completed)

  useEffect(() => {
    if (axAuthorized) {
      callProxiedFn('stopSysPrefsOnboarding')
    }
  }, [axAuthorized])

  useEffect(() => {
    const onKeyDown = (ev: KeyboardEvent) => {
      if (['Enter', ' ', 'ArrowRight'].includes(ev.key)) {
        ev.preventDefault()
        if (nextUncompletedItem) nextUncompletedItem.action()
        else login()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [nextUncompletedItem])

  useEffect(() => {
    if (allAuthorized) {
      login()
    }
  }, [allAuthorized])

  const authorizeAll = async () => {
    const uncompletedItems = checklistItems.filter(i => !i.completed)
    for (const item of uncompletedItems) {
      await item.action()
      await sleep(50)
    }
  }
  const permissionsSection = () => (
    <div className="fake-details permissions-section">
      <div className="fake-summary">
        <h4>
          <svg fill="currentColor" viewBox="0 0 448 512" height="1em" width="1em"><path d="M400 224h-24v-72C376 68.2 307.8 0 224 0S72 68.2 72 152v72H48c-26.5 0-48 21.5-48 48v192c0 26.5 21.5 48 48 48h352c26.5 0 48-21.5 48-48V272c0-26.5-21.5-48-48-48zm-104 0H152v-72c0-39.7 32.3-72 72-72s72 32.3 72 72v72z" /></svg>
          Permissions
        </h4>
        {!showMore && <div onClick={() => setShowMore(true)} className="show-more-button">Need help?</div>}
      </div>
      <div className="imessage-auth-well">
        {checklistItems.map(i => <ChecklistItem {...i} Tooltip={props.Tooltip} />)}
        {nextUncompletedItem && (
          <div>
            <button className="primary" onClick={axAuthorized ? authorizeAll : () => nextUncompletedItem.action()}>Authorize</button>
          </div>
        )}
        {/* {showMore && <div className="show-more-button"><button onClick={revokeAll}>Revoke all permissions</button></div>} */}
      </div>
    </div>
  )

  return (
    <div>
      <RevokeFDASection {...{ nmp, callProxiedFn }} />
      {messageDirAuthorized && <SetupMessagesSection {...{ callProxiedFn }} />}
      {allAuthorized ? 'Adding...' : permissionsSection()}
    </div>
  )
}

const AppleiMessageAuth: React.FC<AuthProps & { nmp?: NMP }> = props => {
  const { api } = props
  const callProxiedFn = useCallback(async (fnName: string) => JSON.parse(await api.getAsset(null, 'proxied', fnName) as string), [])
  const canAccessMessagesDir = useCallback(async () => callProxiedFn('canAccessMessagesDir'), [])
  return (
    <div className="auth imessage-auth styled-inputs">
      <Helmet>
        <link rel="stylesheet" href={cssPath} />
      </Helmet>
      <ChecklistPage {...{ ...props, canAccessMessagesDir, callProxiedFn }} />
    </div>
  )
}

export default AppleiMessageAuth
