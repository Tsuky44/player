#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint media_kit_libs_macos_video.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'media_kit_libs_macos_video'
  s.version          = '1.0.4'
  s.summary          = 'macOS dependency package for package:media_kit'
  s.description      = <<-DESC
  macOS dependency package for package:media_kit.
                       DESC
  s.homepage         = 'https://github.com/media-kit/media-kit.git'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hitesh Kumar Saini' => 'saini123hitesh@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  # Onyx : libmpv n'est plus embarqué sur les appareils Apple, où AetherEngine
  # lit tout (ADR-0038). Son FFmpeg passait devant celui d'AetherEngine à
  # l'édition des liens, et la lecture plantait dès l'ouverture du fichier.
  # Le paquet reste déclaré pour Windows et Linux, sans rien fournir ici.

  s.platform = :osx, '10.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
