import { NitroModules } from 'react-native-nitro-modules';
import type { SvgaManager } from './internal/SvgaManager.nitro';
import type { SvgaPreloadInput } from './types';

let cachedManager: SvgaManager | null = null;
let cachedManagerError: unknown = null;

// Lazy-init the native module. Calling createHybridObject at module top-level
// throws synchronously when the native side isn't linked (Expo Go, missed pod
// install, version skew) — that throw escapes `import` and white-screens the
// app. Defer it so callers see a normal Error from the first API call. Cache
// the failure so a retry doesn't re-run the (expensive, potentially
// side-effecting) hybrid-object creation.
const getManager = (): SvgaManager => {
  if (cachedManager) return cachedManager;
  if (cachedManagerError) throw cachedManagerError;
  try {
    cachedManager = NitroModules.createHybridObject<SvgaManager>('SvgaManager');
    return cachedManager;
  } catch (e) {
    cachedManagerError = e;
    throw e;
  }
};

// Bound-method cache keyed by property name. Without `.bind`, calling
// `svgaManager.foo(...)` invokes `foo` with `this = Proxy`, which breaks
// Nitro hybrid methods that read internal slots from `this`. Caching avoids
// allocating a new bound function on every property access.
const boundMethodCache = new Map<
  PropertyKey,
  (...args: unknown[]) => unknown
>();

// Property names commonly probed by JS infrastructure (await/Promise.resolve,
// console.log, JSON.stringify, structured cloning, devtools). We answer
// undefined for these WITHOUT triggering `getManager()` so a misuse like
// `await svgaManager` doesn't wake the lazy native binding (and so a missing
// native module doesn't keep re-throwing on every accidental probe).
const PROBE_KEYS = new Set<PropertyKey>([
  'then',
  'toJSON',
  'toString',
  'valueOf',
  'constructor',
  Symbol.toPrimitive,
  Symbol.toStringTag,
  Symbol.iterator,
  Symbol.asyncIterator,
]);

export const svgaManager: SvgaManager = new Proxy({} as SvgaManager, {
  get(_target, prop) {
    if (PROBE_KEYS.has(prop)) return undefined;
    const cached = boundMethodCache.get(prop);
    if (cached) return cached;
    const mgr = getManager();
    const v = (mgr as unknown as Record<PropertyKey, unknown>)[prop];
    if (typeof v !== 'function') return v;
    const bound = (v as (...args: unknown[]) => unknown).bind(mgr);
    boundMethodCache.set(prop, bound);
    return bound;
  },
});

const assertNonNegativeFinite = (label: string, value: number): void => {
  if (!Number.isFinite(value) || value < 0) {
    throw new TypeError(`${label} must be a non-negative finite number`);
  }
};

export interface PreloadOptions {
  signal?: AbortSignal;
  timeoutMs?: number;
}

// Normalise a preload input into the parallel (urls, cacheKeys) shape the
// native bridge expects. We validate up-front so a bad item raises a JS
// TypeError before crossing the bridge — the native side trusts the arrays
// are well-formed and aligned.
const normalisePreloadInputs = (
  items: ReadonlyArray<SvgaPreloadInput>
): { urls: string[]; cacheKeys: string[] } => {
  const urls: string[] = [];
  const cacheKeys: string[] = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (typeof item === 'string') {
      if (item.length === 0) {
        throw new TypeError(
          `SvgaCache.preload: items[${i}] is an empty string`
        );
      }
      urls.push(item);
      cacheKeys.push(item);
      continue;
    }
    if (item == null || typeof item !== 'object') {
      throw new TypeError(
        `SvgaCache.preload: items[${i}] must be a string or { url, cacheKey? }`
      );
    }
    const { url, cacheKey } = item;
    if (typeof url !== 'string' || url.length === 0) {
      throw new TypeError(
        `SvgaCache.preload: items[${i}].url must be a non-empty string`
      );
    }
    if (cacheKey !== undefined && typeof cacheKey !== 'string') {
      throw new TypeError(
        `SvgaCache.preload: items[${i}].cacheKey must be a string when provided`
      );
    }
    urls.push(url);
    // Empty cacheKey falls back to url so callers can pass `{ url }` for
    // url-keyed entries without rewriting the call site.
    cacheKeys.push(cacheKey && cacheKey.length > 0 ? cacheKey : url);
  }
  return { urls, cacheKeys };
};

const withCancellation = <T>(
  underlying: Promise<T>,
  options?: PreloadOptions
): Promise<T> => {
  const { signal, timeoutMs } = options ?? {};
  if (!signal && (timeoutMs == null || timeoutMs <= 0)) return underlying;
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const onAbort = (): void => {
      const reason = (signal as unknown as { reason?: unknown } | undefined)
        ?.reason;
      settleReject(reason ?? new Error('SvgaCache preload aborted'));
    };
    // Centralised teardown so timer + abort listener are released as soon
    // as the wrapper settles, regardless of how (or whether) the underlying
    // promise eventually settles. This was a leak when the timer won the
    // race and the underlying never settled — the abort listener stayed on
    // the user's signal forever.
    const cleanup = (): void => {
      if (timer !== undefined) {
        clearTimeout(timer);
        timer = undefined;
      }
      if (signal) signal.removeEventListener('abort', onAbort);
    };
    function settleReject(err: unknown): void {
      if (settled) return;
      settled = true;
      cleanup();
      reject(err);
    }
    function settleResolve(value: T): void {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(value);
    }
    if (timeoutMs != null && timeoutMs > 0) {
      timer = setTimeout(() => {
        settleReject(
          new Error(`SvgaCache preload timed out after ${timeoutMs}ms`)
        );
      }, timeoutMs);
    }
    if (signal) {
      if (signal.aborted) {
        onAbort();
      } else {
        signal.addEventListener('abort', onAbort, { once: true });
      }
    }
    underlying.then(settleResolve, (err) => {
      if (settled) {
        // We already settled (timeout/abort won the race); the underlying's
        // real error would otherwise be silently dropped. Surface it in
        // dev so production diagnostics aren't blank.
        if (__DEV__) {
          console.warn(
            '[SvgaCache] underlying preload rejected after wrapper settled:',
            err
          );
        }
        return;
      }
      settleReject(err);
    });
  });
};

export const SvgaCache = {
  /**
   * Warm the on-disk cache for a list of SVGAs. Each item may be a URL string
   * (cache key defaults to the URL) or `{ url, cacheKey }`. Passing a custom
   * cacheKey lets the same URL produce a fresh cache entry — useful when
   * server-side content is updated without changing the URL.
   */
  preload: (
    items: ReadonlyArray<SvgaPreloadInput>,
    options?: PreloadOptions
  ): Promise<void> => {
    const { urls, cacheKeys } = normalisePreloadInputs(items);
    return withCancellation(getManager().preload(urls, cacheKeys), options);
  },

  /**
   * Like `preload`, but also parses + decodes each entry into the in-memory
   * cache so the next playback is instant. More expensive than `preload`.
   */
  preloadDecoded: (
    items: ReadonlyArray<SvgaPreloadInput>,
    options?: PreloadOptions
  ): Promise<void> => {
    const { urls, cacheKeys } = normalisePreloadInputs(items);
    return withCancellation(
      getManager().preloadDecoded(urls, cacheKeys),
      options
    );
  },

  /**
   * Returns whether an entry is currently cached. Pass `cacheKey` to check
   * by an explicit key; omit to fall back to the URL. Local-file and bundled
   * sources are reported by their existence on disk regardless of cacheKey.
   * Entries past `setMaxAgeMs` report as not cached even though the bytes
   * still exist on disk — they'll be re-downloaded on next request.
   */
  has: (url: string, cacheKey?: string): boolean => {
    if (typeof url !== 'string' || url.length === 0) {
      throw new TypeError('SvgaCache.has: url must be a non-empty string');
    }
    return getManager().isCached(
      cacheKey && cacheKey.length > 0 ? cacheKey : url
    );
  },

  /**
   * Returns the on-disk path of a cached entry, or `undefined` when not
   * cached / expired. As with `has`, `cacheKey` defaults to the URL and TTL
   * is honoured. Native nullable returns are normalised to `undefined` so
   * callers can rely on a single sentinel.
   */
  path: (url: string, cacheKey?: string): string | undefined => {
    if (typeof url !== 'string' || url.length === 0) {
      throw new TypeError('SvgaCache.path: url must be a non-empty string');
    }
    const result = getManager().getCachePath(
      cacheKey && cacheKey.length > 0 ? cacheKey : url
    );
    return result == null ? undefined : result;
  },

  /** Drops the entire on-disk + in-memory cache. */
  clear: (): void => getManager().clearCache(),

  /** Total size of the on-disk SVGA cache, in bytes. */
  size: (): Promise<number> => getManager().getCacheSize(),

  /** Number of entries currently in the on-disk SVGA cache. */
  count: (): Promise<number> => getManager().getCacheCount(),

  /**
   * Set the maximum on-disk cache size, in bytes. When a write would exceed
   * the limit, the LRU policy evicts the least-recently-used entries until
   * the incoming entry fits.
   */
  setLimit: (bytes: number): void => {
    assertNonNegativeFinite('SvgaCache.setLimit(bytes)', bytes);
    getManager().setCacheLimit(bytes);
  },

  /** Set the maximum in-memory (parsed-entity) cache size, in bytes. */
  setMemoryLimit: (bytes: number): void => {
    assertNonNegativeFinite('SvgaCache.setMemoryLimit(bytes)', bytes);
    getManager().setMemoryLimit(bytes);
  },

  /**
   * Set the maximum age (TTL) for cached entries, in milliseconds. Entries
   * older than `ms` are treated as cache misses — the next request triggers
   * a fresh download. Pass `0` to disable TTL (entries live until LRU evicts
   * them; this is the default).
   */
  setMaxAgeMs: (ms: number): void => {
    assertNonNegativeFinite('SvgaCache.setMaxAgeMs(ms)', ms);
    getManager().setMaxAgeMs(ms);
  },

  /**
   * Sweep the on-disk cache and remove every entry whose age exceeds the
   * configured `maxAgeMs`. Returns the number of entries removed. No-op
   * when no `maxAgeMs` is configured.
   */
  evictExpired: (): Promise<number> => getManager().evictExpired(),
};
