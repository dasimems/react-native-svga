import { NitroModules } from 'react-native-nitro-modules';
import type { SvgaManager } from './internal/SvgaManager.nitro';

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
  preload: (urls: string[], options?: PreloadOptions): Promise<void> =>
    withCancellation(getManager().preload(urls), options),

  preloadDecoded: (urls: string[], options?: PreloadOptions): Promise<void> =>
    withCancellation(getManager().preloadDecoded(urls), options),

  has: (url: string): boolean => getManager().isCached(url),

  path: (url: string): string | undefined => getManager().getCachePath(url),

  clear: (): void => getManager().clearCache(),

  size: (): Promise<number> => getManager().getCacheSize(),

  setLimit: (bytes: number): void => {
    assertNonNegativeFinite('SvgaCache.setLimit(bytes)', bytes);
    getManager().setCacheLimit(bytes);
  },

  setMemoryLimit: (bytes: number): void => {
    assertNonNegativeFinite('SvgaCache.setMemoryLimit(bytes)', bytes);
    getManager().setMemoryLimit(bytes);
  },
};
