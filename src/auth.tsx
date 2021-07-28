import path from 'path'
import { createElement, useState, useEffect, useRef } from 'react'
import { Helmet } from 'react-helmet'
import cn from 'clsx'
import { getAuthStatus, askForContactsAccess, askForFullDiskAccess } from 'node-mac-permissions'
import useForceUpdate from 'use-force-update'

import iMessageAPI from './as2'
import { IS_BIG_SUR_OR_UP, IS_MOJAVE_OR_UP, BINARIES_DIR_PATH } from './constants'

const contactsImgPrefix = IS_BIG_SUR_OR_UP ? 'img/bigsur' : 'img/catalina'
const contactsImg = `${contactsImgPrefix}-contacts-allow.png`
const contactsHighlightedImg = `${contactsImgPrefix}-contacts-allow-highlighted.png`

const staticPrefix = `file://${BINARIES_DIR_PATH}`
const staticImgPrefix = `${staticPrefix}/catalina`
const fdaImg = path.join(staticImgPrefix, 'fda.png')
const automationAccessHighlightedImg = path.join(staticImgPrefix, 'automation-messages-highlighted.png')
const automationAccessImg = path.join(staticImgPrefix, 'automation-messages.png')
const notificationsMessagesImg = path.join(staticImgPrefix, 'notifications-messages.png')
const cssPath = path.join(staticPrefix, 'imessage-auth.css')

const openSecuritySystemPrefs = (prefPath: string) =>
  window.open('x-apple.systempreferences:com.apple.preference.security?' + prefPath)

const openNotificationsSystemPrefs = () =>
  window.open('x-apple.systempreferences:com.apple.preference.notifications')

const openContactsPrefs = () => openSecuritySystemPrefs('Privacy_Contacts')

const openAutomationPrefs = () => openSecuritySystemPrefs('Privacy_Automation')

type PageProps = {
  selectPrevPage: () => void
  selectNextPage: () => void
  selectFDAPage: () => void
  login: Function
  isReauthing: boolean
}

const ContactsAuthPage: React.FC<PageProps> = ({ selectNextPage }) => {
  const [showMore, setShowMore] = useState(false)
  const [grayscale, setGrayscale] = useState(false)
  const asked = useRef(false)
  const authorized = getAuthStatus('contacts') === 'authorized'
  const authorizeClick = () => {
    if (asked.current) return openContactsPrefs()
    askForContactsAccess()
    asked.current = true
  }
  const imgClick = () => {
    setGrayscale(true)
    authorizeClick()
  }
  return (
    <div className="page contacts">
      <h3>Contacts</h3>
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
    </div>
  )
}

const FDAAuthPage: React.FC<PageProps> = ({ selectNextPage }) => {
  const [showMore, setShowMore] = useState(false)
  const [grayscale, setGrayscale] = useState(false)
  const authorized = getAuthStatus('full-disk-access') === 'authorized'
  const imgClick = () => {
    setGrayscale(true)
    askForFullDiskAccess()
  }
  return (
    <div className="page fda">
      <h3>Full Disk Access</h3>
      {!authorized && (
        <>
          <img className={cn({ grayscale })} src={fdaImg} alt="System Preferences – Full Disk Access" width={521} onClick={imgClick} />
          <p>Texts needs full disk access to access the local iMessage database. Your data never touches our servers.</p>
          <ol>
            <li>Click the 🔒 icon in the bottom-left corner</li>
            <li>Check <strong>Texts.app</strong></li>
            <li>Click <strong>Later</strong> (you don't need to restart Texts, the macOS popup is incorrect)</li>
          </ol>
        </>
      )}
      <div className="buttons">
        <button type="button" onClick={askForFullDiskAccess} disabled={authorized}>{authorized ? 'Authorized' : 'Open System Preferences'}</button>
        {authorized && <button type="button" onClick={selectNextPage}>Next &rarr;</button>}
      </div>
      {showMore ? (
        <div className="show-more-info">
          If Texts doesn&apos;t show up in the list, try adding it manually by clicking the + button and selecting Texts.app from your Applications folder
        </div>
      ) : <div className="show-more-info grayed" onClick={() => setShowMore(true)}>Having trouble?</div>}
    </div>
  )
}

let automationAuthorized = false
const AutomationAuthPage: React.FC<PageProps> = ({ selectNextPage }) => {
  const [showMore, setShowMore] = useState(false)
  const [loading, setLoading] = useState(false)
  const [calledOnce, setCalledOnce] = useState(false)
  const [grayscale, setGrayscale] = useState(false)
  const authorizeClick = async () => {
    if (calledOnce) return openAutomationPrefs()
    setLoading(true)
    const api = iMessageAPI()
    automationAuthorized = await api.askForAutomationAccess()
    api.dispose()
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
        <div className={cn('img-transition', { grayscale })} style={{ width: 516, height: 292 }} onClick={imgClick}>
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
      <img className={cn({ grayscale })} src={notificationsMessagesImg} alt="System Preferences – Preferences" width={521} onClick={imgClick} />
      <p>
        Both Texts and Messages will notify you for new messages. You can optionally disable notifications for Messages to not get double notifications.
      </p>
      <div className="buttons">
        <button type="button" onClick={openNotificationsSystemPrefs}>Open System Preferences</button>
        <button type="button" onClick={selectNextPage}>Next &rarr;</button>
      </div>
    </div>
  )
}

const AddAccountPage: React.FC<PageProps> = ({ selectFDAPage, login, isReauthing }) => {
  const fdaAuthorized = getAuthStatus('full-disk-access') === 'authorized'
  return (
    <div className="page add-page">
      {fdaAuthorized
        ? (
          <>
            <h3>Almost Done</h3>
            <div className="buttons">
              <button type="button" onClick={() => login()}>{isReauthing ? 'Reauthenticate' : 'Add'} iMessage account</button>
            </div>
          </>
        ) : (
          <>
            <h3>You must authorize Full Disk Access to {isReauthing ? 'reauthenticate' : 'add'} iMessage</h3>
            <div className="buttons">
              <button type="button" onClick={() => selectFDAPage()}>&larr;</button>
            </div>
          </>
        )}
    </div>
  )
}

const KnownIssuesPage: React.FC<PageProps> = ({ selectNextPage }) => (
  <div className="page known-issues">
    <h3>Known Issues</h3>
    <ol>
      <li>Typing indicator, sending reactions and sending read receipts aren't supported</li>
      {IS_BIG_SUR_OR_UP && <li>Creating groups or messaging people you haven't talked to isn't supported.</li>}
      <li>Chats won't be marked as read on Messages.app — the blue unread icons will show up on your iPhone</li>
      <li>Messages.app needs to be open in the background to send messages but you can hide/minimize it</li>
    </ol>
    <p style={{ textAlign: 'center' }}>We recommend using Texts with other platforms first if you rely on these to work perfectly.</p>
    <div className="buttons">
      <button type="button" onClick={selectNextPage}>Next &rarr;</button>
    </div>
  </div>
)

const pages = [
  KnownIssuesPage,
  ContactsAuthPage,
  IS_MOJAVE_OR_UP && FDAAuthPage,
  IS_MOJAVE_OR_UP && AutomationAuthPage,
  NotificationsPromptPage,
  AddAccountPage,
].filter(Boolean)

const AppleiMessageAuth: React.FC<{ login: Function, isReauthing: boolean }> = ({ login, isReauthing }) => {
  const forceUpdate = useForceUpdate()
  const [pageIndex, setPageIndex] = useState(0)
  useEffect(() => {
    window.addEventListener('focus', forceUpdate)
    return () => window.removeEventListener('focus', forceUpdate)
  }, [forceUpdate])
  const selectPrevPage = () => setPageIndex(pi => Math.max(0, pi - 1))
  const selectNextPage = () => setPageIndex(pi => Math.min(pages.length - 1, pi + 1))
  const selectFDAPage = () => setPageIndex(1)
  useEffect(() => {
    const onKeyDown = (ev: KeyboardEvent) => {
      if (ev.key === 'ArrowLeft') {
        selectPrevPage()
      } else if (ev.key === 'ArrowRight') {
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
      {createElement(pages[pageIndex], { selectPrevPage, selectNextPage, selectFDAPage, login, isReauthing })}
      <div className="page-dots">
        {pages.map((_, index) =>
          <div key={index} className={cn('dot', { selected: pageIndex === index })} onClick={() => setPageIndex(index)} />)}
      </div>
    </div>
  )
}

export default AppleiMessageAuth
