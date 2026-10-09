/**
 * Minimal logger. By design it is only used for lifecycle events and
 * aggregate counters: never log keys, IP addresses, IDs, tokens or message
 * contents.
 */
export const log = {
  info(message: string): void {
    console.log(`[sotto-relay] ${message}`);
  },
  error(message: string): void {
    console.error(`[sotto-relay] ${message}`);
  },
};
