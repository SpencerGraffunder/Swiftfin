#!/usr/bin/env ruby
# Adds the SwiftfinUITests UI-testing target to Swiftfin.xcodeproj and wires it
# into the shared Swiftfin scheme's Test action. Idempotent.
#
# Usage: ruby Scripts/qa/add_ui_tests.rb [path/to/Swiftfin.xcodeproj]

require 'xcodeproj'
require 'rexml/document'
require 'fileutils'

project_path = ARGV[0] || 'Swiftfin.xcodeproj'
scheme_path  = File.join(project_path, 'xcshareddata', 'xcschemes', 'Swiftfin.xcscheme')
tests_dir    = 'Tests/SwiftfinUITests'

project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'Swiftfin' } ||
             abort("app target 'Swiftfin' not found")

target_name = 'SwiftfinUITests'
existing = project.targets.find { |t| t.name == target_name }
project.targets.delete(existing) if existing

target = project.new_target(:ui_test_bundle, target_name, :ios, '16.4')

# Sources
group = project.main_group.find_subpath('Tests', true)
group.find_subpath(target_name, true)
test_files = Dir.glob(File.join(tests_dir, '*.swift')).sort
raise "no test sources under #{tests_dir}" if test_files.empty?

test_files.each do |path|
  rel = path.split('/').drop(1).join('/') # Tests/... relative to project root group
  ref = group.files.find { |f| f.path&.end_with?(rel) } ||
        group.new_reference(rel)
  target.source_build_phase.add_file_reference(ref)
end

# Dependency: build the app first
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
test_action = doc.root.elements['TestAction'] ||
              doc.root.elements.add('TestAction',
                                     'buildConfiguration' => 'Debug',
                                     'selectedDebuggerIdentifier' => 'Xcode.DebuggerFoundation.Debugger.LLDB')

list = test_action.elements['Testables'] || test_action.elements.add('Testables')

# Drop stale reference if rerun
list.delete(list.elements["TestableBuildableReference[@BlueprintName='#{target_name}']"])

parent = doc.root.elements['TestAction']
macro = test_action.attributes['macroExpansion']
# MacroExpansion on the launch-action reference for the app
app_ref = doc.root.elements['LaunchAction']&.elements&.[]('BuildableProductRunnable')&.elements&.[]('BuildableReference')

ref_attrs = app_ref ? app_ref.attributes.each_attribute.to_h { |a| [a.name, a.value] } : {}
ref_attrs.delete('BlueprintIdentifier')
ref_attrs['BuildableIdentifier'] = 'primary'
ref_attrs['BlueprintIdentifier'] = app_target.uuid
ref_attrs['BuildableName'] = 'Swiftfin.app'
ref_attrs['BlueprintName'] = app_target.name

testable = list.add_element('TestableBuildableReference')
ref_attrs.each { |k, v| testable.add_attribute(k, v) }
testable.add_attribute('Skipped', 'NO')
testable.add_attribute('Parallelizable', 'NO')
testable.add_attribute('PublishedReference', 'NO')

test_action.add_attribute('macroExpansion', 'primary') unless test_action.attributes['macroExpansion']

# Also patch LaunchAction to the same app target so the scheme remains launchable
launch = doc.root.elements['LaunchAction']
if launch && (bp = launch.elements['BuildableProductRunnable/BuildableReference'])
  bp.add_attribute('BlueprintIdentifier', app_target.uuid)
  bp.add_attribute('BuildableName', 'Swiftfin.app')
  bp.add_attribute('BlueprintName', app_target.name)
end

File.open(scheme_path, 'w') { |f| doc.write(f, indent: 2) }
puts "Added #{target_name} (#{test_files.size} sources) to #{project_path} and scheme"
