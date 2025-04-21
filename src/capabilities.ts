// 100 MB as of macOS Monterey 12.2; big media files are automatically
// compressed
const maxFileSizeBytes = 100 * 1_024 * 1_024

// FIXME: copied from beeper-desktop-new's platform-sdk
/**
 * The support level for a feature. These are integers rather than booleans
 * to accurately represent what the bridge is doing and hopefully make the
 * state event more generally useful. Our clients should check for > 0 to
 * determine if the feature should be allowed.
 */
export enum CapabilitySupportLevel {
  /** The feature is unsupported and messages using it will be rejected. */
  Rejected = -2,
  /** The feature is unsupported and has no fallback. The message will go through, but data may be lost. */
  Dropped = -1,
  /** The feature is unsupported, but may have a fallback. The nature of the fallback depends on the context. */
  Unsupported = 0,
  /** The feature is partially supported (e.g. it may be converted to a different format). */
  PartialSupport = 1,
  /** The feature is fully supported and can be safely used. */
  FullySupported = 2,
}

// FIXME: copied from beeper-desktop-new's platform-sdk
export enum CapabilityMsgType {
  // Real message types used in the `msgtype` field
  Image = 'm.image',
  File = 'm.file',
  Audio = 'm.audio',
  Video = 'm.video',

  // Pseudo types only used in capabilities
  /** An `m.audio` message that has `"org.matrix.msc3245.voice": {}` */
  Voice = 'org.matrix.msc3245.voice',
  /** An `m.video` message that has `"info": {"fi.mau.gif": true}`, or an `m.image` message of type `image/gif` */
  GIF = 'fi.mau.gif',
  /** An `m.sticker` event, no `msgtype` field */
  Sticker = 'm.sticker',
}

export const roomFeatures = {
  // PlatformInfo `editMessageTimeLimit` stopped being recognized in
  // 2232e765a1 (beeper-desktop-new), send equivalent room features.
  edit_max_age: 60 * 15,
  edit_max_count: 5,
  edit: CapabilitySupportLevel.FullySupported,

  delete: CapabilitySupportLevel.FullySupported,
  delete_max_age: 60 * 2,

  reaction: CapabilitySupportLevel.FullySupported,
  reaction_count: 1,
  // NOTE(skip): Beeper Desktop doesn't check this (instead it checks the
  // platform-sdk equivalent `canReactWithAllEmojis`), so there's little
  // point in sending the correct value for this right now.
  //
  // allowed_reactions
  custom_emoji_reactions: false,

  file: {
    [CapabilityMsgType.File]: {
      mime_types: {
        '*/*': CapabilitySupportLevel.FullySupported,
      },
      caption: CapabilitySupportLevel.FullySupported,
      max_size: maxFileSizeBytes,
    },
    [CapabilityMsgType.Image]: {
      mime_types: {
        'image/jpeg': CapabilitySupportLevel.FullySupported,
        'image/png': CapabilitySupportLevel.FullySupported,
        'image/gif': CapabilitySupportLevel.FullySupported,
        'image/webp': CapabilitySupportLevel.FullySupported,
      },
      caption: CapabilitySupportLevel.FullySupported,
      max_size: maxFileSizeBytes,
    },
    [CapabilityMsgType.Audio]: {
      mime_types: {
        'audio/mpeg': CapabilitySupportLevel.FullySupported,
        'audio/mp4': CapabilitySupportLevel.FullySupported,
        'audio/ogg': CapabilitySupportLevel.FullySupported,
        'audio/wav': CapabilitySupportLevel.FullySupported,
        'audio/webm': CapabilitySupportLevel.FullySupported,
        'audio/aac': CapabilitySupportLevel.FullySupported,
      },
      caption: CapabilitySupportLevel.FullySupported,
      max_size: maxFileSizeBytes,
    },
    [CapabilityMsgType.Video]: {
      mime_types: {
        'video/mp4': CapabilitySupportLevel.FullySupported,
        'video/webm': CapabilitySupportLevel.FullySupported,
        'video/ogg': CapabilitySupportLevel.FullySupported,
      },
      caption: CapabilitySupportLevel.FullySupported,
      max_size: maxFileSizeBytes,
    },
    [CapabilityMsgType.GIF]: {
      mime_types: {
        'image/gif': CapabilitySupportLevel.FullySupported,
      },
      caption: CapabilitySupportLevel.FullySupported,
      max_size: maxFileSizeBytes,
    },
  },
} as const
