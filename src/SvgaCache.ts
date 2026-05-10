import { NitroModules } from 'react-native-nitro-modules';
import type { SvgaManager } from './internal/SvgaManager.nitro';

let cachedManager: SvgaManager | null = null;

// Lazy-init the native module. Calling createHybridObject at module top-level
// throws synchronously when the native side isn't linked (Expo Go, missed pod
// install, version skew) — that throw escapes `import` and white-screens the
// app. Defer it so callers see a normal Error from the first API call.
const getManager = (): SvgaManager => {
  if (cachedManager) return cachedManager;
  cachedManager = NitroModules.createHybridObject<SvgaManager>('SvgaManager');
  return cachedManager;
};

export const svgaManager = new Proxy({} as SvgaManager, {
  get(_target, prop, receiver) {
    return Reflect.get(getManager(), prop, receiver);
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
    const settleReject = (err: unknown) => {
      if (settled) return;
      settled = true;
      reject(err);
    };
    const settleResolve = (value: T) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    let timer: ReturnType<typeof setTimeout> | undefined;
    if (timeoutMs != null && timeoutMs > 0) {
      timer = setTimeout(() => {
        settleReject(
          new Error(`SvgaCache preload timed out after ${timeoutMs}ms`)
        );
      }, timeoutMs);
    }
    const onAbort = () => {
      const reason = (signal as unknown as { reason?: unknown } | undefined)
        ?.reason;
      settleReject(reason ?? new Error('SvgaCache preload aborted'));
    };
    if (signal) {
      if (signal.aborted) {
        onAbort();
      } else {
        signal.addEventListener('abort', onAbort, { once: true });
      }
    }
    underlying.then(
      (value) => {
        if (timer) clearTimeout(timer);
        if (signal) signal.removeEventListener('abort', onAbort);
        settleResolve(value);
      },
      (err) => {
        if (timer) clearTimeout(timer);
        if (signal) signal.removeEventListener('abort', onAbort);
        settleReject(err);
      }
    );
  });
};

export const SvgaCache = {
  preload: (urls: string[], options?: PreloadOptions): Promise<void> =>
    withCancellation(getManager().preload(urls), options),

  preloadDecoded: (urls: string[], options?: PreloadOptions): Promise<void> =>
    withCancellation(getManager().preloadDecoded(urls), options),

  has: (url: string): boolean => getManager().isCached(url),

  path: (url: string): string | null => getManager().getCachePath(url),

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
