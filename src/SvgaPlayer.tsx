import {
  forwardRef,
  memo,
  useCallback,
  useEffect,
  useId,
  useImperativeHandle,
  useMemo,
  useRef,
} from 'react';
import { AppState, type AppStateStatus } from 'react-native';
import { getHostComponent } from 'react-native-nitro-modules';
import type { Svga, SvgaMethods, SvgaProps } from './internal/Svga.nitro';
import {
  loadSoundSafely,
  namespaceSounds,
  playSoundsForTrigger,
  shouldMuteBuiltInAudio,
  soundsEqual,
  type NamespacedSound,
} from './internal/soundOrchestrator';
import { svgaManager } from './SvgaCache';
import type { SvgaPlayerHandle, SvgaPlayerProps } from './types';

// Lazy host-component init. require + getHostComponent at module-scope throws
// synchronously when nitrogen output is missing/stale or the native module
// isn't linked, which escapes `import` and white-screens the app. Defer it so
// the throw becomes a normal React render error caught by an error boundary.
type SvgaHostComponent = ReturnType<
  typeof getHostComponent<SvgaProps, SvgaMethods>
>;
let cachedSvgaView: SvgaHostComponent | null = null;
let cachedSvgaViewError: unknown = null;
const getSvgaView = (): SvgaHostComponent => {
  if (cachedSvgaView) return cachedSvgaView;
  // Cache the failure so an error boundary that retries doesn't keep
  // re-running the (expensive, side-effecting) require.
  if (cachedSvgaViewError) throw cachedSvgaViewError;
  try {
    const SvgaConfig = require('../nitrogen/generated/shared/json/SvgaConfig.json');
    cachedSvgaView = getHostComponent<SvgaProps, SvgaMethods>(
      'Svga',
      () => SvgaConfig
    );
    return cachedSvgaView;
  } catch (e) {
    cachedSvgaViewError = e;
    throw e;
  }
};

const noopHandle = (): void => {
  if (__DEV__) {
    console.warn(
      '[SvgaPlayer] Method called on a disposed (unmounted) player; ignoring. ' +
        'Capture imperative handles only while the component is mounted.'
    );
  }
};

const SvgaPlayerInner = forwardRef<SvgaPlayerHandle, SvgaPlayerProps>(
  (props, ref) => {
    const {
      source,
      loops = 0,
      autoPlay = true,
      speed = 1.0,
      muteBuiltInAudio,
      builtInAudioVolume = 1.0,
      playInBackground = false,
      sounds,
      scaleMode = 'aspectFit',
      style,
      onStart,
      onFinish,
      onLoop,
      onError,
    } = props;

    const SvgaView = useMemo(getSvgaView, []);

    const hybridRef = useRef<Svga | null>(null);
    const disposedRef = useRef(false);
    const instanceId = useId();
    const effectiveMute = useMemo(
      () => shouldMuteBuiltInAudio(muteBuiltInAudio, sounds),
      [muteBuiltInAudio, sounds]
    );

    // Stabilise the sounds reference: the user may pass a fresh array literal
    // every render, but we only re-load when the contents actually change.
    const stableSoundsRef = useRef<typeof sounds>(undefined);
    const stableSounds = useMemo(() => {
      if (soundsEqual(stableSoundsRef.current, sounds)) {
        return stableSoundsRef.current;
      }
      stableSoundsRef.current = sounds;
      return sounds;
    }, [sounds]);

    const namespacedSounds = useMemo<NamespacedSound[]>(
      () => namespaceSounds(instanceId, stableSounds),
      [instanceId, stableSounds]
    );

    const namespacedSoundsRef = useRef(namespacedSounds);
    namespacedSoundsRef.current = namespacedSounds;
    const onStartRef = useRef(onStart);
    onStartRef.current = onStart;
    const onFinishRef = useRef(onFinish);
    onFinishRef.current = onFinish;
    const onLoopRef = useRef(onLoop);
    onLoopRef.current = onLoop;
    const onErrorRef = useRef(onError);
    onErrorRef.current = onError;

    // Exposes `play()`/`pause()`/etc. to the parent via ref. Each method
    // short-circuits to a dev-warn no-op once the player is disposed so
    // late callers don't crash on a freed native handle.
    useImperativeHandle(
      ref,
      (): SvgaPlayerHandle => ({
        play: () => {
          if (disposedRef.current) return noopHandle();
          hybridRef.current?.play();
        },
        pause: () => {
          if (disposedRef.current) return noopHandle();
          hybridRef.current?.pause();
        },
        stop: () => {
          if (disposedRef.current) return noopHandle();
          hybridRef.current?.stop();
        },
        seekToFrame: (f) => {
          if (disposedRef.current) return noopHandle();
          hybridRef.current?.seekToFrame(f);
        },
        seekToProgress: (p) => {
          if (disposedRef.current) return noopHandle();
          hybridRef.current?.seekToProgress(p);
        },
        isPlaying: () => {
          if (disposedRef.current) return false;
          return hybridRef.current?.isPlaying() ?? false;
        },
      }),
      []
    );

    // Tracks which sounds we have loaded natively, keyed by namespaced key.
    // The map's value is the URL we loaded for that key, so we can detect
    // when only the URL changes (same key, different audio) and reload only
    // that one entry instead of all of them.
    const loadedSoundsRef = useRef<Map<string, string>>(new Map());
    const mountedRef = useRef(true);
    // Per-key chain of in-flight load Promises. Serializes loads for the
    // same key so the native side receives loadSound calls in the order
    // JS issued them — without this, a fast disk-cache hit on a newer URL
    // can land in native memory BEFORE a slower download of the older URL,
    // and the older URL ends up as the live entry while JS thinks the new
    // URL is loaded. (Native SoundLibrary swaps by sourcePath, so call
    // order at the native side determines the final state.)
    const loadChainsRef = useRef<Map<string, Promise<void>>>(new Map());

    // Mount/unmount fence. Declared BEFORE the sound-diff effect so its
    // setup runs first on every commit (React runs effect setups in
    // declaration order). That means `mountedRef.current = true` is set
    // before the diff effect's body executes, even on Strict Mode's
    // mount → unmount → re-mount dance where a stale `false` could
    // otherwise be observed by the diff effect's first synchronous body.
    // Cleanup runs in reverse, so on unmount the diff effect's cleanup
    // (currently empty) runs first and then this effect flips to `false`
    // before the native unloads — preserving the invariant that any
    // in-flight load that resumes post-unmount sees `mountedRef.current`
    // as `false`.
    useEffect(() => {
      mountedRef.current = true;
      const loaded = loadedSoundsRef.current;
      const chains = loadChainsRef.current;
      return () => {
        mountedRef.current = false;
        for (const key of loaded.keys()) svgaManager.unloadSound(key);
        loaded.clear();
        // In-flight chain Promises will see !mountedRef and unload their
        // own keys; clearing the map drops references so they can settle
        // and be GC'd without blocking future remounts.
        chains.clear();
      };
    }, []);

    useEffect(() => {
      const loaded = loadedSoundsRef.current;
      const chains = loadChainsRef.current;
      const desiredByKey = new Map(namespacedSounds.map((s) => [s.key, s]));

      // Unload any key that's no longer in the desired set, or whose URL
      // changed. If a load for the same key is still in flight, chain the
      // unload AFTER it completes — without this, the native SoundLibrary
      // can end up with a stale entry when a slow load resolves AFTER our
      // unload (the native side swaps by sourcePath, so call order
      // determines the final state).
      for (const [key, prevUrl] of Array.from(loaded.entries())) {
        const desired = desiredByKey.get(key);
        if (!desired || desired.url !== prevUrl) {
          const prior = chains.get(key);
          if (prior) {
            const after = prior
              .catch(() => undefined)
              .then(() => {
                svgaManager.unloadSound(key);
              });
            chains.set(key, after);
            // Drop our chain entry once the unload settles, but only if
            // we're still the head (a newer load may have queued behind).
            after.finally(() => {
              if (chains.get(key) === after) chains.delete(key);
            });
          } else {
            svgaManager.unloadSound(key);
          }
          loaded.delete(key);
        }
      }

      // Load any key that's new, or whose URL changed (we just unloaded above).
      const toLoad = namespacedSounds.filter(
        (s) => loaded.get(s.key) !== s.url
      );
      for (const s of toLoad) {
        const prior = chains.get(s.key);
        // `let` + definite-assignment so the closure can reference
        // `myPromise` for the staleness check after we've assigned it.
        // The body's reads of `myPromise` happen after `await prior`, by
        // which time the assignment below has completed.
        let myPromise!: Promise<void>;
        const run = async (): Promise<void> => {
          // Wait for any prior load for this key to finish before issuing
          // ours. Errors in the prior load are not our concern.
          if (prior) {
            try {
              await prior;
            } catch {
              // swallow — we're starting fresh
            }
          }
          try {
            await loadSoundSafely(
              svgaManager,
              s,
              () => !mountedRef.current,
              (m) => {
                if (!mountedRef.current) return;
                onErrorRef.current?.(m);
              }
            );
            if (!mountedRef.current) {
              // Unmounted during our load. The unmount-only cleanup already
              // drained `loaded`, so we own this entry — unload it.
              svgaManager.unloadSound(s.key);
              return;
            }
            // If a newer load for this key has been queued (chains[key] is
            // a different Promise), it will run after us and write the
            // canonical entry. Don't touch `loaded` — we're stale.
            if (chains.get(s.key) !== myPromise) return;
            loaded.set(s.key, s.url);
          } finally {
            // Only clear our own chain entry. Without the identity check a
            // late-arriving deletion would clear a newer queued load and
            // strand it without a serializer — leaking the chain map and
            // reordering loads.
            if (chains.get(s.key) === myPromise) chains.delete(s.key);
          }
        };
        myPromise = run();
        chains.set(s.key, myPromise);
      }

      return undefined;
    }, [namespacedSounds]);

    const wasPlayingForBgRef = useRef(false);

    useEffect(() => {
      if (playInBackground) {
        wasPlayingForBgRef.current = false;
        return undefined;
      }
      const onChange = (state: AppStateStatus) => {
        // Late events can fire after the player has been disposed by the
        // unmount effect below — skip them so we don't poke a freed
        // native handle.
        if (disposedRef.current) return;
        if (state === 'active') {
          if (!wasPlayingForBgRef.current) return;
          wasPlayingForBgRef.current = false;
          hybridRef.current?.play();
          return;
        }
        const isPlaying = hybridRef.current?.isPlaying() ?? false;
        if (isPlaying) {
          wasPlayingForBgRef.current = true;
          hybridRef.current?.pause();
        }
      };
      const subscription = AppState.addEventListener('change', onChange);
      return () => {
        subscription.remove();
        wasPlayingForBgRef.current = false;
      };
    }, [playInBackground]);

    useEffect(() => {
      return () => {
        const hybrid = hybridRef.current;
        // Mark disposed FIRST so any AppState event, imperative handle
        // call, or in-flight callback that fires before native dispose
        // returns sees the gate and short-circuits.
        disposedRef.current = true;
        hybridRef.current = null;
        if (!hybrid) return;
        try {
          hybrid.stop();
        } catch {
          // ignore — view may already be detached
        }
        // Eager-dispose the native object. Android's auto-generated
        // ViewManager doesn't call dispose() on view drop, so without
        // this the audio engine, coroutine scope, and MediaPlayers
        // leak until JVM GC.
        try {
          hybrid.dispose?.();
        } catch {
          // ignore — best-effort cleanup
        }
      };
    }, []);

    // Returns true iff the named sound was loaded for the URL the player
    // currently expects. This is enough to gate trigger-sound playback
    // across rapid `source`/`sounds` changes: the prior source's sounds are
    // unloaded before the new ones are loaded, so a late frame callback
    // from the prior source sees `loaded.get(key) === undefined` (or a
    // different URL) and skips. We do NOT need a separate source-token
    // because the same diff effect drives both unload-old and load-new.
    const isSoundLoaded = useCallback((s: NamespacedSound) => {
      return loadedSoundsRef.current.get(s.key) === s.url;
    }, []);

    const handleStart = useCallback(() => {
      if (disposedRef.current) return;
      playSoundsForTrigger(
        svgaManager,
        namespacedSoundsRef.current,
        'start',
        isSoundLoaded
      );
      onStartRef.current?.();
    }, [isSoundLoaded]);

    const handleFinish = useCallback(() => {
      if (disposedRef.current) return;
      playSoundsForTrigger(
        svgaManager,
        namespacedSoundsRef.current,
        'finish',
        isSoundLoaded
      );
      onFinishRef.current?.();
    }, [isSoundLoaded]);

    const handleLoop = useCallback((count: number) => {
      if (disposedRef.current) return;
      onLoopRef.current?.(count);
    }, []);

    const handleError = useCallback((message: string) => {
      if (disposedRef.current) return;
      onErrorRef.current?.(message);
    }, []);

    const captureRef = useCallback((value: Svga) => {
      if (disposedRef.current) return;
      hybridRef.current = value;
    }, []);

    // Memoize the host-view ref-wrapper. A fresh literal every render makes
    // the host component non-shallow-equal and may cause Nitro to re-bind
    // its JSI handle on every parent re-render.
    const hybridRefProp = useMemo(() => ({ f: captureRef }), [captureRef]);

    const eventHandlers = useMemo(
      () => ({
        onStart: { f: handleStart },
        onFinish: { f: handleFinish },
        onLoop: { f: handleLoop },
        onError: { f: handleError },
      }),
      [handleStart, handleFinish, handleLoop, handleError]
    );

    return (
      <SvgaView
        hybridRef={hybridRefProp}
        source={source}
        loops={loops}
        autoPlay={autoPlay}
        speed={speed}
        muteBuiltInAudio={effectiveMute}
        builtInAudioVolume={builtInAudioVolume}
        playInBackground={playInBackground}
        scaleMode={scaleMode}
        style={style}
        {...eventHandlers}
      />
    );
  }
);

SvgaPlayerInner.displayName = 'SvgaPlayer';

export const SvgaPlayer = memo(SvgaPlayerInner);
export type { SvgaPlayerProps, SvgaPlayerHandle, SvgaSound } from './types';
