#!/usr/bin/env ruby
# Adds the SwiftfinTests unit-testing target (app-hosted) to Swiftfin.xcodeproj
# and makes it the SOLE testable of the shared Swiftfin scheme's Test action.
# Idempotent.
#
# The bundle is hosted in the app (TEST_HOST/BUNDLE_LOADER) so tests can
# `@testable import Swiftfin`. TEST_HOST includes $(BUNDLE_EXECUTABLE_FOLDER_PATH)
# because the shipped app layout splits the executable from the bundle root.
#
# Usage: ruby Scripts/qa/add_unit_tests.rb [path/to/Swiftfin.xcodeproj]

require 'xcodeproj'

project_path = ARGV[0] || 'Swiftfin.xcodeproj'
scheme_path  = File.join(project_path, 'xcshareddata', 'xcschemes', 'Swiftfin.xcscheme')
tests_dir    = 'Tests/SwiftfinTests'
target_name  = 'SwiftfinTests'

project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'Swiftfin iOS' } ||
             project.targets.find { |t| t.name == 'Swiftfin' } ||
             abort("app target 'Swiftfin iOS' not found")

existing = project.targets.find { |t| t.name == target_name }
project.targets.delete(existing) if existing

# The test bundle @testable-imports the app module, so its deployment target
# MUST be >= the app's effective IPHONEOS_DEPLOYMENT_TARGET (target-level
# override first, then project-level), or swift-frontend fails with
# "compiling for iOS X, but module 'Swiftfin' has a minimum deployment
# target of iOS Y". Derive it instead of hardcoding so the two can never
# drift apart again.
deployment_target = (
  app_target.build_configurations.map { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] } +
  project.build_configurations.map { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] }
).compact.reject(&:empty?).first || '18.0'

target = project.new_target(:unit_test_bundle, target_name, :ios, deployment_target)

# Sources
tests_group = project.main_group.find_subpath('Tests', true)
tests_group.set_source_tree('<group>')
tests_group.set_path('Tests')
tests_leaf = tests_group.find_subpath('SwiftfinTests', true)
tests_leaf.set_source_tree('<group>')
tests_leaf.set_path('SwiftfinTests')
test_files = Dir.glob(File.join(tests_dir, '*.swift')).sort
raise "no test sources under #{tests_dir}" if test_files.empty?

test_files.each do |path|
  ref = tests_leaf.files.find { |f| f.path == File.basename(path) } ||
        tests_leaf.new_reference(File.basename(path))
  ref.set_source_tree('<group>')
  target.source_build_phase.add_file_reference(ref)
end

target.add_dependency(app_target)

target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.swiftfin.SwiftfinTests'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['TEST_TARGET_NAME'] = app_target.name
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Swiftfin.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Swiftfin'
  s['BUNDLE_LOADER'] = '$(TEST_HOST)'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SDKROOT'] = 'iphoneos'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['CODE_SIGN_STYLE'] = 'Manual'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['IPHONEOS_DEPLOYMENT_TARGET'] = deployment_target
  s['SWIFT_VERSION'] = '5.0'
  s['SUPPORTS_MACCATALYST'] = 'NO'
end

project.save

# --- Scheme wiring: unit tests are the ONLY testable -------------------------
# (The Screenshots UI-test target stays out of every ship build; it is built
# explicitly by its own flows, and compiling it here would just burn time.)
scheme = Xcodeproj::XCScheme.new(scheme_path)
scheme.test_action.testables = []
scheme.add_test_target(target)
scheme.set_launch_target(app_target)  # ensures the app is in BuildAction too
scheme.save_as(project_path, 'Swiftfin', true)

puts "Added #{target_name} (#{test_files.size} sources) to #{project_path}; host: #{app_target.name}"
