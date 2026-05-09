import { NitroModules } from 'react-native-nitro-modules';
import type { SvgaManager } from './internal/SvgaManager.nitro';

export const svgaManager =
  NitroModules.createHybridObject<SvgaManager>('SvgaManager');

export const SvgaCache = {
  preload: (urls: string[]): Promise<void> => svgaManager.preload(urls),

  has: (url: string): boolean => svgaManager.isCached(url),

  path: (url: string): string | null => svgaManager.getCachePath(url),

  clear: (): void => svgaManager.clearCache(),

  size: (): Promise<number> => svgaManager.getCacheSize(),

  setLimit: (bytes: number): void => svgaManager.setCacheLimit(bytes),
};
