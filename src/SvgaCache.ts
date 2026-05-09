import { NitroModules } from 'react-native-nitro-modules';
import type { SvgaManager } from './internal/SvgaManager.nitro';

export const svgaManager =
  NitroModules.createHybridObject<SvgaManager>('SvgaManager');

export const SvgaCache = {
  preload: (urls: string[]): Promise<void> => svgaManager.preload(urls),

  preloadDecoded: (urls: string[]): Promise<void> =>
    svgaManager.preloadDecoded(urls),

  has: (url: string): boolean => svgaManager.isCached(url),

  path: (url: string): string | null => svgaManager.getCachePath(url),

  clear: (): void => svgaManager.clearCache(),

  size: (): Promise<number> => svgaManager.getCacheSize(),

  setLimit: (bytes: number): void => svgaManager.setCacheLimit(bytes),

  setMemoryLimit: (bytes: number): void => svgaManager.setMemoryLimit(bytes),
};
