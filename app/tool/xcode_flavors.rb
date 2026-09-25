#!/usr/bin/env ruby
# frozen_string_literal: true

# Give the iOS and macOS Runner projects the free and pro flavors.
#
# Editing project.pbxproj by hand is error-prone, so this owns it instead: it is
# idempotent and may be rerun whenever the projects change — and after
# `dart run flutter_launcher_icons`, which rewrites the iOS project's icon
# settings.
#
# It writes, for both projects:
#   * build configurations Debug-free, Debug-pro, Profile-free, Profile-pro,
#     Release-free and Release-pro, copied from the matching base one;
#   * an xcconfig per new configuration, next to the one it is copied from, so
#     CocoaPods' per-configuration file is the one that gets included;
#   * the bundle identifier, display name and app icon per configuration;
#   * shared schemes named free and pro, which is what `flutter build --flavor`
#     looks for.
#
# Run it with the xcodeproj gem that ships inside CocoaPods:
#   ruby tool/xcode_flavors.rb
# from the app/ directory. It finds that gem itself.

require 'fileutils'

def load_xcodeproj
  require 'xcodeproj'
rescue LoadError
  pod = `which pod`.strip
  home = pod.empty? ? nil : File.read(pod)[/GEM_HOME="([^"]+)"/, 1]
  abort 'xcodeproj not found. Install CocoaPods, or `gem install xcodeproj`.' if home.nil?
  ENV['GEM_HOME'] = home
  Gem.clear_paths
  require 'xcodeproj'
end

load_xcodeproj

ROOT = File.expand_path('..', __dir__)
BASES = %w[Debug Profile Release].freeze

FLAVORS = {
  # Free keeps the identifier every existing install already has.
  'free' => { suffix: '', name: 'Doomsaday' },
  'pro' => { suffix: '.pro', name: 'Doomsaday Pro' }
}.freeze

BASE_BUNDLE_ID = 'dev.doomsaday.doomsaday'

# A configuration's xcconfig, copied for one configuration and flavor.
#
# Two things are rewritten: the optional CocoaPods include, which is named after
# the build configuration and so differs per flavor, and any include of another
# xcconfig that itself has one, which is copied the same way.
#
# The copy is named after the configuration rather than the file it came from,
# because Profile is built from Release.xcconfig and still needs CocoaPods'
# profile-<flavor> file.
def flavored_xcconfig(path, configuration, flavor)
  target = File.join(
    File.dirname(path),
    "#{File.basename(path, '.xcconfig').sub(/(Debug|Profile|Release)\z/, '')}" \
    "#{configuration}-#{flavor}.xcconfig"
  )
  body = File.readlines(path).map do |line|
    included = line[/#include\??\s+"([^"]+\.xcconfig)"/, 1]
    if line.include?('Pods-Runner.')
      line.sub(/Pods-Runner\.[^.]+\.xcconfig/,
               "Pods-Runner.#{configuration.downcase}-#{flavor}.xcconfig")
    elsif included && pods_aware?(File.expand_path(included, File.dirname(path)))
      copy = flavored_xcconfig(
        File.expand_path(included, File.dirname(path)), configuration, flavor
      )
      line.sub(included, File.join(File.dirname(included), File.basename(copy)))
    else
      line
    end
  end
  File.write(target, "// Written by tool/xcode_flavors.rb.\n" + body.join)
  target
end

# Whether this xcconfig, or one it includes, pulls in a CocoaPods file.
def pods_aware?(path)
  return false unless File.exist?(path)

  File.readlines(path).any? do |line|
    next true if line.include?('Pods-Runner.')

    included = line[/#include\??\s+"([^"]+\.xcconfig)"/, 1]
    included && pods_aware?(File.expand_path(included, File.dirname(path)))
  end
end

def file_reference(project, path)
  relative = path.sub("#{File.dirname(project.path)}/", '')
  project.files.find { |file| file.real_path.to_s == path } ||
    project.new_file(relative)
end

# One flavoured copy of a configuration, on the project or on one target.
def duplicate(project, holder, base, flavor)
  name = "#{base.name}-#{flavor}"
  holder.build_configurations.delete_if { |c| c.name == name }
  copy = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  copy.name = name
  copy.build_settings = Marshal.load(Marshal.dump(base.build_settings))
  if base.base_configuration_reference
    source = base.base_configuration_reference.real_path.to_s
    copy.base_configuration_reference =
      if pods_aware?(source)
        file_reference(project, flavored_xcconfig(source, base.name, flavor))
      else
        base.base_configuration_reference
      end
  end
  holder.build_configurations << copy
  copy
end

def apply_app_settings(settings, flavor, macos:)
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = BASE_BUNDLE_ID + FLAVORS[flavor][:suffix]
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = "AppIcon-#{flavor}"
  # Both Info.plists read the name from here.
  settings['APP_DISPLAY_NAME'] = FLAVORS[flavor][:name]
  # On macOS the product name is the bundle name, the menu bar and the window
  # title; on iOS it stays Runner and the display name does the talking.
  settings['PRODUCT_NAME'] = FLAVORS[flavor][:name] if macos
end

def apply_test_settings(settings, flavor, macos:)
  settings['PRODUCT_BUNDLE_IDENTIFIER'] =
    "#{BASE_BUNDLE_ID}#{FLAVORS[flavor][:suffix]}.RunnerTests"
  return unless macos && settings['TEST_HOST']

  name = FLAVORS[flavor][:name]
  settings['TEST_HOST'] =
    "$(BUILT_PRODUCTS_DIR)/#{name}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/#{name}"
end

# Each flavor's scheme is the Runner scheme with its configurations swapped.
def write_schemes(project_path)
  FLAVORS.each_key do |flavor|
    scheme = Xcodeproj::XCScheme.new(
      File.join(project_path, 'xcshareddata', 'xcschemes', 'Runner.xcscheme')
    )
    scheme.test_action.build_configuration = "Debug-#{flavor}"
    scheme.launch_action.build_configuration = "Debug-#{flavor}"
    scheme.profile_action.build_configuration = "Profile-#{flavor}"
    scheme.analyze_action.build_configuration = "Debug-#{flavor}"
    scheme.archive_action.build_configuration = "Release-#{flavor}"
    scheme.save_as(project_path, flavor, true)
    puts "  scheme #{flavor}"
  end
end

%w[ios macos].each do |platform|
  project_path = File.join(ROOT, platform, 'Runner.xcodeproj')
  project = Xcodeproj::Project.open(project_path)
  macos = platform == 'macos'
  puts "#{platform}:"

  BASES.each do |base_name|
    base = project.build_configuration_list[base_name]
    raise "no #{base_name} configuration in #{platform}" if base.nil?

    FLAVORS.each_key { |flavor| duplicate(project, project, base, flavor) }

    project.targets.each do |target|
      target_base = target.build_configuration_list[base_name]
      next if target_base.nil?

      FLAVORS.each_key do |flavor|
        copy = duplicate(project, target, target_base, flavor)
        if target.name == 'Runner'
          apply_app_settings(copy.build_settings, flavor, macos: macos)
        else
          apply_test_settings(copy.build_settings, flavor, macos: macos)
        end
      end
      # A build with no flavor, from Xcode, is the free edition.
      next unless target.name == 'Runner'

      target_base.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon-free'
      target_base.build_settings['APP_DISPLAY_NAME'] = FLAVORS['free'][:name]
    end
    puts "  #{base_name}-free, #{base_name}-pro"
  end

  project.save
  write_schemes(project_path)
end
