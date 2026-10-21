#!/usr/bin/env ruby
# Adds the SwiftfinUITests UI-testing target to Swiftfin.xcodeproj and wires it
# into the shared Swiftfin scheme's Test action. Idempotent.
#
# Usage: ruby Scripts/qa/add_ui_tests.rb [path/to/Swiftfin.xcodeproj]

require 'xcodeproj'
require 'rexml/document'

project_path = ARGV[0] || 'Swiftfin.xcodeproj'
scheme_path  = File.join(project_path, 'xcshareddata', 'xcschemes', 'Swiftfin.xcscheme')
tests_dir    = 'Tests/SwiftfinUITests'
target_name  = 'SwiftfinUITests'

project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'Swiftfin iOS' } ||
             project.targets.find { |t| t.name == 'Swiftfin' } ||
             abort("app target 'Swiftfin iOS' not found")
ios = true
bundle_prefix = 'app.swiftfin'

existing = project.targets.find { |t| t.name == target_name }
project.targets.delete(existing) if existing

target = project.new_target(:ui_test_bundle, target_name, :ios, '16.4')

# Sources
tests_group = project.main_group.find_subpath('Tests', true)
test_files = Dir.glob(File.join(tests_dir, '*.swift')).sort
raise "no test sources under #{tests_dir}" if test_files.empty?

test_files.each do |path|
  rel = path.split('/').drop(1).join('/') # relative to the Tests group
  ref = tests_group.files.find { |f| f.path&.end_with?(rel) } ||
        tests_group.new_reference(rel)
  target.source_build_phase.add_file_reference(ref)
end

target.add_dependency(app_target)

target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{bundle_prefix}.SwiftfinUITests"
  s['TEST_TARGET_NAME'] = app_target.name
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Swiftfin.app/$(BUNDLE_LOADER_PATH)' if ios
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SDKROOT'] = 'iphoneos'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.4'
  s['SWIFT_VERSION'] = '5.0'
  s['SUPPORTS_MACCATALYST'] = 'NO'
end

project.save

# --- Scheme wiring (xcodeproj gem API; keeps element order valid) -----------
scheme = Xcodeproj::XCScheme.new(scheme_path)
unless File.read(scheme_path).include?(target_name)
  scheme.add_build_target(target, false)   # BuildForTesting=YES, Running=NO
  scheme.add_test_target(target)
  scheme.set_launch_target(app_target)     # also sets TestAction macroExpansion
end
scheme.save_as(project_path, 'Swiftfin', true)

puts "Added #{target_name} (#{test_files.size} sources) to #{project_path}; host: #{app_target.name}"
