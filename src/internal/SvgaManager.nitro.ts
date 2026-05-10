import type { HybridObject } from 'react-native-nitro-modules';

export interface SvgaManager extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  // `cacheKeys[i]` is the identity used for cache lookup/storage; download
  // bytes still come from `urls[i]`. Pass an empty string to fall back to the
  // url. Arrays must have the same length — the JS layer enforces this.
  preload(urls: string[], cacheKeys: string[]): Promise<void>;
  preloadDecoded(urls: string[], cacheKeys: string[]): Promise<void>;
  isCached(cacheKey: string): boolean;
  getCachePath(cacheKey: string): string | undefined;
  clearCache(): void;
  getCacheSize(): Promise<number>;
  getCacheCount(): Promise<number>;
  setCacheLimit(bytes: number): void;
  setMemoryLimit(bytes: number): void;
  // 0 disables TTL eviction (entries live until LRU evicts them).
  setMaxAgeMs(ms: number): void;
  evictExpired(): Promise<number>;

  // Extra sounds (not baked into svga bundle)
  loadSound(key: string, url: string): Promise<void>;
  playSound(key: string, volume: number): void;
  stopSound(key: string): void;
  stopAllSounds(): void;
  unloadSound(key: string): void;
}
