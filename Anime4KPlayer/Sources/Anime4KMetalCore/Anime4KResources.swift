import Foundation

/// Access to the package's bundled resources (GLSL shaders, compiled Metal library).
public enum Anime4KResources {
    /// The SwiftPM resource bundle of this module.
    public static var bundle: Bundle { .module }

    /// URL of a bundled GLSL file, e.g. `glslURL("Anime4K_Upscale_CNN_x2_M.glsl", subdir: "Upscale")`.
    public static func glslURL(_ name: String, subdir: String) -> URL? {
        bundle.url(forResource: name, withExtension: nil, subdirectory: "glsl/" + subdir)
    }
}
