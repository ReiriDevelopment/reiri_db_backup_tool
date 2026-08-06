// File purpose: Defines application-wide version and controller model constants.

/// Human-readable version shown in the application UI.
///
/// Keep this aligned with the semantic version in `pubspec.yaml` (the build
/// suffix is intentionally omitted from the UI).
const String appVersion = '1.0.0';

/// Controller models accepted by discovery and QR/QRC import.
///
/// An empty list means that every controller model is accepted.
const List<String> supportedModels = [];
