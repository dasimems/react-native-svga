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

const SvgaConfig = require('../nitrogen/generated/shared/json/SvgaConfig.json');

const SvgaView = getHostComponent<SvgaProps, SvgaMethods>(
  'Svga',
  () => SvgaConfig
);

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

    const hybridRef = useRef<Svga | null>(null);
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

    useImperativeHandle(
      ref,
      (): SvgaPlayerHandle => ({
        play: () => hybridRef.current?.play(),
        pause: () => hybridRef.current?.pause(),
        stop: () => hybridRef.current?.stop(),
        seekToFrame: (f) => hybridRef.current?.seekToFrame(f),
        seekToProgress: (p) => hybridRef.current?.seekToProgress(p),
        isPlaying: () => hybridRef.current?.isPlaying() ?? false,
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

    useEffect(() => {
      const loaded = loadedSoundsRef.current;
      const chains = loadChainsRef.current;
      const desiredByKey = new Map(namespacedSounds.map((s) => [s.key, s]));

      // Unload any key that's no longer in the desired set, or whose URL changed.
      for (const [key, prevUrl] of Array.from(loaded.entries())) {
        const desired = desiredByKey.get(key);
        if (!desired || desired.url !== prevUrl) {
          svgaManager.unloadSound(key);
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
          await loadSoundSafely(
            svgaManager,
            s,
            () => !mountedRef.current,
            (m) => onErrorRef.current?.(m)
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
          chains.delete(s.key);
          loaded.set(s.key, s.url);
        };
        myPromise = run();
        chains.set(s.key, myPromise);
      }

      return undefined;
    }, [namespacedSounds]);

    // Unload everything we loaded when the component unmounts. This effect
    // intentionally has empty deps so its cleanup fires only on unmount;
    // the diffed effect above doesn't clean up on its own teardown.
    // mountedRef is reset on each setup so React Strict Mode's
    // mount → unmount → re-mount dance leaves us in a healthy state.
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

    const wasPlayingForBgRef = useRef(false);

    useEffect(() => {
      if (playInBackground) {
        wasPlayingForBgRef.current = false;
        return undefined;
      }
      const onChange = (state: AppStateStatus) => {
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
        hybrid.dispose?.();
      };
    }, []);

    const handleStart = useCallback(() => {
      playSoundsForTrigger(svgaManager, namespacedSoundsRef.current, 'start');
      onStartRef.current?.();
    }, []);

    const handleFinish = useCallback(() => {
      playSoundsForTrigger(svgaManager, namespacedSoundsRef.current, 'finish');
      onFinishRef.current?.();
    }, []);

    const handleLoop = useCallback((count: number) => {
      onLoopRef.current?.(count);
    }, []);

    const handleError = useCallback((message: string) => {
      onErrorRef.current?.(message);
    }, []);

    const captureRef = useCallback((value: Svga) => {
      hybridRef.current = value;
    }, []);

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
        hybridRef={{ f: captureRef }}
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
