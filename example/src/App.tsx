import { useCallback, useMemo, useRef, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  type ViewStyle,
} from 'react-native';
import {
  SvgaCache,
  SvgaPlayer,
  type SvgaPlayerHandle,
  type SvgaSound,
} from 'react-native-svga';

// These URLs are reasonable third-party samples but may go down without
// notice. Override them with your own hosted copies if the example breaks.
// Set EXPO_PUBLIC_SVGA_SAMPLE_URL / SECONDARY_URL / EXTERNAL_MP3_URL in your
// environment, or edit the constants below.
const REMOTE_URL =
  process.env.EXPO_PUBLIC_SVGA_SAMPLE_URL ||
  'https://assets.svga.io/svga/sample.svga';
const SECONDARY_URL =
  process.env.EXPO_PUBLIC_SVGA_SECONDARY_URL ||
  'https://assets.svga.io/svga/sample2.svga';
const EXTERNAL_MP3 =
  process.env.EXPO_PUBLIC_SVGA_EXTERNAL_MP3 ||
  'https://www.kozco.com/tech/piano2-CoolEdit.mp3';

type Scenario =
  | 'remote'
  | 'controls'
  | 'externalAudio'
  | 'cacheStatus'
  | 'errorPath';

const SCENARIOS: { id: Scenario; label: string; hint: string }[] = [
  {
    id: 'remote',
    label: '1. Remote streaming + cache',
    hint: 'First play hits the network; replay loads instantly from disk + memory.',
  },
  {
    id: 'controls',
    label: '2. Programmatic controls',
    hint: 'Use play / pause / stop / seek. Verify smooth resume.',
  },
  {
    id: 'externalAudio',
    label: '3. External MP3 (mutes built-in)',
    hint: 'External MP3 plays on start; built-in audio auto-mutes.',
  },
  {
    id: 'cacheStatus',
    label: '4. Cache facade',
    hint: 'preload + size + path + clear. Watch the status panel.',
  },
  {
    id: 'errorPath',
    label: '5. Error path',
    hint: 'Invalid url should fire onError without crashing.',
  },
];

export default function App() {
  const [scenario, setScenario] = useState<Scenario>('remote');

  return (
    <ScrollView style={styles.root} contentContainerStyle={styles.content}>
      <Text style={styles.title}>react-native-svga</Text>
      <View style={styles.tabs}>
        {SCENARIOS.map((s) => {
          const active = s.id === scenario;
          return (
            <Pressable
              key={s.id}
              onPress={() => setScenario(s.id)}
              style={[styles.tab, active && styles.tabActive]}
            >
              <Text style={[styles.tabLabel, active && styles.tabLabelActive]}>
                {s.label}
              </Text>
            </Pressable>
          );
        })}
      </View>

      <Text style={styles.hint}>
        {SCENARIOS.find((s) => s.id === scenario)?.hint}
      </Text>

      {scenario === 'remote' && <RemoteScenario />}
      {scenario === 'controls' && <ControlsScenario />}
      {scenario === 'externalAudio' && <ExternalAudioScenario />}
      {scenario === 'cacheStatus' && <CacheScenario />}
      {scenario === 'errorPath' && <ErrorPathScenario />}
    </ScrollView>
  );
}

const RemoteScenario = () => {
  const [reloadKey, setReloadKey] = useState(0);
  const [event, setEvent] = useState<string>('idle');

  return (
    <View style={styles.card}>
      <SvgaPlayer
        key={reloadKey}
        source={REMOTE_URL}
        loops={2}
        style={styles.player}
        onStart={() => setEvent('started')}
        onLoop={(c) => setEvent(`loop ${c}`)}
        onFinish={() => setEvent('finished')}
        onError={(m) => setEvent(`error: ${m}`)}
      />
      <Text style={styles.status}>state: {event}</Text>
      <Pressable
        onPress={() => setReloadKey((k) => k + 1)}
        style={styles.button}
      >
        <Text style={styles.buttonLabel}>Replay (cache hit expected)</Text>
      </Pressable>
    </View>
  );
};

const ControlsScenario = () => {
  const ref = useRef<SvgaPlayerHandle>(null);
  const [event, setEvent] = useState<string>('idle');

  const action = useCallback((label: string, fn: () => void) => {
    fn();
    setEvent(label);
  }, []);

  return (
    <View style={styles.card}>
      <SvgaPlayer
        ref={ref}
        source={REMOTE_URL}
        autoPlay={false}
        loops={0}
        style={styles.player}
        onStart={() => setEvent('started')}
        onLoop={(c) => setEvent(`loop ${c}`)}
        onFinish={() => setEvent('finished')}
        onError={(m) => setEvent(`error: ${m}`)}
      />
      <Text style={styles.status}>state: {event}</Text>
      <View style={styles.buttonRow}>
        <Pressable
          style={styles.button}
          onPress={() => action('play()', () => ref.current?.play())}
        >
          <Text style={styles.buttonLabel}>Play</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={() => action('pause()', () => ref.current?.pause())}
        >
          <Text style={styles.buttonLabel}>Pause</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={() => action('stop()', () => ref.current?.stop())}
        >
          <Text style={styles.buttonLabel}>Stop</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={() =>
            action('seek 50%', () => ref.current?.seekToProgress(0.5))
          }
        >
          <Text style={styles.buttonLabel}>Seek 50%</Text>
        </Pressable>
      </View>
    </View>
  );
};

const ExternalAudioScenario = () => {
  const sounds = useMemo<SvgaSound[]>(
    () => [
      {
        key: 'cheer',
        url: EXTERNAL_MP3,
        playOn: 'start',
        volume: 0.8,
      },
    ],
    []
  );
  const [event, setEvent] = useState<string>('idle');

  return (
    <View style={styles.card}>
      <SvgaPlayer
        source={REMOTE_URL}
        sounds={sounds}
        loops={1}
        style={styles.player}
        onStart={() => setEvent('started - external mp3 playing')}
        onFinish={() => setEvent('finished')}
        onError={(m) => setEvent(`error: ${m}`)}
      />
      <Text style={styles.status}>state: {event}</Text>
      <Text style={styles.hint}>
        Built-in audio is auto-muted because `sounds` is non-empty.
      </Text>
    </View>
  );
};

const CacheScenario = () => {
  const [status, setStatus] = useState<string>('');

  const updateStatus = useCallback(async () => {
    const cached = SvgaCache.has(REMOTE_URL);
    const path = SvgaCache.path(REMOTE_URL);
    const size = await SvgaCache.size();
    const human = (size / (1024 * 1024)).toFixed(2);
    setStatus(`cached: ${cached}\npath: ${path ?? 'none'}\ntotal: ${human} MB`);
  }, []);

  const preload = useCallback(async () => {
    setStatus('preloading...');
    try {
      await SvgaCache.preload([REMOTE_URL, SECONDARY_URL]);
      await updateStatus();
    } catch (e) {
      setStatus(`error: ${(e as Error).message}`);
    }
  }, [updateStatus]);

  const clear = useCallback(() => {
    SvgaCache.clear();
    setStatus('cleared');
  }, []);

  return (
    <View style={styles.card}>
      <Text style={styles.status}>{status || 'Tap a button to begin.'}</Text>
      <View style={styles.buttonRow}>
        <Pressable style={styles.button} onPress={preload}>
          <Text style={styles.buttonLabel}>Preload 2 files</Text>
        </Pressable>
        <Pressable style={styles.button} onPress={updateStatus}>
          <Text style={styles.buttonLabel}>Refresh status</Text>
        </Pressable>
        <Pressable style={styles.button} onPress={clear}>
          <Text style={styles.buttonLabel}>Clear cache</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={() => SvgaCache.setLimit(8 * 1024 * 1024)}
        >
          <Text style={styles.buttonLabel}>Set limit 8MB</Text>
        </Pressable>
      </View>
    </View>
  );
};

const ErrorPathScenario = () => {
  const [event, setEvent] = useState<string>('idle');
  return (
    <View style={styles.card}>
      <SvgaPlayer
        source="https://invalid.invalid/does-not-exist.svga"
        style={styles.player}
        onStart={() => setEvent('started (unexpected)')}
        onError={(m) => setEvent(`error received: ${m}`)}
      />
      <Text style={styles.status}>state: {event}</Text>
    </View>
  );
};

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: '#0c0e14',
  },
  content: {
    padding: 16,
    paddingTop: 60,
    paddingBottom: 60,
  },
  title: {
    color: '#e6e8eb',
    fontSize: 22,
    fontWeight: '700',
    marginBottom: 12,
  },
  tabs: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 6,
    marginBottom: 12,
  },
  tab: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 6,
    backgroundColor: '#1a1f2b',
  },
  tabActive: {
    backgroundColor: '#356bff',
  },
  tabLabel: {
    color: '#9aa3b2',
    fontSize: 12,
  },
  tabLabelActive: {
    color: '#ffffff',
    fontWeight: '600',
  },
  hint: {
    color: '#9aa3b2',
    fontSize: 12,
    marginBottom: 12,
  },
  card: {
    backgroundColor: '#11141d',
    borderRadius: 12,
    padding: 12,
    gap: 10,
  },
  player: {
    width: '100%',
    height: 280,
    borderRadius: 8,
  } as ViewStyle,
  status: {
    color: '#e6e8eb',
    fontSize: 13,
    fontFamily: 'Menlo',
  },
  buttonRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 6,
  },
  button: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 8,
    backgroundColor: '#1a1f2b',
  },
  buttonLabel: {
    color: '#e6e8eb',
    fontSize: 13,
    fontWeight: '500',
  },
});
