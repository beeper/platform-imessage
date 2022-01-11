import path from 'path'
import url from 'url'
import { createElement, useState, useEffect, useRef, useCallback } from 'react'
import { Helmet } from 'react-helmet'
import cn from 'clsx'
import type { AuthType } from 'node-mac-permissions'
import type { PlatformAPI } from '@textshq/platform-sdk'

import { IS_BIG_SUR_OR_UP, IS_MOJAVE_OR_UP, BINARIES_DIR_PATH, IS_MONTEREY_OR_UP } from './constants'
import useAsync from './use-async'

declare const __IS_BROWSER__: boolean

if (typeof globalThis.__IS_BROWSER__ === 'undefined') globalThis.__IS_BROWSER__ = false

const contactsImgPrefix = IS_BIG_SUR_OR_UP ? 'img/bigsur' : 'img/catalina'
const contactsImg = `${contactsImgPrefix}-contacts-allow.png`
const contactsHighlightedImg = `${contactsImgPrefix}-contacts-allow-highlighted.png`

const staticPrefix = __IS_BROWSER__ ? './platform-imessage' : url.pathToFileURL(BINARIES_DIR_PATH).href
const staticImgPrefix = `${staticPrefix}/${IS_BIG_SUR_OR_UP ? 'bigsur' : 'catalina'}`
const axImg = path.join(staticImgPrefix, 'ax.png')
const axHighlightedImg = path.join(staticImgPrefix, 'ax-highlighted.png')
const automationAccessHighlightedImg = path.join(staticImgPrefix, 'automation-messages-highlighted.png')
const automationAccessImg = path.join(staticImgPrefix, 'automation-messages.png')
const notificationsMessagesImg = path.join(staticImgPrefix, 'notifications-messages.png')
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

type PageProps = {
  selectPrevPage: () => void
  selectNextPage: () => void
  selectMessagesDirAccessPage: () => void
  canAccessMessagesDir: () => Promise<boolean>
  login: Function
  isReauthing: boolean
  nmp: NMP
  api: PlatformAPI
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

const renderWhyNeeded = (text: string) => <p className="grayed" style={{ textAlign: 'center' }}>{text}</p>

const ContactsAuthPage: React.FC<PageProps> = ({ selectNextPage, nmp }) => {
  const [showMore, setShowMore] = useState(false)
  const [grayscale, setGrayscale] = useState(false)
  const asked = useRef(false)
  const { authorized, pending } = useNMP(nmp, 'contacts')
  const authorizeClick = async () => {
    if (asked.current) return openContactsPrefs()
    await nmp.askForContactsAccess()
    asked.current = true
  }
  const imgClick = () => {
    setGrayscale(true)
    authorizeClick()
  }
  const inner = (
    <>
      {!authorized && (
        <div className={cn('img-transition', { grayscale })} style={IS_BIG_SUR_OR_UP ? { width: 356, height: 362 } : { width: 516, height: 258 }} onClick={imgClick}>
          <img className="animating-other-img" src={contactsImg} alt="Contacts Popup" />
          {!grayscale && <img className="animating-img" src={contactsHighlightedImg} alt="Contacts Popup" />}
        </div>
      )}
      <div className="buttons">
        <button type="button" onClick={authorizeClick} disabled={authorized}>{authorized ? 'Authorized' : 'Authorize'}</button>
        {authorized && <button type="button" onClick={selectNextPage}>Next &rarr;</button>}
      </div>
      {showMore ? (
        <div className="show-more-info" onClick={openContactsPrefs}>
          Open System Preferences and manually check <strong>Texts</strong> in the list &rarr;
        </div>
      ) : <div className="show-more-info grayed" onClick={() => setShowMore(true)}>Having trouble?</div>}
      {renderWhyNeeded('Contacts access allows Texts to show names instead of phone numbers.')}
    </>
  )
  return (
    <div className="page contacts">
      <h3>Contacts</h3>
      {!pending && inner}
    </div>
  )
}

const AXAuthPage: React.FC<PageProps> = ({ selectNextPage, nmp }) => {
  const [showMore, setShowMore] = useState(false)
  const [grayscale, setGrayscale] = useState(false)
  const { authorized, pending } = useNMP(nmp, 'accessibility')
  const authorizeClick = () => {
    nmp.askForAccessibilityAccess()
  }
  const imgClick = () => {
    setGrayscale(true)
    authorizeClick()
  }
  const inner = (
    <>
      {!authorized && (
        <div className={cn('img-transition', { grayscale })} style={{ width: 764, height: 685, maxWidth: '100%' }} onClick={imgClick}>
          <img className="animating-other-img" src={axImg} alt="System Preferences – Accessibility" width={764} />
          {!grayscale && <img className="animating-img" src={axHighlightedImg} alt="System Preferences – Accessibility" width={764} />}
        </div>
      )}
      <div className="buttons">
        <button type="button" onClick={authorizeClick} disabled={authorized}>{authorized ? 'Authorized' : 'Authorize'}</button>
        {authorized && <button type="button" onClick={selectNextPage}>Next &rarr;</button>}
      </div>
      {showMore ? (
        <div className="show-more-info" onClick={openAXPrefs}>
          If Texts doesn&apos;t show up in the list, try adding it manually by clicking the + button and selecting Texts.app from your Applications folder
        </div>
      ) : <div className="show-more-info grayed" onClick={() => setShowMore(true)}>Having trouble?</div>}
      {renderWhyNeeded('Accessibility access allows Texts to power many iMessage features.')}
    </>
  )
  return (
    <div className="page contacts">
      <h3>Accessibility</h3>
      {!pending && inner}
    </div>
  )
}

const RevokeFDA: React.FC<{ nmp: NMP, api: PlatformAPI }> = ({ nmp, api }) => {
  const isAuthorized = useCallback(() => nmp.getAuthStatus('full-disk-access').then(res => res === 'authorized'), [])
  const { execute: refreshAuthorization, value: authorized, pending } = useAsync(isAuthorized)
  if (!authorized || pending) return null
  const onClick = async () => {
    if (await api.getAsset('proxied', 'revokeFDA') !== 'true') return
    setTimeout(() => {
      refreshAuthorization()
    }, 100)
  }
  return (
    <div className="revoke-fda">
      <p>Texts has Full Disk Access. It's no longer required and you're recommended to revoke it.</p>
      <button onClick={onClick}>Revoke Full Disk Access</button>
    </div>
  )
}

const MessagesDirAuthPage: React.FC<PageProps> = ({ api, nmp, selectNextPage, canAccessMessagesDir }) => {
  const [showMore, setShowMore] = useState(false)
  const { execute: refreshAuthorization, value: authorized, pending } = useAsync(canAccessMessagesDir)
  const onAuthorizeClick = async () => {
    await api.getAsset('proxied', 'askForMessagesDirAccess')
    await refreshAuthorization()
  }
  const inner = (
    <>
      {!authorized && (
        <>
          <p>Texts needs to access the local iMessage database. Your data never touches our servers.</p>
        </>
      )}
      <div className="buttons">
        <button type="button" onClick={onAuthorizeClick} disabled={authorized}>{authorized ? 'Authorized' : 'Authorize'}</button>
        {authorized && <button type="button" onClick={selectNextPage}>Next &rarr;</button>}
      </div>
      {showMore ? (
        <div className="show-more-info" onClick={() => nmp.askForFullDiskAccess()}>
          If this doesn&apos;t work, try giving Texts.app Full Disk Access in System Preferences &rarr;
        </div>
      ) : <div className="show-more-info grayed" onClick={() => setShowMore(true)}>Having trouble?</div>}
    </>
  )
  return (
    <div className="page">
      <h3>Messages Directory Access</h3>
      {!pending && inner}
      <RevokeFDA {...{ api, nmp }} />
    </div>
  )
}

let automationAuthorized = false
const AutomationAuthPage: React.FC<PageProps> = ({ api, selectNextPage }) => {
  const [showMore, setShowMore] = useState(false)
  const [loading, setLoading] = useState(false)
  const [calledOnce, setCalledOnce] = useState(false)
  const [grayscale, setGrayscale] = useState(false)
  const authorizeClick = async () => {
    if (calledOnce) return openAutomationPrefs()
    setLoading(true)
    // unclean way to do it but fine for now
    automationAuthorized = (await api.getAsset('proxied', 'askForAutomationAccess')) === 'true'
    setCalledOnce(true)
    setLoading(false)
  }
  let buttonText = automationAuthorized ? 'Authorized' : 'Authorize'
  if (loading) buttonText = '...'
  if (calledOnce && !automationAuthorized) buttonText = 'Open System Preferences'
  const imgClick = () => {
    setGrayscale(true)
    authorizeClick()
  }
  return (
    <div className="page automation">
      <h3>Automation</h3>
      {!automationAuthorized && (
        <div className={cn('img-transition', { grayscale })} style={IS_BIG_SUR_OR_UP ? { width: 356, height: 412 } : { width: 516, height: 292 }} onClick={imgClick}>
          <img className="animating-other-img" src={automationAccessImg} alt="System Preferences – Automation" />
          {!grayscale && <img className="animating-img" src={automationAccessHighlightedImg} alt="System Preferences – Automation" />}
        </div>
      )}
      <div className="buttons">
        <button type="button" onClick={authorizeClick} disabled={automationAuthorized || loading}>{buttonText}</button>
        {automationAuthorized && <button type="button" onClick={selectNextPage}>Next &rarr;</button>}
      </div>
      {showMore ? (
        <div>
          <div className="show-more-info" onClick={openAutomationPrefs}>
            Open System Preferences and manually check <strong>Texts</strong> in the list &rarr;
          </div>
          <div className="show-more-info" onClick={selectNextPage}>Skip &rarr;</div>
        </div>
      ) : <div className="show-more-info grayed" onClick={() => setShowMore(true)}>Having trouble?</div>}
      {renderWhyNeeded('Automation access allows Texts to send iMessages.')}
    </div>
  )
}

const NotificationsPromptPage: React.FC<PageProps> = ({ selectNextPage }) => {
  const [grayscale, setGrayscale] = useState(false)
  const imgClick = () => {
    setGrayscale(true)
    openNotificationsSystemPrefs()
  }
  return (
    <div className="page notifications">
      <h3>Notifications</h3>
      <img className={cn({ grayscale })} src={notificationsMessagesImg} alt="System Preferences – Notifications" width={521} onClick={imgClick} />
      <p>
        Both Texts and Messages will notify you for new messages. You can optionally disable notifications for Messages to not get duplicate notifications.
      </p>
      <div className="buttons">
        <button type="button" onClick={openNotificationsSystemPrefs}>Open System Preferences</button>
        <button type="button" onClick={selectNextPage}>Next &rarr;</button>
      </div>
    </div>
  )
}

const AddAccountPage: React.FC<PageProps> = ({ selectMessagesDirAccessPage, canAccessMessagesDir, login, isReauthing }) => {
  const { value: authorized, pending } = useAsync(canAccessMessagesDir)
  const inner = authorized
    ? (
      <>
        <h3>Almost Done</h3>
        <div className="buttons">
          <button type="button" onClick={() => login()}>{isReauthing ? 'Reauthenticate' : 'Add'} iMessage account</button>
        </div>
      </>
    ) : (
      <>
        <h3>You must authorize access to the messages directory to {isReauthing ? 'reauthenticate' : 'add'} iMessage</h3>
        <div className="buttons">
          <button type="button" onClick={() => selectMessagesDirAccessPage()}>&larr;</button>
        </div>
      </>
    )
  return (
    <div className="page add-page">
      {!pending && inner}
    </div>
  )
}

const KnownIssuesPage: React.FC<PageProps> = ({ selectNextPage }) => {
  const getIssues = () => {
    if (IS_MONTEREY_OR_UP) return ["Reacting/replying to some types of messages isn't supported."]
    if (IS_BIG_SUR_OR_UP) return ["On macOS Big Sur, reacting/replying to non-text messages isn't supported. We recommend updating to the latest macOS."]
    return ["On macOS Catalina and lower: mark as read, typing indicator and reactions aren't supported. We recommend updating to the latest macOS."]
  }
  return (
    <div className="page known-issues">
      <h3>Known Issues</h3>
      <ol>
        <li>Messages.app will be open in the background for powering functionality but Texts can keep it hidden.</li>
        {getIssues().map(issue => <div key={issue}>{issue}</div>)}
      </ol>
      <div className="buttons">
        <button type="button" onClick={selectNextPage}>Next &rarr;</button>
      </div>
    </div>
  )
}

const pages = [
  KnownIssuesPage,
  ContactsAuthPage,
  IS_MOJAVE_OR_UP && MessagesDirAuthPage,
  IS_MOJAVE_OR_UP && AutomationAuthPage,
  IS_MOJAVE_OR_UP && AXAuthPage,
  NotificationsPromptPage,
  AddAccountPage,
].filter(Boolean)

const AppleiMessageAuth: React.FC<{ api: PlatformAPI, login: Function, isReauthing: boolean, nmp: NMP }> = ({ api, login, isReauthing, nmp }) => {
  const [pageIndex, setPageIndex] = useState(0)
  const selectPrevPage = () => setPageIndex(pi => Math.max(0, pi - 1))
  const selectNextPage = () => setPageIndex(pi => Math.min(pages.length - 1, pi + 1))
  const selectMessagesDirAccessPage = () => setPageIndex(1)
  const canAccessMessagesDir = useCallback(async () => (await api.getAsset('proxied', 'canAccessMessagesDir')) === 'true', [])
  useEffect(() => {
    const onKeyDown = (ev: KeyboardEvent) => {
      if (ev.key === 'ArrowLeft') {
        ev.preventDefault()
        selectPrevPage()
      } else if (ev.key === 'ArrowRight') {
        ev.preventDefault()
        selectNextPage()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])
  return (
    <div className="auth imessage-auth">
      <Helmet>
        <link rel="stylesheet" href={cssPath} />
      </Helmet>
      {createElement(pages[pageIndex], { api, selectPrevPage, selectNextPage, selectMessagesDirAccessPage, canAccessMessagesDir, login, isReauthing, nmp })}
      <div className="page-dots">
        {pages.map((_, index) =>
          <div key={index} className={cn('dot', { selected: pageIndex === index })} onClick={() => setPageIndex(index)} />)}
      </div>
    </div>
  )
}

export default AppleiMessageAuth
