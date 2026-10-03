/// The release this binary belongs to. It must equal MARKETING_VERSION in the repository's VERSION file,
/// the one source the Mac app and the Linux packages read; a CLI test holds the two together.
enum VizierVersion {
    static let marketing = "0.2.0"
}
