# -*- encoding : utf-8 -*-
require "tempfile"
require 'set'
require 'deb/s3/log'
require 'deb/s3/utils'

class Deb::S3::Release
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :origin
  attr_accessor :architectures
  attr_accessor :components

  attr_accessor :files
  attr_accessor :policy

  attr_accessor :manifests
  attr_reader   :packages

  def initialize
    @origin = nil
    @codename = nil
    @architectures = Set.new ['amd64', 'i386']
    @components = Set.new
    @files = {}
    @policy = :public_read
    @manifests = Set.new
    @packages = Set.new
    @pending = { :upload => Set.new, :remove => Set.new, :manifests => Set.new }
  end

  class << self
    def retrieve(codename, origin=nil)
      if s = Deb::S3::Utils.s3_read("dists/#{codename}/Release")
        self.parse_release(s)
      else
        rel = self.new
        rel.codename = codename
        rel.origin = origin
        rel
      end
    end

    def parse_release(str)
      rel = self.new
      rel.parse(str)
      rel
    end
  end

  def filename
    "dists/#{@codename}/Release"
  end

  def parse(str)
    parse = lambda do |field|
      value = str[/^#{field}: .*/]
      if value.nil?
        return nil
      else
        return value.split(": ",2).last
      end
    end

    # grab basic fields
    @codename = parse.call("Codename")
    @origin = parse.call("Origin") || nil
    @architectures = (parse.call("Architectures") || "").split(/\s+/)
    @components = (parse.call("Components") || "").split(/\s+/)

    architectures.each do |a|
      components.each do |c|
        add_manifest(a, c)
      end
    end
    # find all the hashes
    str.scan(/^\s+([^\s]+)\s+(\d+)\s+(.+)$/).each do |(hash,size,name)|
      self.files[name] ||= { :size => size.to_i }
      case hash.length
      when 32
        self.files[name][:md5] = hash
      when 40
        self.files[name][:sha1] = hash
      when 64
        self.files[name][:sha256] = hash
      end
    end
  end

  def generate
    template("release.erb").result(binding)
  end

  def write_to_s3
    remove_package_s3
    upload_package_s3

    @pending[:manifests].each { |m| m.write_to_s3 }

    # generate the Release file
    release_tmp = Tempfile.new("Release")
    release_tmp.puts self.generate
    release_tmp.close
    yield self.filename if block_given?
    s3_store(release_tmp.path, self.filename, 'binary/octet-stream; charset=binary')

    # sign the file, if necessary
    if Deb::S3::Utils.signing_key
      key_param = Deb::S3::Utils.signing_key != "" ? "--default-key=#{Deb::S3::Utils.signing_key}" : ""
      if system("gpg -a #{key_param} #{Deb::S3::Utils.gpg_options} -b #{release_tmp.path}")
        local_file = release_tmp.path+".asc"
        remote_file = self.filename+".gpg"
        yield remote_file if block_given?
        raise "Unable to locate Release signature file" unless File.exists?(local_file)
        s3_store(local_file, remote_file, 'application/pgp-signature; charset=us-ascii')
        File.unlink(local_file)
      else
        raise "Signing the Release file failed."
      end
    else
      # remove an existing Release.gpg, if it was there
      s3_remove(self.filename+".gpg")
    end

    release_tmp.unlink
  end

  def add_manifest(arch, component)
    manifest = Deb::S3::Manifest.new(codename, component, arch)
    m = manifests.find { |man| man == manifest }
    unless m
      m = manifest
      Log.log.debug("Adding Manifest #{m}")
      components << manifest.component
      architectures << manifest.architecture
      files.merge(manifest.files)
      @packages.merge(manifest.parse_packages)
      @manifests << manifest
    end
    m
  end

  def add_package(package, manifest)
    Log.log.debug("Add #{package.name}:#{package.full_version} to #{manifest}")
    if package.architecture == 'all'
      mans = manifests_same_component(manifest)
    else
      mans = [manifest]
    end
    mans.each do |m|
      m.packages << package
      @pending[:manifests] << m
    end
    @pending[:upload] << package
    @pending[:manifests] << manifest
  end

  def delete_package(package_name, manifest, versions = [])
    Log.log.debug("Remove #{package_name}:#{versions} from #{manifest}")
    if manifest.architecture == 'all'
      mans = manifests_same_component(manifest)
    else
      mans = [manifest]
    end
    packages_to_remove = []
    mans.each do |m|
      ptr = m.packages.select do |p|
        p.name == package_name &&
        (versions.nil? || versions.include?(p.version) || versions.include?(p.full_version))
      end
      @pending[:manifests] << m
      m.packages.subtract(ptr)
      packages_to_remove.concat(ptr)
    end
    @pending[:remove].merge(packages_to_remove)
    @pending[:manifests] << manifest
  end

  def purge_package(package)
    @packages.delete(package)
    @manifests.each do |m|
      next unless m.packages.delete?(package)
      @pending[:manifests] << m
    end
  end

  def upload_package_s3
    @pending[:upload].each do |pkg|
      next unless @packages.add?(pkg)
      s3_store(pkg.filename, pkg.filename, 'application/octet-stream; charset=binary')
    end
  end

  def remove_package_s3
    @pending[:remove].each do |pkg|
      next if @manifests.any? { |m| m.packages.include?(pkg) }
      s3_remove(pkg.filename)
      @packages.delete(pkg)
    end
  end

  def manifests_same_component(manifest)
    @manifests.select { |m| m.component == manifest.component }
  end
end
