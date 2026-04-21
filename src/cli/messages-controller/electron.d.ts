// fake electron shim - headless runs inside of desktop's Electron and haven't
// introduced that dependency link just yet

declare module 'electron' {
  export declare const app: {
    whenReady: () => Promise<void>
  }
}
