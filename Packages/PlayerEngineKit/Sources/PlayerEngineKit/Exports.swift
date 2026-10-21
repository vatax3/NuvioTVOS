// The app imports PlayerEngineKit and gets AetherEngine's API through it, so that the engine is
// linked into this dynamic framework rather than into the executable. See Package.swift for why
// that placement is the whole point of this target.
@_exported import AetherEngine
