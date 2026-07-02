Pod::Spec.new do |s|
  s.name             = 'Webnat'
  s.version          = '1.2.0'
  s.summary          = 'Lightweight WebView–Native bridge for iOS and macOS using WKWebView.'
  s.description      = <<-DESC
    Webnat is a lightweight bridge library between native code and web content.
    It supports multiple communication modes based on WebKit's WKWebView and
    WKScriptMessageHandler, including raw messages, broadcast events, and RPC-style methods.
  DESC

  s.homepage         = 'https://github.com/auhgnayuo/webnat-darwin'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Auhgnayuo' => 'https://github.com/auhgnayuo' }
  s.source           = { :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :tag => s.version.to_s }

  s.swift_versions   = ['5.5']
  s.ios.deployment_target = '13.0'
  # iOS 14+/macOS 11+ use allowsContentJavaScript; below that use javaScriptEnabled. Swift concurrency targets iOS 13+/macOS 10.15+.
  s.osx.deployment_target = '10.15'

  s.source_files     = 'Sources/Webnat/**/*.swift'
  s.resources        = 'Sources/Webnat/PrivacyInfo.xcprivacy'

  s.frameworks       = 'WebKit'
  s.requires_arc     = true
  s.module_name      = 'Webnat'
end
