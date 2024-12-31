source 'https://github.com/CocoaPods/Specs.git'

platform :ios, '15.0'

use_frameworks!

workspace 'VideoCamera'

target 'VideoCamera_Framework' do
    project 'VideoCamera_Framework.xcodeproj'
    pod 'Shakuro.CommonTypes', '1.9.5'
end

target 'VideoCamera_Example' do
    project 'VideoCamera_Example.xcodeproj'
    pod 'Shakuro.CommonTypes', '1.9.5'
    pod 'SwiftLint', '0.57.1'
end

post_install do |installer|

  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings.delete 'IPHONEOS_DEPLOYMENT_TARGET'
    end
  end

end
