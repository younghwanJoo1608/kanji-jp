#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8

require "fileutils"
require "json"
require "optparse"
require "time"

options = {
  dir: "_kanji_8",
  root: "_migration_snapshots"
}

OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby tools/snapshot_kanji_stage.rb [options]"
  opts.on("--dir DIR", "Directory to snapshot. Default: _kanji_8") { |value| options[:dir] = value }
  opts.on("--root DIR", "Snapshot root. Default: _migration_snapshots") { |value| options[:root] = value }
end.parse!

source_dir = options[:dir]
abort "Snapshot source does not exist: #{source_dir}" unless Dir.exist?(source_dir)

timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
snapshot_root = File.join(options[:root], timestamp)
snapshot_dir = File.join(snapshot_root, File.basename(source_dir))

FileUtils.mkdir_p(snapshot_root)
FileUtils.cp_r(source_dir, snapshot_dir)

manifest = {
  "created_at" => Time.now.iso8601,
  "source_dir" => source_dir,
  "snapshot_dir" => snapshot_dir,
  "file_count" => Dir.glob(File.join(snapshot_dir, "**", "*")).count { |path| File.file?(path) }
}

File.write(File.join(snapshot_root, "manifest.json"), JSON.pretty_generate(manifest), encoding: "UTF-8")
puts JSON.pretty_generate(manifest)
