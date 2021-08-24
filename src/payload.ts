// import os from 'os'
import { trimStart, trimEnd } from 'lodash'
import { Message, MessageAttachment, Size, MessageAttachmentType } from '@textshq/platform-sdk'

import { parseTweetURL } from './util'
import safeBplistParse from './safe-bplist-parse'
import unarchive from './NSUnarchiver'
import { BalloonBundleID } from './constants'

export function getPayloadData({ payload_data: payload, msgID }: { payload_data: Uint8Array, msgID?: string }) {
  if (!payload) return
  const payloadBuffer = Buffer.from(payload)
  const plist = safeBplistParse(payloadBuffer)
  if (!plist) return
  const unarchived = unarchive(plist)
  // if (IS_DEV) {
  //   fs.writeFileSync(os.homedir() + '/Downloads/imsg/' + msgID + '-parsed.json', JSON.stringify(unarchived, null, 2))
  //   fs.writeFileSync(os.homedir() + '/Downloads/imsg/' + msgID + '-plist.json', JSON.stringify(plist, null, 2))
  // }
  return unarchived
}

function parseSize(size: string): Size {
  const [, w, h] = /\{(\d+), (\d+)\}/.exec(size) || []
  const width = +w
  const height = +h
  if (width && height) return { width, height }
}

function getExternalVideos(videos: any): MessageAttachment[] {
  if (!videos) return []
  return (videos['NS.objects'] as any[]).map((video: any) => {
    const srcURL = video.URL['NS.relative']
    if (video.type === 'text/html') return null
    return {
      id: srcURL,
      type: MessageAttachmentType.VIDEO,
      srcURL,
      size: parseSize(video.size),
    }
  }).filter(Boolean)
}

function getURLBalloonProps(payloadData: any, msgAttachments: MessageAttachment[]): Partial<Message> {
  const { richLinkMetadata } = payloadData
  if (!richLinkMetadata) return {}
  const { summary, title, image, icon, alternateImages, video, videos } = richLinkMetadata
  if (!title && !summary) return {}
  const ppa = msgAttachments?.filter(a => a.srcURL && a.fileName.toLowerCase().endsWith('.pluginpayloadattachment')) || []
  const alternates = (alternateImages?.['NS.objects'] as any[])?.map(o => ppa[o.richLinkImageAttachmentSubstituteIndex]) || []
  const attachments = videos ? [
    ...getExternalVideos(videos),
    ...alternates,
  ] : alternates
  const url = richLinkMetadata.originalURL?.['NS.relative'] || richLinkMetadata.URL?.['NS.relative']
  if (url && url.startsWith('https://twitter.com')) {
    const { tweetID, username } = parseTweetURL(url) || {}
    if (username) {
      return {
        attachments: undefined,
        tweets: [{
          id: tweetID,
          user: {
            username,
            imgURL: ppa[icon?.richLinkImageAttachmentSubstituteIndex]?.srcURL,
            name: title.split(' on ').shift(),
          },
          url,
          text: trimStart(trimEnd(summary, '”'), '“'),
          attachments: [ppa[image?.richLinkImageAttachmentSubstituteIndex], ...attachments].filter(Boolean),
        }],
      }
    }
  }
  const iframeURL = video?.youTubeURL?.['NS.relative']?.replace('autoplay=1', '')
  return {
    attachments: iframeURL ? [] : attachments,
    links: [{
      // favicon: ppa[icon?.richLinkImageAttachmentSubstituteIndex]?.srcURL,
      img: iframeURL ? undefined : ppa[image?.richLinkImageAttachmentSubstituteIndex]?.srcURL,
      url,
      title,
      summary,
    }],
    iframeURL,
  }
}

function getApplePayProps(payloadData: any) {
  const { 'NS.objects': objects } = payloadData
  if (!objects || typeof objects[0] !== 'string') return {}
  return {
    textHeading: objects[0],
  }
}

export function getPayloadProps(payloadData: any, msgAttachments: MessageAttachment[], balloon_bundle_id: string): Partial<Message> {
  if (!payloadData) return {}
  if (balloon_bundle_id === BalloonBundleID.URL) return getURLBalloonProps(payloadData, msgAttachments)
  if (balloon_bundle_id === BalloonBundleID.APPLE_PAY) return getApplePayProps(payloadData)
  console.log('[imessage] unknown balloon_bundle_id', balloon_bundle_id)
  try {
    if (balloon_bundle_id === null) return getURLBalloonProps(payloadData, msgAttachments)
  } catch (err) {
    // swallow
  }
  return {}
}
