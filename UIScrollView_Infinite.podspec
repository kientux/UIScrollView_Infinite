#
# Be sure to run `pod lib lint UIScrollView_Infinite.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'UIScrollView_Infinite'
  s.version          = '1.0.2'
  s.summary          = 'UIScrollView_Infinite'

  s.description      = <<-DESC
  # UIScrollView_Infinite

  Swift version of https://github.com/pronebird/UIScrollView-InfiniteScroll
  
  >  `load` cannot be overriden in Swift, so method swizzling cannot automatically works. You have to manually call `UIScrollView.swizzleInfiniteScrolls()` once (eg. in AppDelegate).
                       DESC

  s.homepage         = 'https://github.com/kientux/UIScrollView_Infinite'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'kientux' => 'ntkien93@gmail.com' }
  s.source           = { :git => 'https://github.com/kientux/UIScrollView_Infinite.git', :tag => s.version.to_s }

  s.ios.deployment_target = '11.0'
  s.swift_versions = '5.5'

  s.source_files = 'Sources/UIScrollView_Infinite/**/*'
end
