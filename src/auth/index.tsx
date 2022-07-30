import path from 'path'
import url from 'url'
import bluebird from 'bluebird'
import React, { useState, useEffect, useRef, useCallback } from 'react'
import { Helmet } from 'react-helmet'
import cn from 'clsx'
import type { AuthType } from 'node-mac-permissions'
import { AuthProps, texts } from '@textshq/platform-sdk'
import type PAPI from '../api'

import { IS_BIG_SUR_OR_UP, IS_MOJAVE_OR_UP, BINARIES_DIR_PATH, IS_MONTEREY_OR_UP } from '../constants'
import useAsync from './use-async'

const staticPrefix = window.location.protocol === 'file:'
  ? url.pathToFileURL(BINARIES_DIR_PATH).href
  : './platform-imessage'
const notificationsMessagesImg = path.join(staticPrefix, 'notifications-messages.png')
const cssPath = path.join(staticPrefix, 'imessage-auth.css')

const openSecuritySystemPrefs = (prefPath: string) =>
  window.open('x-apple.systempreferences:com.apple.preference.security?' + prefPath)

const openNotificationsSystemPrefs = () =>
  window.open('x-apple.systempreferences:com.apple.preference.notifications')

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
  nmp: NMP
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
  more: React.ReactNode
  showMore?: boolean
}

const ChecklistItem = ({
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
      <div className={cn('check', { completed })}>{completed && CompletedCheckIcon}</div>
      <span>{title}</span>
      <Tooltip
        position="top"
        tip={false}
        maxWidth={420}
        content={<span>{info}</span>}
      >
        <span className="info-icon">{InfoIcon}</span>
      </Tooltip>
    </div>
    {showMore && <div className="more">{more}</div>}
  </article>
)

const NotificationsSection: React.FC<Props> = ({ open, callProxiedFn, nmp }) => {
  const { authorized: axAuthorized } = useNMP(nmp, 'accessibility')
  const [done, setDone] = useState(false)

  const canDisableNotifs = IS_BIG_SUR_OR_UP && axAuthorized
  const text = canDisableNotifs
    ? "Both Texts and Messages will notify you for new messages. Texts can disable notifications for Messages.app so you don't get duplicate notifications."
    : 'Both Texts and Messages will notify you for new messages. You can optionally disable notifications for Messages.app to not get duplicate notifications.'

  return (
    <details open={open} className="notifications-section">
      <summary><h4>Double Notifications</h4></summary>
      <div className="imessage-auth-well">
        <div>
          {text}
        </div>

        <br />

        {!canDisableNotifs && (
          <img src={notificationsMessagesImg} alt="System Preferences – Notifications" width={400} onClick={() => openNotificationsSystemPrefs()} />
        )}

        <div className="buttons">
          {canDisableNotifs ? (
            <button
              className="primary"
              onClick={() => {
                callProxiedFn('disableMessagesNotifications')
                setDone(true)
              }}
              disabled={done}
            >
              Disable{done ? 'd' : ''} Messages.app Notifications
            </button>
          ) : (
            <button type="button" onClick={() => openNotificationsSystemPrefs()}>Open Notification Preferences</button>
          )}
        </div>
      </div>
    </details>
  )
}

const AddAccountSection: React.FC<Pick<Props, 'login' | 'isReauthing'> & { buttonDisabled: boolean }> = ({ buttonDisabled, login, isReauthing }) => (
  <div className="imessage-auth-well" style={{ borderRadius: 8 }}>
    <div className="buttons">
      <button type="button" className="primary" disabled={buttonDisabled} onClick={() => login()}>{isReauthing ? 'Reauthenticate' : 'Add'} iMessage account</button>
    </div>
  </div>
)

const knownIssues = [
  'Messages.app will be open in the background but Texts can keep it hidden.',
  ...(() => {
    if (IS_MONTEREY_OR_UP) return ["Reacting/replying to some types of messages isn't supported."]
    if (IS_BIG_SUR_OR_UP) return ["On macOS Big Sur, reacting/replying to non-text messages isn't supported. We recommend updating to the latest macOS."]
    return ["On macOS Catalina and lower: mark as read, typing indicator and reactions aren't supported. We recommend updating to the latest macOS."]
  })(),
].map((issue, i) => <li key={issue}>{i + 1}. {issue}</li>)

const KnownIssuesSection: React.FC<{ open: boolean }> = ({ open }) => (
  <details open={open} className="known-issues-section">
    <summary><h4>Known Issues</h4></summary>
    <div className="imessage-auth-well">
      <ul>{knownIssues}</ul>
    </div>
  </details>
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
    if (axAuthorized) setTimeout(() => callProxiedFn('confirmUNCPrompt'), 1)
    setAutomationAuthorized(await callProxiedFn('askForAutomationAccess'))
    setCalledAutomationOnce(true)
  }

  const authorizeAX = () => {
    openAXPrefs()
    if (!axAuthorized) callProxiedFn('startSysPrefsOnboarding')
  }

  // const revokeAll = () => {
  //   callProxiedFn('revokeAll')
  //   // prompt for app relaunch
  // }

  const checklistItems: ChecklistItemProps[] = [
    IS_BIG_SUR_OR_UP && {
      title: 'Accessibility',
      completed: axAuthorized,
      action: authorizeAX,
      info: 'Accessibility access allows Texts to power many iMessage features.',
      more: <div onClick={openAXPrefs}>Try: add <strong>Texts.app</strong> manually by clicking the + button and selecting <strong>Texts.app</strong> from your Applications folder &rarr;</div>,
      showMore,
    },
    {
      title: 'Contacts',
      completed: contactsAuthorized,
      action: authorizeContacts,
      info: 'Contacts access allows Texts to show names instead of phone numbers.',
      more: <div onClick={openContactsPrefs}>Try: open System Preferences and manually check <strong>Texts.app</strong> in the list &rarr;</div>,
      showMore,
    },
    IS_MOJAVE_OR_UP && {
      title: 'Messages Data',
      completed: messageDirAuthorized,
      action: authorizeMessagesDir,
      info: 'Messages data access allows Texts to show threads and messages. Your data never touches our servers.',
      more: <div onClick={() => nmp.askForFullDiskAccess()}>Try: give <strong>Texts.app</strong> Full Disk Access in System Preferences &rarr;</div>,
      showMore,
    },
    IS_MOJAVE_OR_UP && {
      title: 'Automation',
      completed: automationAuthorized,
      action: authorizeAutomation,
      info: 'Automation access allows Texts to send iMessages.',
      more: <div onClick={openAutomationPrefs}>Try: open System Preferences and manually check <strong>Texts.app</strong> in the list &rarr;</div>,
      showMore,
    },
  ].filter(Boolean)

  const allAuthorized = checklistItems.every(i => i.completed)

  useEffect(() => {
    if (axAuthorized) {
      callProxiedFn('stopSysPrefsOnboarding')
    }
  }, [axAuthorized])

  const nextUncompletedItem = checklistItems.find(i => !i.completed)

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

  const authorizeAll = async () => {
    const uncompletedItems = checklistItems.filter(i => !i.completed)
    for (const item of uncompletedItems) {
      await item.action()
      await bluebird.delay(50)
    }
  }

  return (
    <div>
      <RevokeFDASection {...{ nmp, callProxiedFn }} />
      {messageDirAuthorized && <SetupMessagesSection {...{ callProxiedFn }} />}
      <details open={!allAuthorized} className="permissions-section">
        <summary><h4>Permissions{allAuthorized ? ' (Authorized)' : ''}</h4></summary>
        <div className="imessage-auth-well">
          {checklistItems.map(i => <ChecklistItem {...i} Tooltip={props.Tooltip} />)}
          {nextUncompletedItem && (
            <div>
              {axAuthorized
                ? <button className="primary" onClick={authorizeAll}>Authorize All</button>
                : <button className="primary" onClick={() => nextUncompletedItem.action()}>Authorize {nextUncompletedItem.title}</button>}
            </div>
          )}
          {!showMore && <div onClick={() => setShowMore(true)} className="show-more-button">Having issues?</div>}
          {/* {showMore && <div className="show-more-button"><button onClick={revokeAll}>Revoke all permissions</button></div>} */}
        </div>
      </details>
      <KnownIssuesSection open={!allAuthorized} />
      <NotificationsSection open={allAuthorized} {...props} />
      <AddAccountSection {...props} buttonDisabled={!messageDirAuthorized} />
    </div>
  )
}

const AppleiMessageAuth: React.FC<AuthProps & { nmp: NMP }> = props => {
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
