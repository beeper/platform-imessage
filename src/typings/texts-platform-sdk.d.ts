// Some kind of `import`/`export`/etc. statement is needed for TypeScript to
// consider this file to be a module, which avoids overwriting types which we
// merely wish to extend.
import type { Awaitable } from '@textshq/platform-sdk'

declare module '@textshq/platform-sdk' {
  // (2025-07-03) https://github.com/beeper/beeper-desktop-new/blob/8a605b41935215c0380063f71e30048c0efeb588/packages/@beeper/platform-sdk/src/Thread.ts#L49
  export interface ThreadReminder {
    remindAtMs?: number
    dismissOnIncomingMessage?: boolean
    /**
     * The timestamp corresponding to if and when the user was reminded
     */
    userRemindedAt?: number
  }

  export interface Thread {
    reminder?: ThreadReminder
  }

  export interface PlatformAPI {
    // (2025-07-03) https://github.com/beeper/beeper-desktop-new/blob/8a605b41935215c0380063f71e30048c0efeb588/packages/@beeper/platform-sdk/src/PlatformAPI.ts#L267
    setThreadReminder?: (roomID: string, reminder: ThreadReminder) => Awaitable<void>
    clearThreadReminder?: (roomID: string) => Awaitable<void>
    recordThreadReminderElapsed?: (roomID: string) => Awaitable<void>
  }
}
