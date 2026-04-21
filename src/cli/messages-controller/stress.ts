import type { MessagesController } from '../../SwiftServer/lib/index'

export async function runStress(
  controller: MessagesController,
  first: string,
  second: string,
): Promise<void> {
  await Promise.all([
    controller.toggleThreadRead(first, true),
    controller.toggleThreadRead(first, true),
    controller.toggleThreadRead(second, true),
    controller.toggleThreadRead(first, true),
    controller.toggleThreadRead(second, true),
    controller.toggleThreadRead(first, true),
    controller.toggleThreadRead(second, true),
    controller.toggleThreadRead(first, true),
    controller.toggleThreadRead(first, true),
    controller.toggleThreadRead(first, true),
    controller.toggleThreadRead(first, true),
  ])
}
