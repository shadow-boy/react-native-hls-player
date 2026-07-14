import { useState } from 'react';
import { View, StyleSheet, Button, Text } from 'react-native';
import { HlsPlayerView } from 'react-native-hls-player';

export default function App() {
  const [paused, setPaused] = useState(false);
  const [progress, setProgress] = useState(0);

  return (
    <View style={styles.container}>
      <HlsPlayerView
        style={styles.player}
        sourceUrl="https://example.com/stream/index.m3u8"
        keyUrl="https://example.com/api/v1/video/key/xxxx"
        headers={{ Authorization: 'Bearer demo-token' }}
        paused={paused}
        onLoad={(event) => console.log('onLoad', event.duration)}
        onProgress={(event) => setProgress(event.currentTime)}
        onEnd={() => console.log('onEnd')}
        onError={(event) => console.warn('onError', event.message)}
      />
      <Text style={styles.text}>currentTime: {progress.toFixed(1)}s</Text>
      <Button
        title={paused ? '播放' : '暂停'}
        onPress={() => setPaused((value) => !value)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  player: {
    width: '100%',
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
  },
  text: {
    color: '#fff',
    textAlign: 'center',
    paddingVertical: 12,
  },
});
