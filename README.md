# react-native-svga

A fast, secure SVGA player for React Native, built on [Nitro Modules](https://nitro.margelo.com/). Streams `.svga` files from the network or disk, caches them transparently, and plays both built-in audio tracks and external MP3s without disrupting the host app's audio session.

> SVGA is a vector + sprite animation format used widely in livestream gift animations. It's lighter than Lottie for raster-driven animations and supports frame-synced audio.

## Features

- **Stream from anywhere** - remote URLs, local files (`file://`), or bundled assets (`asset://`)
- **Two-tier cache** - SHA-256-keyed disk cache + in-memory LRU of decoded entities, so the second play of a recent file is instant
- **Built-in + external audio** - plays `.svga`-bundled audio tracks; can layer external MP3s that play on `start`/`finish`. External MP3s auto-mute the built-in audio when present (override available)
- **Doesn't fight other audio modules** - uses an isolated `SoundPool` (Android) and per-track `AVAudioPlayer` instances (iOS) without touching `AVAudioSession`
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

```sh
npm install react-native-svga react-native-nitro-modules
# or
yarn add react-native-svga react-native-nitro-modules
```

Then run pod install for iOS:

```sh
cd ios && pod install
```

> `react-native-nitro-modules` is required because this library is implemented on top of Nitro.

## Quick start

```tsx
import { SvgaPlayer } from 'react-native-svga';

export default function App() {
  return (
    <SvgaPlayer
      source="https://assets.svga.io/svga/sample.svga"
      style={{ width: 300, height: 300 }}
      loops={0}
      onFinish={() => console.log('done')}
    />
  );
}
```

## Source formats

The `source` prop accepts:

| Form | Example | Notes |
| --- | --- | --- |
| Remote URL | `https://cdn.example/anim.svga` | Downloaded once, cached on disk, replayed from memory |
| Local file | `file:///var/.../anim.svga` or `/var/.../anim.svga` | Read directly, bypassing the cache |
| Bundled asset | `asset://animations/cheer.svga` | Read from the platform asset bundle |

Schemes other than `http`, `https`, `file`, and `asset` are rejected for safety, as are paths containing `..`.

## API

### `<SvgaPlayer>` props

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `source` | `string` | - | URL, file path, or bundled asset |
| `loops` | `number` | `0` | Number of loops; `0` = infinite |
| `autoPlay` | `boolean` | `true` | Play immediately once loaded |
| `speed` | `number` | `1.0` | Playback speed multiplier (0.05-reasonable) |
| `muteBuiltInAudio` | `boolean` | auto | If omitted, becomes `true` when `sounds` is non-empty |
| `builtInAudioVolume` | `number` | `1.0` | 0-1 |
| `sounds` | `SvgaSound[]` | - | Extra MP3s to play alongside the animation |
| `scaleMode` | `'fill' \| 'aspectFit' \| 'aspectFill'` | `'aspectFit'` | How the content fits the view |
| `style` | `ViewStyle` | - | Standard RN view style |
| `onStart` | `() => void` | - | Fires when playback transitions from idle to playing |
| `onLoop` | `(count: number) => void` | - | Fires at the end of each loop |
| `onFinish` | `() => void` | - | Fires when `loops` is reached |
| `onError` | `(message: string) => void` | - | Fires on load / parse / network errors |

### Imperative handle

```tsx
import { useRef } from 'react';
import { SvgaPlayer, type SvgaPlayerHandle } from 'react-native-svga';

const ref = useRef<SvgaPlayerHandle>(null);

<SvgaPlayer ref={ref} source={url} autoPlay={false} />

ref.current?.play();
ref.current?.pause();
ref.current?.stop();
ref.current?.seekToFrame(42);
ref.current?.seekToProgress(0.5);  // 0..1
```

### External sounds

```tsx
<SvgaPlayer
  source="https://cdn.example/gift.svga"
  sounds={[
    { key: 'cheer',   url: 'https://cdn.example/cheer.mp3',   playOn: 'start',  volume: 0.8 },
    { key: 'applause', url: 'https://cdn.example/applause.mp3', playOn: 'finish' },
  ]}
/>
```

`playOn: 'start'` triggers when the animation begins; `playOn: 'finish'` triggers when the configured loops complete. Sounds are downloaded, cached on disk, and unloaded automatically when the component unmounts.

When `sounds` is non-empty, the built-in audio bundled inside the `.svga` is muted by default. Pass `muteBuiltInAudio={false}` to layer them.

### Cache facade

```ts
import { SvgaCache } from 'react-native-svga';

// Pre-warm the disk cache at app startup
await SvgaCache.preload([
  'https://cdn.example/gift1.svga',
  'https://cdn.example/gift2.svga',
]);

SvgaCache.has(url);             // boolean
SvgaCache.path(url);            // string | null - local path of the cached file
await SvgaCache.size();         // number - total bytes on disk
SvgaCache.setLimit(50 * 1024 * 1024);  // bytes; oldest evicted first
SvgaCache.clear();              // wipes both disk and in-memory caches
```

The disk cache lives under the platform cache directory (`Context.cacheDir/svga_cache` on Android, `Caches/svga_cache` on iOS). Files are SHA-256-keyed by URL so the same source string maps to the same file across app launches.

## Notes per platform

### Android

- Renders into a custom `View` via `Canvas` + `drawBitmap`, transparent by default
- Uses `SoundPool` with `USAGE_MEDIA` so it doesn't request audio focus
- Network requests use `HttpURLConnection` with explicit 15s connect / 30s read timeouts
- Bundle and per-entry size limits guard against malicious zips (64 MB bundle / 32 MB entry)

### iOS

- Renders into a `UIView` driven by `CADisplayLink` (weak proxy, no retain cycle)
- Audio uses `AVAudioPlayer` instances and deliberately does not configure `AVAudioSession`, so the host app's session category is preserved
- ZIP decompression uses Apple's `Compression` framework (raw DEFLATE) - no third-party dependency
- `URLSession` requests use 15s/60s timeouts

## Performance

- Decoded `.svga` entities are kept in an LRU keyed by source string. The default limit is 32 MB. Adjust at runtime via `SvgaMemoryCache` (Android) or by changing the `NSCache.totalCostLimit` source for iOS if needed.
- Disk cache evicts the oldest files (by mtime) when over the configured byte limit.
- The frame loop tracks expected wake-up time and self-corrects so playback doesn't drift on a busy main thread.
- A single `Matrix` / `CGAffineTransform` is reused per draw; nothing is allocated per frame.

## Security

- URL scheme allow-list (`http`, `https`, `file`, `asset`)
- Path traversal (`..`) rejected at the validator and in zip entry names
- Bundle and entry size caps in the parser
- Atomic disk writes (tmp + rename) so a partial download can't corrupt the cache

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
