Pod::Spec.new do |s|
  s.name             = 'loopit_minis'
  s.version          = '0.1.0'
  s.summary          = 'Camera and asset editing minis for Buzzit.in.'
  s.description      = 'Camera and asset editing minis for Buzzit.in.'
  s.homepage         = 'https://github.com/PoonamMaxPlay/minis.git'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'maxplaydigital@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'Accelerate', 'UIKit', 'Photos', 'Speech', 'Vision', 'VideoToolbox', 'AudioToolbox', 'Metal', 'MetalKit'
  s.libraries = 'iconv', 'bz2', 'z'
  # Vendored FFmpeg.xcframework is produced by ios/ffmpeg/build_ios.sh.
  # When the framework is absent (clean checkout), pod install will fail —
  # build the framework first or comment this line out for native-disabled
  # builds.
  s.vendored_frameworks = 'Frameworks/FFmpeg.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'ENABLE_BITCODE' => 'NO',
  }
  s.swift_version = '5.0'
end
