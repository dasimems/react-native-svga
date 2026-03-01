import type { HybridObject } from 'react-native-nitro-modules';

export interface SvgaManager extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  preload(urls: string[]): Promise<void>;
  isCached(url: string): boolean;
  getCachePath(url: string): string | null;
  clearCache(): void;
  getCacheSize(): Promise<number>;
  setCacheLimit(bytes: number): void;

  // Extra sounds (not baked into svga bundle)
  loadSound(key: string, url: string): Promise<void>;
  playSound(key: string, volume: number): void;
  stopSound(key: string): void;
  stopAllSounds(): void;
  unloadSound(key: string): void;
}
