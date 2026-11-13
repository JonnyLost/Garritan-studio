/// Public product identity is deliberately independent of executable and document IDs.
///
/// The display name may change. The legacy identifiers must remain stable until
/// a separately reviewed compatibility migration is implemented and tested.
public enum StudioApplicationIdentity {
    public static let displayName = "Studio"
    public static let legacyBundleIdentifier = "com.musio.create"
    public static let legacyProjectTypeIdentifier = "com.musio.create.project"
}
