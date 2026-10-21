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
app_product = app_target.product_reference.path || 'Swiftfin.app'

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
  s['TEST_TARGET_NAME'] = app_target.name
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SDKROOT'] = 'iphoneos'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.4'
  s['SUPPORTS_MACCATALYST'] = 'NO'
end

project.save

# --- Scheme wiring -----------------------------------------------------------
doc = File.open(scheme_path) { |f| REXML::Document.new(f) }

launch_ref = doc.root.elements['LaunchAction/BuildableProductRunnable/BuildableReference']
raise 'scheme LaunchAction reference missing' unless launch_ref

test_action = doc.root.elements['TestAction'] ||
              doc.root.elements.add_element('TestAction').tap do |el|
                el.add_attribute('buildConfiguration', 'Debug')
                el.add_attribute('selectedDebuggerIdentifier', 'Xcode.DebuggerFoundation.Debugger.LLDB')
              end

test_action.add_attribute('macroExpansion', 'primary')
test_action.add_attribute('selectedLauncherIdentifier', 'Xcode.DebuggerFoundation.Launcher.LLDB')
test_action.add_attribute('shouldUseLaunchSchemeArgsEnv', 'YES')

list = test_action.elements['Testables'] || test_action.elements.add_element('Testables')
list.delete(list.elements["TestableBuildableReference[@BlueprintName='#{target_name}']"])

testable = list.add_element('TestableBuildableReference')
testable.add_attribute('BuildableIdentifier', 'primary')
testable.add_attribute('BlueprintIdentifier', app_target.uuid)
testable.add_attribute('BlueprintName', app_target.name)
testable.add_attribute('BuildableName', app_product)
testable.add_attribute('ReferencedContainer', launch_ref.attributes['ReferencedContainer'])
testable.add_attribute('Skipped', 'NO')
testable.add_attribute('Parallelizable', 'NO')

# The scheme must also build the test target: add a BuildEntry for it
build_action = doc.root.elements['BuildAction']
build_entries = build_action && build_action.elements['BuildActionEntries']
if build_entries && !build_entries.elements["BuildableReference[@BlueprintName='#{target_name}']"]
  entry = build_entries.add_element('BuildActionEntry')
  entry.add_attribute('BuildForTesting', 'YES')
  entry.add_attribute('BuildForRunning', 'NO')
  entry.add_attribute('BuildForProfiling', 'NO')
  entry.add_attribute('BuildForArchiving', 'NO')
  entry.add_attribute('BuildForAnalyzing', 'NO')
  ref = entry.add_element('BuildableReference')
  ref.add_attribute('BuildableIdentifier', 'primary')
  ref.add_attribute('BlueprintIdentifier', target.uuid)
  ref.add_attribute('BuildableName', "#{target_name}.xctest")
  ref.add_attribute('BlueprintName', target_name)
  ref.add_attribute('ReferencedContainer', launch_ref.attributes['ReferencedContainer'])
end

File.open(scheme_path, 'w') { |f| doc.write(f, 2) }
puts "Added #{target_name} (#{test_files.size} sources) to #{project_path}; host: #{app_target.name}"
