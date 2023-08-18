// import os from 'os'
import { trimStart, trimEnd } from 'lodash'
import { Message, Attachment, Size, AttachmentType, MessageLink } from '@textshq/platform-sdk'

import { parseTweetURL } from './util'
import safeBplistParse from './safe-bplist-parse'
import unarchive, { unwrapDictionary } from './NSUnarchiver'
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

function getExternalVideos(videos: any): Attachment[] {
  if (!videos) return []
  return (videos['NS.objects'] as any[]).map((video: any) => {
    const srcURL = video.URL['NS.relative']
    if (video.type === 'text/html') return null
    return {
      id: srcURL,
      type: AttachmentType.VIDEO,
      srcURL,
      size: parseSize(video.size),
    }
  }).filter(Boolean)
}

const unquote = (str: string) =>
  ((str[0] === '“' && str[str.length - 1] === '”') ? str.slice(1, -1) : str)

function getURLBalloonProps(payloadData: any, msgAttachments: Attachment[]): Partial<Message> {
  const { richLinkMetadata } = payloadData
  if (!richLinkMetadata) return {}
  const { summary, title, image, icon, alternateImages, video, videos } = richLinkMetadata
  const ppa = msgAttachments?.filter(a => a.srcURL && a.fileName.toLowerCase().endsWith('.pluginpayloadattachment')) || []
  const alternates = (alternateImages?.['NS.objects'] as any[])?.map(o => ppa[o.richLinkImageAttachmentSubstituteIndex]) || []
  const attachments = videos ? [
    ...getExternalVideos(videos),
    ...alternates,
  ] : alternates
  const parsedURL = richLinkMetadata.URL?.['NS.relative'] // this is the URL that link preview service was redirected to
  const ogURL = richLinkMetadata.originalURL?.['NS.relative'] // this is the URL user entered
  const url = ogURL || parsedURL
  if ((parsedURL || ogURL)?.includes('://twitter.com/')) {
    const { tweetID, username } = parseTweetURL(ogURL) || {}
    if (username) {
      const tweet = {
        id: tweetID,
        user: {
          username,
          imgURL: ppa[icon?.richLinkImageAttachmentSubstituteIndex]?.srcURL,
          name: title?.split(' on ')?.shift(),
        },
        url,
        text: unquote(summary || ''),
        attachments: [ppa[image?.richLinkImageAttachmentSubstituteIndex], ...attachments].filter(Boolean),
      }
      if (tweet.attachments.length > 0 || tweet.text) {
        return {
          attachments: undefined,
          tweets: [tweet],
        }
      }
    }
  }
  const iframeURL = video?.youTubeURL?.['NS.relative']?.replace('autoplay=1', '')
  const imgAtt = iframeURL ? undefined : ppa[image?.richLinkImageAttachmentSubstituteIndex]
  const link: MessageLink = {
    img: imgAtt?.srcURL,
    imgSize: imgAtt?.size,
    url,
    title,
    summary,
  }
  if (!link.img) link.favicon = ppa[icon?.richLinkImageAttachmentSubstituteIndex]?.srcURL
  if (!link.title && !link.summary && !link.favicon && !link.img) return {}
  return {
    attachments: iframeURL ? [] : attachments,
    links: [link],
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

function getYouTubeProps(payloadData: any, msgAttachments: Attachment[]): Partial<Message> {
  const unwrapped = unwrapDictionary(payloadData)
  const img = msgAttachments[0]
  return {
    attachments: [],
    links: [{
      title: unwrapped.ldtext,
      url: unwrapped.URL['NS.relative'],
      // img: img?.srcURL,
      // imgSize: img?.size,
    }],
  }
}

export function getPayloadProps(payloadData: any, msgAttachments: Attachment[], balloon_bundle_id: string): Partial<Message> {
  if (!payloadData) return {}
  switch (balloon_bundle_id) {
    case BalloonBundleID.URL: return getURLBalloonProps(payloadData, msgAttachments)
    case BalloonBundleID.APPLE_PAY: return getApplePayProps(payloadData)
    case BalloonBundleID.YOUTUBE: return getYouTubeProps(payloadData, msgAttachments)
    default:
  }
  console.log('[imessage] unknown balloon_bundle_id', balloon_bundle_id)
  try {
    if (balloon_bundle_id === null) return getURLBalloonProps(payloadData, msgAttachments)
  } catch (err) {
    // swallow
  }
  return {}
}
