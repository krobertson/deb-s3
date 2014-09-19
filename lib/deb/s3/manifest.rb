# -*- encoding : utf-8 -*-
require "tempfile"
require "zlib"
require 'deb/s3/utils'
require 'deb/s3/package'
require "deb/s3/log"

class Deb::S3::Manifest
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :component
  attr_accessor :architecture

  attr_accessor :files

  attr_reader :packages
  attr_reader :packages_to_be_upload

  def initialize
    @packages = []
    @packages_to_be_upload = []
    @component = nil
    @architecture = nil
    @files = {}
  end

  class << self
    def retrieve(codename, component, architecture)
      m = if s = Deb::S3::Utils.s3_read("dists/#{codename}/#{component}/binary-#{architecture}/Packages")
        self.parse_packages(s)
      else
        self.new
      end

      m.codename = codename
      m.component = component
      m.architecture = architecture
      m
    end

    def parse_packages(str)
      m = self.new
      str.split("\n\n").each do |s|
        next if s.chomp.empty?
        m.packages << Deb::S3::Package.parse_string(s)
      end
      m
    end
  end

  def add(pkg, preserve_versions, needs_uploading=true)
    if preserve_versions
      delete_package(pkg.name, {:full_versions => [pkg.full_version]})
    else
      delete_package(pkg.name)
    end

    packages << pkg
    packages_to_be_upload << pkg if needs_uploading
    pkg
  end

  def delete_package(package_name, opt = {})
    versions = opt[:versions]
    full_versions = opt[:full_versions]
    deleted = packages.select do |p|
      p.name == package_name &&
      (versions.nil? || versions.include?(p.version)) &&
      (full_versions.nil? || full_versions.include?(p.full_version))
    end
    deleted.each do |p|
      Log.log.info("Removing #{p.name} #{p.full_version}")
      s3_remove(p.url_filename)
    end
    packages.reject! {|p| deleted.include?(p)}
    deleted
  end

  def generate
    packages.collect { |pkg| pkg.generate }.join("\n")
  end

  def write_to_s3
    # store any packages that need to be stored
    packages_to_be_upload.each do |pkg|
      Log.log.info("Upload #{pkg.name} #{pkg.full_version}")
      s3_store(pkg.filename, pkg.url_filename, 'application/octet-stream; charset=binary')
    end

    manifest = self.generate

    # generate the Packages file
    pkgs_temp = Tempfile.new("Packages")
    pkgs_temp.write manifest
    pkgs_temp.close
    f = "dists/#{@codename}/#{@component}/binary-#{@architecture}/Packages"
    Log.log.info("Upload #{f}")
    s3_store(pkgs_temp.path, f, 'binary/octet-stream; charset=binary')
    @files["#{@component}/binary-#{@architecture}/Packages"] = hashfile(pkgs_temp.path)
    pkgs_temp.unlink

    # generate the Packages.gz file
    gztemp = Tempfile.new("Packages.gz")
    gztemp.close
    Zlib::GzipWriter.open(gztemp.path) { |gz| gz.write manifest }
    f = "dists/#{@codename}/#{@component}/binary-#{@architecture}/Packages.gz"
    Log.log.info("Upload #{f}")
    s3_store(gztemp.path, f, 'application/x-gzip; charset=binary')
    @files["#{@component}/binary-#{@architecture}/Packages.gz"] = hashfile(gztemp.path)
    gztemp.unlink

    nil
  end

  def hashfile(path)
    {
      :size   => File.size(path),
      :sha1   => Digest::SHA1.file(path).hexdigest,
      :sha256 => Digest::SHA2.file(path).hexdigest,
      :md5    => Digest::MD5.file(path).hexdigest
    }
  end
end
