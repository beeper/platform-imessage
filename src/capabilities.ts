// `CapabilitySupportLevel.FullySupported`
// TODO: replace when we can use @beeper/platform-sdk
const fullySupportedCapabilitySupportLevel = 2

export const roomFeatures = {
  // PlatformInfo `editMessageTimeLimit` stopped being recognized in
  // 2232e765a1 (beeper-desktop-new), send equivalent room features.
  edit_max_age: 60 * 15,
  edit_max_count: 5,
  edit: fullySupportedCapabilitySupportLevel,

  delete: fullySupportedCapabilitySupportLevel,
  delete_max_age: 60 * 2,

  reaction: fullySupportedCapabilitySupportLevel,
  reaction_count: 1,
  // NOTE(skip): Beeper Desktop doesn't check this (instead it checks the
  // platform-sdk equivalent `canReactWithAllEmojis`), so there's little
  // point in sending the correct value for this right now.
  //
  // allowed_reactions
  custom_emoji_reactions: false,
} as const
