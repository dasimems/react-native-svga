type MockSvgaManager = {
  preload: jest.Mock;
  isCached: jest.Mock;
  getCachePath: jest.Mock;
  clearCache: jest.Mock;
  getCacheSize: jest.Mock;
  setCacheLimit: jest.Mock;
  loadSound: jest.Mock;
  playSound: jest.Mock;
  stopSound: jest.Mock;
  stopAllSounds: jest.Mock;
  unloadSound: jest.Mock;
};

const buildMockManager = (): MockSvgaManager => ({
  preload: jest.fn().mockResolvedValue(undefined),
  isCached: jest.fn().mockReturnValue(false),
  getCachePath: jest.fn().mockReturnValue(null),
  clearCache: jest.fn(),
  getCacheSize: jest.fn().mockResolvedValue(0),
  setCacheLimit: jest.fn(),
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
  let SvgaCache: typeof import('../SvgaCache').SvgaCache;

  beforeEach(() => {
    jest.resetModules();
    mockManager = buildMockManager();
    SvgaCache = require('../SvgaCache').SvgaCache;
  });

  it('delegates preload to the native manager', async () => {
    mockManager.preload.mockResolvedValueOnce(undefined);
    await SvgaCache.preload(['https://a.test/x.svga', 'https://a.test/y.svga']);
    expect(mockManager.preload).toHaveBeenCalledWith([
      'https://a.test/x.svga',
      'https://a.test/y.svga',
    ]);
  });

  it('reports cache hits via has()', () => {
    mockManager.isCached.mockReturnValueOnce(true);
    expect(SvgaCache.has('https://a.test/x.svga')).toBe(true);
    expect(mockManager.isCached).toHaveBeenCalledWith('https://a.test/x.svga');
  });

  it('returns the cache path or null', () => {
    mockManager.getCachePath.mockReturnValueOnce('/cache/abc');
    expect(SvgaCache.path('https://a.test/x.svga')).toBe('/cache/abc');

    mockManager.getCachePath.mockReturnValueOnce(null);
    expect(SvgaCache.path('https://a.test/y.svga')).toBeNull();
  });

  it('clears the cache', () => {
    SvgaCache.clear();
    expect(mockManager.clearCache).toHaveBeenCalledTimes(1);
  });

  it('returns total disk size as a number', async () => {
    mockManager.getCacheSize.mockResolvedValueOnce(2048);
    await expect(SvgaCache.size()).resolves.toBe(2048);
  });

  it('forwards the byte limit', () => {
    SvgaCache.setLimit(10 * 1024 * 1024);
    expect(mockManager.setCacheLimit).toHaveBeenCalledWith(10 * 1024 * 1024);
  });
});
