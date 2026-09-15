xcode_major = ENV.fetch("XCODE_MAJOR")
allow_prerelease = ENV["XCODE_ALLOW_PRERELEASE"] == "true"

def prerelease_xcode_path?(path)
  labels = [path, File.realpath(path)].map { |candidate| File.basename(candidate).downcase }
  labels.any? do |label|
    label.match?(/beta|release[ _-]?candidate|(?:^|[_. -])rc(?:$|[_. -])/)
  end
end

def version_components(path)
  version = File.basename(path)[/Xcode[_-](\d+(?:[._]\d+)*)/, 1]
  (version.to_s.tr("_", ".").split(".").map(&:to_i) + [0, 0]).first(3)
end

candidates = Dir["/Applications/Xcode*.app"].select do |path|
  File.directory?(path) &&
    File.basename(path).match?(/Xcode_#{Regexp.escape(xcode_major)}(?:[_.-]|\z)/)
end
candidates = candidates.reject { |path| prerelease_xcode_path?(path) } unless allow_prerelease
selected = candidates.max_by do |path|
  [version_components(path), prerelease_xcode_path?(path) ? 0 : 1]
end
abort("No #{allow_prerelease ? "" : "stable "}Xcode #{xcode_major} installation found") unless selected

developer_dir = "#{selected}/Contents/Developer"
version_output = IO.popen(
  { "DEVELOPER_DIR" => developer_dir },
  ["xcodebuild", "-version"],
  &:read
)
abort("Unable to read Xcode version") unless $?.success?

File.open(ENV.fetch("GITHUB_ENV"), "a") do |env|
  env.puts "DEVELOPER_DIR=#{developer_dir}"
end
cache_id = version_output.tr("\n ", "--").gsub(/[^[:alnum:]._-]/, "")
File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |output|
  output.puts "cache-id=#{cache_id}"
end
puts "Resolved Xcode: #{selected}"
puts version_output
