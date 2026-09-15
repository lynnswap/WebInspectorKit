require "json"

ios_major = ENV.fetch("IOS_MAJOR")
requested_device = ENV.fetch("SIMULATOR_DEVICE", "")
devices_output = IO.popen(["xcrun", "simctl", "list", "devices", "available", "--json"], &:read)
abort("Unable to list available simulators") unless $?.success?

runtimes = JSON.parse(devices_output).fetch("devices")
candidates = runtimes.flat_map do |runtime, devices|
  match = runtime.match(/SimRuntime\.iOS-(\d+(?:-\d+)*)$/)
  next [] unless match

  version = match[1].tr("-", ".")
  next [] unless version.split(".").first == ios_major

  devices.filter_map do |device|
    next unless device.fetch("isAvailable", true)
    next unless requested_device.empty? || device.fetch("name") == requested_device

    [version.split(".").map(&:to_i), version, device.fetch("name"), device.fetch("udid")]
  end
end

if requested_device.empty?
  iphones = candidates.select { |_, _, name, _| name.start_with?("iPhone") }
  candidates = iphones unless iphones.empty?
end
selected = candidates.max_by { |components, _, name, udid| [components, name, udid] }
abort("No available #{requested_device.empty? ? "iOS" : requested_device + " iOS"} #{ios_major}.x simulator found") unless selected

_, version, device_name, udid = selected
File.open(ENV.fetch("GITHUB_ENV"), "a") do |env|
  env.puts "DESTINATION=platform=iOS Simulator,id=#{udid}"
  env.puts "RESOLVED_IOS_VERSION=#{version}"
  env.puts "WATCHDOG_SIMULATOR_UDID=#{udid}"
end
puts "Resolved simulator: #{device_name} iOS #{version} (#{udid})"
