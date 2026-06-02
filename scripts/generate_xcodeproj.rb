#!/usr/bin/env ruby
require "rubygems"
require "xcodeproj"
require "fileutils"
require "pathname"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "Grammarless.xcodeproj")
APP_REQUIREMENT = "-r$(PROJECT_DIR)/scripts/signing/grammarless.requirement"
CORE_REQUIREMENT = "-r$(PROJECT_DIR)/scripts/signing/grammarless_core.requirement"

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "1530"
project.root_object.attributes["LastUpgradeCheck"] = "1530"

app_target = project.new_target(:application, "Grammarless", :osx, "14.0")
core_target = project.new_target(:framework, "GrammarlessCore", :osx, "14.0")
tests_target = project.new_target(:unit_test_bundle, "GrammarlessCoreTests", :osx, "14.0")

[app_target, core_target, tests_target].each do |target|
  target.build_configurations.each do |config|
    config.build_settings["SWIFT_VERSION"] = "5.0"
    config.build_settings["CODE_SIGN_STYLE"] = "Manual"
    config.build_settings["CODE_SIGN_IDENTITY"] = "-"
    config.build_settings["AD_HOC_CODE_SIGNING_ALLOWED"] = "YES"
    config.build_settings["CODE_SIGNING_ALLOWED"] = "YES"
    config.build_settings["CODE_SIGNING_REQUIRED"] = "YES"
  end
end

app_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "local.yxp.grammarless"
  config.build_settings["INFOPLIST_FILE"] = "GrammarlessApp/Resources/Info.plist"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  config.build_settings["PRODUCT_NAME"] = "Grammarless"
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/../Frameworks"
  config.build_settings["ENABLE_HARDENED_RUNTIME"] = "NO"
  config.build_settings["OTHER_CODE_SIGN_FLAGS"] = APP_REQUIREMENT
end

core_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "local.yxp.grammarless.core"
  config.build_settings["DEFINES_MODULE"] = "YES"
  config.build_settings["SKIP_INSTALL"] = "YES"
  config.build_settings["PRODUCT_NAME"] = "GrammarlessCore"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["OTHER_CODE_SIGN_FLAGS"] = CORE_REQUIREMENT
  config.build_settings["OTHER_LDFLAGS"] = "$(inherited) -lsqlite3"
end

tests_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "local.yxp.grammarless.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["TEST_HOST"] = ""
  config.build_settings["BUNDLE_LOADER"] = ""
end

main_group = project.main_group
app_group = main_group.new_group("GrammarlessApp")
core_group = main_group.new_group("GrammarlessCore")
tests_group = main_group.new_group("GrammarlessCoreTests")

def add_sources(group, target, path_glob)
  Dir.glob(path_glob).sort.each do |path|
    relative = Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
    ref = group.find_file_by_path(relative) || group.new_file(relative)
    target.source_build_phase.add_file_reference(ref)
  end
end

def add_resources(group, target, path_glob)
  Dir.glob(path_glob).sort.each do |path|
    next if File.directory?(path)
    relative = Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
    ref = group.find_file_by_path(relative) || group.new_file(relative)
    target.resources_build_phase.add_file_reference(ref)
  end
end

app_sources_group = app_group.new_group("Sources")
core_sources_group = core_group.new_group("Sources")
core_resources_group = core_group.new_group("Resources")
tests_sources_group = tests_group.new_group("Sources")

add_sources(app_sources_group, app_target, File.join(ROOT, "GrammarlessApp/**/*.swift"))
add_sources(core_sources_group, core_target, File.join(ROOT, "GrammarlessCore/Sources/**/*.swift"))
add_resources(core_resources_group, core_target, File.join(ROOT, "GrammarlessCore/Resources/**/*"))
add_sources(tests_sources_group, tests_target, File.join(ROOT, "GrammarlessCoreTests/**/*.swift"))

app_target.add_dependency(core_target)
app_target.frameworks_build_phase.add_file_reference(core_target.product_reference)
embed_frameworks_phase = app_target.new_copy_files_build_phase("Embed Frameworks")
embed_frameworks_phase.symbol_dst_subfolder_spec = :frameworks
embed_build_file = embed_frameworks_phase.add_file_reference(core_target.product_reference, true)
embed_build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
tests_target.add_dependency(core_target)
tests_target.frameworks_build_phase.add_file_reference(core_target.product_reference)

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_build_target(core_target)
scheme.set_launch_target(app_target)
scheme.add_test_target(tests_target)
scheme.save_as(PROJECT_PATH, "Grammarless", true)

project.save
puts "Generated #{PROJECT_PATH}"
