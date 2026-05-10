# react-native-svga

A fast, secure SVGA player for React Native, built on [Nitro Modules](https://nitro.margelo.com/). Streams `.svga` files from the network or disk, caches them transparently, and plays both built-in audio tracks and external MP3s without disrupting the host app's audio session.

> SVGA is a vector + sprite animation format used widely in livestream gift animations. It's lighter than Lottie for raster-driven animations and supports frame-synced audio.
>
> **Expo users:** this library ships native code, so it cannot run inside **Expo Go**. You'll need a [development build](https://docs.expo.dev/develop/development-builds/introduction/) (via `expo prebuild` or EAS Build). Full instructions below.

## Features

- **Plays every common SVGA packaging** - v2 zip (`PK…`), zlib stream (`78 xx`), gzip stream (`1F 8B`), or raw protobuf
- **Stream from anywhere** - remote URLs, local files (`file://`), or bundled assets (`asset://`)
- **Two-tier cache** - SHA-256-keyed disk cache + in-memory LRU of decoded entities, so the second play of a recent file is instant
- **Built-in + external audio** - plays `.svga`-bundled audio tracks; can layer external sounds that play on `start`/`finish`. Externals auto-mute the built-in audio when present (override available)
- **Broad audio format support** - Android plays MP3 / AAC / M4A / OGG / WAV / FLAC / AMR via `MediaPlayer`; iOS plays MP3 / AAC / M4A / WAV / AIFF / ALAC via `AVAudioPlayer`
- **Doesn't fight other audio modules** - uses isolated `MediaPlayer` instances (Android) and per-track `AVAudioPlayer` instances (iOS) without touching `AVAudioSession`
- **Programmatic controls** - `play`, `pause`, `stop`, `seekToFrame`, `seekToProgress` via a ref
- **Lifecycle events** - `onStart`, `onLoop`, `onFinish`, `onError`
- **Transparent background** - no card-coloured rectangle; restyle freely
- **Hardened parser** - bounded varints, size caps, zip-slip rejection, scheme allow-list
- **Drift-corrected frame loop** with no per-frame allocation
- **TypeScript first**

## Requirements

- React Native ≥ 0.74
- iOS 13+ / Android `minSdkVersion` 24
- [`react-native-nitro-modules`](https://github.com/mrousavy/nitro) ≥ 0.29

## Installation

This package autolinks. There's no manifest to edit, no linking command to run; React Native CLI and Expo prebuild both pick it up automatically. The flow differs slightly depending on your project type.

### Bare React Native CLI

```sh
npm install react-native-svga react-native-nitro-modules
# or
yarn add react-native-svga react-native-nitro-modules
```

Then install the iOS pods:

```sh
cd ios && pod install && cd ..
```

Rebuild the native projects (the JS dev server will not pick up new native code on its own):

```sh
npx react-native run-ios
# or
npx react-native run-android
```

### Expo (with prebuild / development build)

> **`react-native-svga` does not work in Expo Go.** Expo Go is a fixed, prebuilt binary - it cannot load custom native modules. You must use a development build (`expo prebuild` + a custom client). This is a one-time setup; afterwards your dev workflow is the same as with Expo Go.

#### 1. Install the package and its peer dependency

```sh
npx expo install react-native-svga react-native-nitro-modules
```

(Using `expo install` instead of `npm install` makes Expo align the versions with your SDK.)

#### 2. Generate native projects with `expo prebuild`

```sh
npx expo prebuild
```

This creates the `ios/` and `android/` folders in your app, runs autolinking, and wires up `react-native-svga` (and `react-native-nitro-modules`) automatically. You only need to re-run prebuild when you add or remove a native module.

#### 3. Build and run a development client

The first time:

```sh
# locally
npx expo run:ios
# or
npx expo run:android
```

Or via [EAS Build](https://docs.expo.dev/build/introduction/):

```sh
eas build --profile development --platform ios
eas build --profile development --platform android
```

After the development client is installed on your device/simulator, your daily workflow goes back to:

```sh
npx expo start --dev-client
```

#### Common Expo gotchas

- **Stuck on Expo Go?** If `expo start` opens the project in Expo Go, hit `s` in the terminal to switch to "development build" mode, or run `npx expo start --dev-client`.
- **Updated Expo SDK?** Re-run `npx expo prebuild --clean` to regenerate the native projects from scratch.
- **Custom config plugins?** Move any patches into `app.config.js` config plugins; raw edits to `ios/`/`android/` are wiped by the next prebuild.

### Verify the install

After installing, confirm the native module is registered. From your app's entry file:

```ts
import { SvgaCache } from 'react-native-svga';

console.log(await SvgaCache.size()); // should print a number, not throw
```

If it throws "module not found", the autolinking step didn't run - rebuild the app (`pod install` + native rebuild for bare; `expo prebuild` + run for Expo).

## Quick start

```tsx
import { SvgaPlayer } from 'react-native-svga';
import { View, StyleSheet } from 'react-native';

export default function App() {
  return (
    <View style={styles.container}>
      <SvgaPlayer
        source="https://assets.svga.io/svga/sample.svga"
        style={styles.player}
        loops={0}
        onFinish={() => console.log('finished')}
        onError={(message) => console.warn('svga error:', message)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  player: { width: 300, height: 300 },
});
```

`SvgaPlayer` autoplays by default and renders with a transparent background, so you can drop it onto any screen.

## Usage walkthrough

### Source formats

The `source` prop accepts three URI styles:

| Form | Example | Notes |
| --- | --- | --- |
| Remote URL | `https://cdn.example/anim.svga` | Downloaded once, cached on disk, replayed from memory |
| Local file | `file:///var/.../anim.svga` or `/var/.../anim.svga` | Read directly, bypassing the cache |
| Bundled asset | `asset://animations/cheer.svga` | Read from the platform asset bundle |

Schemes other than `http`, `https`, `file`, and `asset` are rejected for safety, as are paths containing `..`.

```tsx
// Remote
<SvgaPlayer source="https://cdn.example/gift.svga" />

// Local file (e.g. one you saved with expo-file-system)
<SvgaPlayer source="file:///path/to/local/anim.svga" />

// Bundled asset
// Android: place file under android/app/src/main/assets/animations/cheer.svga
// iOS:     add to the Xcode bundle as animations/cheer.svga
<SvgaPlayer source="asset://animations/cheer.svga" />
```

### Programmatic control

`SvgaPlayer` forwards a ref that exposes imperative methods:

```tsx
import { useRef } from 'react';
import { Button, View } from 'react-native';
import { SvgaPlayer, type SvgaPlayerHandle } from 'react-native-svga';

export function Controlled() {
  const ref = useRef<SvgaPlayerHandle>(null);

  return (
    <View>
      <SvgaPlayer
        ref={ref}
        source="https://cdn.example/gift.svga"
        autoPlay={false}
        loops={3}
      />
      <Button title="Play"  onPress={() => ref.current?.play()} />
      <Button title="Pause" onPress={() => ref.current?.pause()} />
      <Button title="Stop"  onPress={() => ref.current?.stop()} />
      <Button title="Skip to halfway"
              onPress={() => ref.current?.seekToProgress(0.5)} />
    </View>
  );
}
```

Available methods on the handle:

| Method | Effect |
| --- | --- |
| `play()` | Starts (or resumes) playback. Fires `onStart` on a fresh start. |
| `pause()` | Suspends playback at the current frame. |
| `stop()` | Resets to frame 0 and clears any active audio streams. |
| `seekToFrame(frame)` | Jumps to a specific frame index. |
| `seekToProgress(progress)` | Jumps to `0.0`-`1.0` of the timeline. |

### External MP3s synced to the animation

Layer your own sounds on top of the animation and decide when each one fires:

```tsx
import { SvgaPlayer, type SvgaSound } from 'react-native-svga';

const sounds: SvgaSound[] = [
  { key: 'open',  url: 'https://cdn.example/open.mp3',   playOn: 'start',  volume: 0.8 },
  { key: 'cheer', url: 'https://cdn.example/cheer.mp3',  playOn: 'finish' },
];

<SvgaPlayer
  source="https://cdn.example/gift.svga"
  sounds={sounds}
  loops={1}
/>;
```

Behaviour:

- Sounds are downloaded the first time they're seen and cached on disk by `key`.
- When the array is non-empty, the built-in audio bundled inside the `.svga` is muted automatically. Pass `muteBuiltInAudio={false}` to layer both.
- Sounds unload automatically when the component unmounts (or when `sounds` changes).
- The library uses an isolated audio pool, so it won't interrupt music or other audio modules in your app.

### Lifecycle events

```tsx
<SvgaPlayer
  source={url}
  loops={2}
  onStart={() => analytics.track('svga_play_started')}
  onLoop={(count) => console.log(`finished loop ${count}`)}
  onFinish={() => analytics.track('svga_play_finished')}
  onError={(msg) => Sentry.captureMessage(`svga: ${msg}`)}
/>
```

`onStart` fires on the transition from idle to playing. `onLoop` fires every time a loop completes. `onFinish` fires once when the configured `loops` count is reached. `onError` fires for any load, parse, or network failure.

### Preloading and cache management

For animations you know you'll play (e.g. gift animations in a livestream), warm the cache at app startup so the first play is instant:

```ts
import { SvgaCache } from 'react-native-svga';

useEffect(() => {
  SvgaCache.preload([
    'https://cdn.example/gift-1.svga',
    'https://cdn.example/gift-2.svga',
    'https://cdn.example/gift-3.svga',
  ]).catch((e) => console.warn('preload failed', e));
}, []);
```

The full facade:

```ts
// Preload accepts plain URLs or { url, cacheKey } items. Use `cacheKey` to
// decouple cache identity from the download URL — bumping the key forces a
// fresh download and stores the new bytes under the new key, leaving any
// in-flight player on the old key untouched until it releases.
SvgaCache.preload([
  'https://cdn.example/gift-1.svga',                            // url-keyed
  { url: 'https://cdn.example/gift-2.svga', cacheKey: 'g2-v3' },// versioned
]);

SvgaCache.has(url);                          // boolean — disk hit?
SvgaCache.has(url, cacheKey);                // boolean — disk hit under cacheKey?
SvgaCache.path(url);                         // string | undefined — disk path
SvgaCache.path(url, cacheKey);               // string | undefined — disk path under cacheKey
await SvgaCache.size();                      // total bytes on disk
await SvgaCache.count();                     // total entries on disk
SvgaCache.setLimit(50 * 1024 * 1024);        // disk bytes; LRU evicts to fit
SvgaCache.setMemoryLimit(16 * 1024 * 1024);  // in-memory decoded-entity bytes
SvgaCache.setMaxAgeMs(24 * 60 * 60 * 1000);  // TTL — stale entries miss + re-download
await SvgaCache.evictExpired();              // sweep TTL-expired entries; returns count removed
SvgaCache.clear();                           // wipes both disk and in-memory caches
```

The disk cache lives under the platform cache directory (`Context.cacheDir/svga_cache` on Android, `Caches/svga_cache` on iOS). Files are SHA-256-keyed by `cacheKey` (which falls back to the URL when omitted), so the same key maps to the same file across launches and devices. When a write would exceed `setLimit`, the LRU policy evicts the least-recently-used entries first; entries older than `setMaxAgeMs` are treated as misses on read and reaped by `evictExpired()`.

The `<SvgaPlayer>` component takes the same `cacheKey` prop:

```tsx
<SvgaPlayer
  source="https://cdn.example/gift-2.svga"
  cacheKey="g2-v3"
  loops={2}
/>
```

Bumping `cacheKey` triggers a fresh download under the new key while still serving the URL.

### Styling and layout

The view has a transparent background; it inherits whatever style you give it. Common patterns:

```tsx
// Fixed size
<SvgaPlayer source={url} style={{ width: 200, height: 200 }} />

// Fill a container, contain the content
<SvgaPlayer source={url} style={StyleSheet.absoluteFill} scaleMode="aspectFit" />

// Cover the container, cropping if needed
<SvgaPlayer source={url} style={styles.cover} scaleMode="aspectFill" />

// Stretch to the container regardless of aspect ratio
<SvgaPlayer source={url} style={styles.stretch} scaleMode="fill" />
```

### Sequencing multiple animations

Render conditionally and let `key` reset the player between sources:

```tsx
const [step, setStep] = useState(0);
const sources = [intro, body, outro];

<SvgaPlayer
  key={step}
  source={sources[step]}
  loops={1}
  onFinish={() => setStep((s) => Math.min(s + 1, sources.length - 1))}
/>;
```

## API reference

### `<SvgaPlayer>` props

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `source` | `string` | - | URL, file path, or bundled asset |
| `loops` | `number` | `0` | Number of loops; `0` = infinite |
| `autoPlay` | `boolean` | `true` | Play immediately once loaded |
| `speed` | `number` | `1.0` | Playback speed multiplier (0.05 minimum) |
| `muteBuiltInAudio` | `boolean` | auto | If omitted, becomes `true` when `sounds` is non-empty |
| `builtInAudioVolume` | `number` | `1.0` | 0-1 |
| `playInBackground` | `boolean` | `false` | If `false`, playback (frames + audio) auto-pauses when the player leaves the visible window or the app is backgrounded. Set to `true` for video-style background audio. |
| `sounds` | `SvgaSound[]` | - | Extra MP3s to play alongside the animation |
| `scaleMode` | `'fill' \| 'aspectFit' \| 'aspectFill'` | `'aspectFit'` | How the content fits the view |
| `style` | `ViewStyle` | - | Standard RN view style |
| `onStart` | `() => void` | - | Fires when playback transitions from idle to playing |
| `onLoop` | `(count: number) => void` | - | Fires at the end of each loop |
| `onFinish` | `() => void` | - | Fires when `loops` is reached |
| `onError` | `(message: string) => void` | - | Fires on load / parse / network errors |

### Types

```ts
type ScaleMode = 'fill' | 'aspectFit' | 'aspectFill';

interface SvgaSound {
  key: string;
  url: string;
  playOn: 'start' | 'finish';
  volume?: number; // 0..1
}

interface SvgaPlayerHandle {
  play: () => void;
  pause: () => void;
  stop: () => void;
  seekToFrame: (frame: number) => void;
  seekToProgress: (progress: number) => void;
}
```

## Notes per platform

### Android

- Renders into a custom `View` via `Canvas` + `drawBitmap`, transparent by default
- Uses `MediaPlayer` (per track) with `USAGE_MEDIA` so it doesn't request audio focus; broad codec coverage
- Network requests use `HttpURLConnection` with explicit 15s connect / 30s read timeouts
- Bundle and per-entry size limits guard against malicious zips (64 MB bundle / 32 MB entry)

### iOS

- Renders into a `UIView` driven by `CADisplayLink` (weak proxy, no retain cycle)
- Audio uses `AVAudioPlayer` instances and deliberately does not configure `AVAudioSession`, so the host app's session category is preserved
- ZIP decompression uses Apple's `Compression` framework (raw DEFLATE) - no third-party dependency
- `URLSession` requests use 15s/60s timeouts

## Performance

- Decoded `.svga` entities are kept in an LRU keyed by source string. The default limit is **32 MB on regular devices, automatically reduced to 8-16 MB on devices flagged as low-RAM** (`ActivityManager.isLowRamDevice` or `memoryClass < 256`). On iOS, `NSCache` uses the same default and auto-purges under memory pressure.
- On Android, the memory cache subscribes to `ComponentCallbacks2`. When the system reports `TRIM_MEMORY_RUNNING_LOW` the cache halves itself; `TRIM_MEMORY_RUNNING_CRITICAL` (or `onLowMemory`) clears it. This keeps long sessions stable on small devices without manual intervention.
- Per-frame transforms are pre-composed at parse time, so the draw path is just `concatenate(matrix) + draw` - no per-frame allocation.
- Bitmaps are decoded with a 2048 px longest-side cap (`BitmapFactory.inSampleSize` on Android, `kCGImageSourceThumbnailMaxPixelSize` on iOS) so a single oversized asset can't OOM the device.
- Concurrent loads of the same URL are coalesced into one network + parse + decode.
- Disk cache evicts the oldest files (by mtime) when over the configured byte limit.
- The frame loop tracks expected wake-up time and self-corrects so playback doesn't drift on a busy main thread.

## Security

- URL scheme allow-list (`http`, `https`, `file`, `asset`)
- Path traversal (`..`) rejected at the validator and in zip entry names
- Bundle and entry size caps in the parser
- Atomic disk writes (tmp + rename) so a partial download can't corrupt the cache

## Lifecycle and background playback

By default, `<SvgaPlayer>` stops both its frame loop and any active audio whenever:

- The component unmounts.
- The native view leaves the visible window (e.g. you navigated away in a stack navigator on iOS / Android).
- The app moves to the background (`AppState` transitions away from `'active'`).

This is what you usually want for gift animations and one-shot effects: the user moves on, the audio stops with them. When the player comes back on screen the animation does **not** auto-resume; call `play()` on the ref or remount to restart.

Set `playInBackground={true}` if you want video-player-style behaviour, where audio (and the underlying playback state) survive backgrounding and navigation:

```tsx
<SvgaPlayer source={url} playInBackground />
```

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Cannot find module 'react-native-svga'` at runtime | Native rebuild missed | Bare: re-run `pod install` and rebuild. Expo: re-run `expo prebuild` + `expo run:*` |
| Crashes/errors only in Expo Go | This package isn't supported by Expo Go | Switch to a development build (see Installation) |
| Animation never appears, no error | `source` URL unreachable / 404 | Check the URL in a browser; listen on `onError` |
| Built-in audio not playing | `muteBuiltInAudio` is `true`, or `sounds` is non-empty | Pass `muteBuiltInAudio={false}` |
| Disk cache filling up | `setLimit` not configured | Call `SvgaCache.setLimit(maxBytes)` at startup |

## Roadmap

- [ ] Image caching for non-bundle PNG sources (Lottie-style remote image overrides)
- [ ] Configurable network adapter (drop in OkHttp / `fetch` proxy)
- [ ] Optional pre-decoded frame buffers for ultra-low-latency replays

## Contributing

- [Development workflow](CONTRIBUTING.md#development-workflow)
- [Sending a pull request](CONTRIBUTING.md#sending-a-pull-request)
- [Code of conduct](CODE_OF_CONDUCT.md)

```sh
npm install
npm run nitrogen
npm run typecheck
npm run lint
npm test
```

Run the example app from `example/`:

```sh
cd example
npm install
npm run android    # or: npm run ios
```

## License

MIT © [dasimems](https://github.com/dasimems)

---

Built with [Nitro Modules](https://nitro.margelo.com/) and [create-react-native-library](https://github.com/callstack/react-native-builder-bob).
