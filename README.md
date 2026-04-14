# SecretVault 🔒

A motion-controlled, highly secure notes vault built with Flutter.

I built this project to experiment with alternative, physical ways of authentication. Instead of typing a PIN or drawing a screen pattern (which can easily be shoulder-surfed by someone sitting next to you), SecretVault relies on a unique Two-Factor Authentication system:
1. **Biometrics:** Scans your fingerprint to prove identity.
2. **Spatial Gestures:** You must perform a secret sequence of 4 physical hand movements (e.g., Tilt Left, Shake, Tilt Up, Tilt Right) to unlock the app.

## Features ✨
* **Multi-Factor Auth:** Native Android fingerprint integration running sequentially before hardware accelerometer detection.
* **Persistent Lockout:** Failing the gesture pattern 5 times triggers a rigorous 30-second lockout that survives app restarts.
* **Encrypted Storage:** Notes and metadata are handled securely via SQLite with AES encryption and `flutter_secure_storage`.
* **State Management:** Fully reactive UI using Provider.
* **Sensor Math:** Custom cooldown and debounce algorithms in Dart to prevent a single wrist flick from registering as 10 consecutive gestures.

## How to run it 🚀
You'll need a standard Flutter development environment setup. Wait – **connect a physical Android device!** Gestures don't work reliably on Android Emulators since they lack real-world hardware accelerometers.

```bash
flutter pub get
flutter run
```

## Tech Stack 🛠️
* **Dart / Flutter**
* `provider` (Reactive state)
* `sensors_plus` (Hardware accelerometer stream)
* `local_auth` (Native Android fingerprint bridging)
* `sqflite` + `flutter_secure_storage` (Persistence & Security)
