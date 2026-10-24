# The private build removes only the optional widget dependency and capabilities.
# This runs on a disposable checkout, preserving the normal upstream project in Git.
require 'xcodeproj'
require 'pathname'
root = Pathname.new(__dir__).join('../..').realpath
project = Xcodeproj::Project.open(root.join('iphone/Maps/Maps.xcodeproj'))
app = project.targets.find { |target| target.name == 'CoMaps' }
raise 'CoMaps target missing' unless app
app.dependencies.select { |dep| dep.target&.name == 'CoMapsWidgetExtension' }.each(&:remove_from_project)
app.copy_files_build_phases.select { |phase| phase.name == 'Embed Foundation Extensions' }.each(&:remove_from_project)
app.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = root.join('packaging/private/PrivateSideload.entitlements').to_s
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.navi.private'
end
# Simulator-only trap diagnostics are empty in device builds. Add the source
# only in this disposable private-build project, not the upstream project file.
diagnostics = project.main_group.groups.find { |group| group.display_name == 'Private Startup Diagnostics' }
diagnostics ||= project.main_group.new_group('Private Startup Diagnostics')
capture_path = root.join('tools/private/NaviStartupCapture.mm').to_s
capture = diagnostics.files.find { |file| file.path == capture_path }
capture ||= diagnostics.new_file(capture_path)
app.source_build_phase.add_file_reference(capture, true)
project.save
