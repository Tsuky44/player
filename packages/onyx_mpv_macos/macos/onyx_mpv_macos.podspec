Pod::Spec.new do |s|
  s.name             = 'onyx_mpv_macos'
  s.version          = '0.1.0'
  s.summary          = 'Surface vidéo native d\'Onyx sur macOS, où libmpv dessine lui-même.'
  s.description      = <<-DESC
  Une vue AppKit exposée à Flutter (AppKitView) dont l'adresse est passée à
  libmpv comme `wid`, pour qu'il y présente ses images avec vo=gpu-next.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = 'Onyx'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  # Le libmpv livrable (native/build_release.sh), embarqué dans l'app quand il
  # a été construit. Sans lui, l'app retombe sur la texture de media_kit.
  if File.exist?(File.join(__dir__, 'Frameworks', 'OnyxMpv.xcframework'))
    s.vendored_frameworks = 'Frameworks/OnyxMpv.xcframework'
  end

  s.platform = :osx, '11.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
