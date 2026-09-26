#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint media_kit_libs_ios_video.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'media_kit_libs_ios_video'
  s.version          = '1.0.4'
  s.summary          = 'iOS dependency package for package:media_kit'
  s.description      = <<-DESC
  iOS dependency package for package:media_kit.
                       DESC
  s.homepage         = 'https://github.com/media-kit/media-kit.git'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hitesh Kumar Saini' => 'saini123hitesh@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'

  # Onyx : libmpv n'est plus embarqué sur les appareils Apple, où AetherEngine
  # lit tout (ADR-0038). Son FFmpeg passait devant celui d'AetherEngine à
  # l'édition des liens, et la lecture plantait dès l'ouverture du fichier.
  # Le paquet reste déclaré pour Windows et Linux, sans rien fournir ici.

  s.platform = :ios, '9.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
