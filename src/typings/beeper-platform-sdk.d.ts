// This is relegated to its own module because you seemingly can't have multiple
// `declare module` statements in one file?

// We aren't augmenting `@textshq/platform-sdk` because an `instanceof` check
// is involved, and it'll likely fail if we use `@textshq/platform-sdk`'s
// class. This is OK because the import is correctly resolved by the bundler
// when it gets compiled into the app.
declare module '@beeper/platform-sdk' {
  export class ReAuthError extends Error {}
}
