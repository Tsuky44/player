#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint media_kit_video.podspec` to validate before publishing.
#

require_relative '../common/darwin/Podspec/media_kit_utils.rb'

Pod::Spec.new do |s|
  # Setup required files
  system("make -C ../common/darwin HEADERS_DESTDIR=\"$(pwd)/Headers\"")

  # Initialize `MediaKitUtils`
  mku = MediaKitUtils.new(MediaKitUtils::Platform::MACOS)

  s.name             = 'media_kit_video'
  s.version          = '0.0.1'
  s.summary          = 'Native implementation for video playback in package:media_kit'
  s.description      = <<-DESC
  Native implementation for video playback in package:media_kit.
                       DESC
  s.homepage         = 'https://github.com/media-kit/media-kit.git'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hitesh Kumar Saini' => 'saini123hitesh@gmail.com' }

  s.source           = { :path => '.' }
  s.platform         = :osx, '10.9'
  s.swift_version    = '5.0'
  s.dependency         'FlutterMacOS'

  # Onyx : libmpv n'est plus embarqué sur les appareils Apple, où AetherEngine
  # lit tout (ADR-0038). Son FFmpeg passait devant celui d'AetherEngine à
  # l'édition des liens, et la lecture plantait dès l'ouverture du fichier.
  # Le plugin passe donc toujours par son bouchon, sans lier Mpv.
  if false && mku.libs_found
    # Define paths to frameworks dir
    framework_search_paths_macosx = sprintf('$(PROJECT_DIR)/../Flutter/ephemeral/.symlinks/plugins/%s/macos/Frameworks/.symlinks/mpv/macos', mku.libs_package)

    s.source_files        = 'Classes/plugin/**/*.swift', 'Headers/**/*.h'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE'                      => 'YES',
      'GCC_WARN_INHIBIT_ALL_WARNINGS'       => 'YES',
      'GCC_PREPROCESSOR_DEFINITIONS'        => '"$(inherited)" GL_SILENCE_DEPRECATION COREVIDEO_SILENCE_GL_DEPRECATION',
      'FRAMEWORK_SEARCH_PATHS[sdk=macosx*]' => sprintf('"$(inherited)" "%s"', framework_search_paths_macosx),
      'OTHER_LDFLAGS'                       => '"$(inherited)" -framework Mpv',
    }
  else
    s.source_files        = 'Classes/stub/**/*.swift'
    s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  end
end
