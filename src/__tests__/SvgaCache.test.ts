import type { SvgaCache as SvgaCacheType } from '../SvgaCache';

type MockSvgaManager = {
  preload: jest.Mock;
  preloadDecoded: jest.Mock;
  isCached: jest.Mock;
  getCachePath: jest.Mock;
  clearCache: jest.Mock;
  getCacheSize: jest.Mock;
  getCacheCount: jest.Mock;
  setCacheLimit: jest.Mock;
  setMemoryLimit: jest.Mock;
  setMaxAgeMs: jest.Mock;
  evictExpired: jest.Mock;
  loadSound: jest.Mock;
  playSound: jest.Mock;
  stopSound: jest.Mock;
  stopAllSounds: jest.Mock;
  unloadSound: jest.Mock;
};

const buildMockManager = (): MockSvgaManager => ({
  preload: jest.fn().mockResolvedValue(undefined),
  preloadDecoded: jest.fn().mockResolvedValue(undefined),
  isCached: jest.fn().mockReturnValue(false),
  getCachePath: jest.fn().mockReturnValue(null),
  clearCache: jest.fn(),
  getCacheSize: jest.fn().mockResolvedValue(0),
  getCacheCount: jest.fn().mockResolvedValue(0),
  setCacheLimit: jest.fn(),
  setMemoryLimit: jest.fn(),
  setMaxAgeMs: jest.fn(),
  evictExpired: jest.fn().mockResolvedValue(0),
  loadSound: jest.fn().mockResolvedValue(undefined),
  playSound: jest.fn(),
  stopSound: jest.fn(),
  stopAllSounds: jest.fn(),
  unloadSound: jest.fn(),
});

let mockManager: MockSvgaManager;

jest.mock('react-native-nitro-modules', () => ({
  NitroModules: {
    createHybridObject: jest.fn(() => mockManager),
  },
  getHostComponent: jest.fn(),
}));

describe('SvgaCache', () => {
  let SvgaCache: typeof SvgaCacheType;

  beforeEach(() => {
    jest.resetModules();
    mockManager = buildMockManager();
    SvgaCache = require('../SvgaCache').SvgaCache;
  });

  it('delegates string-only preload to the native manager', async () => {
    await SvgaCache.preload(['https://a.test/x.svga', 'https://a.test/y.svga']);
    expect(mockManager.preload).toHaveBeenCalledWith(
      ['https://a.test/x.svga', 'https://a.test/y.svga'],
      ['https://a.test/x.svga', 'https://a.test/y.svga']
    );
  });

  it('passes cacheKey through when items are objects', async () => {
    await SvgaCache.preload([
      { url: 'https://a.test/x.svga', cacheKey: 'gift_v2' },
      { url: 'https://a.test/y.svga' },
      'https://a.test/z.svga',
    ]);
    expect(mockManager.preload).toHaveBeenCalledWith(
      [
        'https://a.test/x.svga',
        'https://a.test/y.svga',
        'https://a.test/z.svga',
      ],
      ['gift_v2', 'https://a.test/y.svga', 'https://a.test/z.svga']
    );
  });

  it('rejects malformed preload items at the JS boundary', () => {
    // Validation runs synchronously before the Promise returns, so a bad
    // shape throws right at the call site (caller never sees a rejected
    // Promise — the bug is in their argument).
    expect(() =>
      // @ts-expect-error – exercising runtime validation
      SvgaCache.preload([{ cacheKey: 'oops' }])
    ).toThrow(/url must be a non-empty string/);
    expect(() => SvgaCache.preload([''])).toThrow(/empty string/);
    expect(() =>
      // @ts-expect-error – exercising runtime validation
      SvgaCache.preload([{ url: 'https://a.test/x.svga', cacheKey: 1 }])
    ).toThrow(/cacheKey must be a string/);
    expect(mockManager.preload).not.toHaveBeenCalled();
  });

  it('forwards cacheKey override to has() and path()', () => {
    SvgaCache.has('https://a.test/x.svga', 'gift_v2');
    expect(mockManager.isCached).toHaveBeenCalledWith('gift_v2');

    SvgaCache.path('https://a.test/x.svga', 'gift_v2');
    expect(mockManager.getCachePath).toHaveBeenCalledWith('gift_v2');
  });

  it('falls back to URL when cacheKey is omitted on lookups', () => {
    mockManager.isCached.mockReturnValueOnce(true);
    expect(SvgaCache.has('https://a.test/x.svga')).toBe(true);
    expect(mockManager.isCached).toHaveBeenCalledWith('https://a.test/x.svga');
  });

  it('returns the cache path or undefined (normalising native null)', () => {
    mockManager.getCachePath.mockReturnValueOnce('/cache/abc');
    expect(SvgaCache.path('https://a.test/x.svga')).toBe('/cache/abc');

    // Android Nitro returns Kotlin null; iOS Nitro maps Swift's nil to
    // undefined. The JS layer normalises both to undefined so callers can
    // rely on a single sentinel.
    mockManager.getCachePath.mockReturnValueOnce(null);
    expect(SvgaCache.path('https://a.test/y.svga')).toBeUndefined();

    mockManager.getCachePath.mockReturnValueOnce(undefined);
    expect(SvgaCache.path('https://a.test/z.svga')).toBeUndefined();
  });

  it('rejects empty / non-string URLs at the JS boundary', () => {
    expect(() => SvgaCache.has('')).toThrow(/non-empty string/);
    expect(() => SvgaCache.path('')).toThrow(/non-empty string/);
    // @ts-expect-error – exercising runtime validation
    expect(() => SvgaCache.has(null)).toThrow(/non-empty string/);
    expect(mockManager.isCached).not.toHaveBeenCalled();
    expect(mockManager.getCachePath).not.toHaveBeenCalled();
  });

  it('clears the cache', () => {
    SvgaCache.clear();
    expect(mockManager.clearCache).toHaveBeenCalledTimes(1);
  });

  it('returns total disk size as a number', async () => {
    mockManager.getCacheSize.mockResolvedValueOnce(2048);
    await expect(SvgaCache.size()).resolves.toBe(2048);
  });

  it('returns total entry count', async () => {
    mockManager.getCacheCount.mockResolvedValueOnce(7);
    await expect(SvgaCache.count()).resolves.toBe(7);
  });

  it('forwards the byte limit', () => {
    SvgaCache.setLimit(10 * 1024 * 1024);
    expect(mockManager.setCacheLimit).toHaveBeenCalledWith(10 * 1024 * 1024);
  });

  it('forwards the memory limit', () => {
    SvgaCache.setMemoryLimit(8 * 1024 * 1024);
    expect(mockManager.setMemoryLimit).toHaveBeenCalledWith(8 * 1024 * 1024);
  });

  it('forwards the max age', () => {
    SvgaCache.setMaxAgeMs(60_000);
    expect(mockManager.setMaxAgeMs).toHaveBeenCalledWith(60_000);
  });

  it('rejects negative or non-finite limits before reaching native', () => {
    expect(() => SvgaCache.setLimit(-1)).toThrow(TypeError);
    expect(() => SvgaCache.setMaxAgeMs(Number.NaN)).toThrow(TypeError);
    expect(mockManager.setCacheLimit).not.toHaveBeenCalled();
    expect(mockManager.setMaxAgeMs).not.toHaveBeenCalled();
  });

  it('returns the count of expired entries from evictExpired', async () => {
    mockManager.evictExpired.mockResolvedValueOnce(3);
    await expect(SvgaCache.evictExpired()).resolves.toBe(3);
  });
});
