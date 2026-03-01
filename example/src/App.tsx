import { View, StyleSheet } from 'react-native';
import { SvgaPlayer } from 'react-native-svga';

export default function App() {
  return (
    <View style={styles.container}>
      <SvgaPlayer source="https://assets.svga.io/svga/sample.svga" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  box: {
    width: 60,
    height: 60,
    marginVertical: 20,
  },
});
