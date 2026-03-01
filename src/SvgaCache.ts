import { NitroModules } from 'react-native-nitro-modules';
import type { SvgaManager } from './internal/SvgaManager.nitro';

// Singleton — one instance for the entire app
export const svgaManager =
  NitroModules.createHybridObject<SvgaManager>('SvgaManager');

export const SvgaCache = {
  /**
   * Preload svga files to disk before they are needed.
   * Call this at app startup for best performance.
   */
  preload: (urls: string[]): Promise<void> => svgaManager.preload(urls),

  /**
   * Check if a url is already cached on disk.
   */
  has: (url: string): boolean => svgaManager.isCached(url),

  /**
   * Get the local disk path of a cached file.
   * Returns null if not cached.
   */
  path: (url: string): string | null => svgaManager.getCachePath(url),

  /**
   * Clear all cached svga files from disk.
   */
  clear: (): void => svgaManager.clearCache(),

  /**
   * Get total size of disk cache in bytes.
   */
  size: (): Promise<number> => svgaManager.getCacheSize(),

  /**
   * Set max disk cache size in bytes.
   * Oldest files are evicted when limit is reached.
   */
  setLimit: (bytes: number): void => svgaManager.setCacheLimit(bytes),
};
