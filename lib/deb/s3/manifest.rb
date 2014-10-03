# -*- encoding : utf-8 -*-
require "tempfile"
require "zlib"
require 'deb/s3/utils'
require 'deb/s3/package'
require "deb/s3/log"
require 'set'

class Deb::S3::Manifest
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :component
  attr_accessor :architecture

  attr_accessor :files

  attr_reader :packages

  def initialize(codename, component, architecture)
    @codename = codename
    @component = component
    @architecture = architecture
    @packages = Set.new
    @files = {}
  end

  def parse_packages
    packages_file = Deb::S3::Utils.s3_read("dists/#{codename}/#{component}/binary-#{architecture}/Packages")
    if packages_file
      packages_file.split("\n\n").each do |s|
        next if s.chomp.empty?
        @packages << Deb::S3::Package.parse_string(s)
      end
    end
    @packages
  end

  def generate
    packages.collect { |pkg| pkg.generate }.join("\n")
  end

  def write_to_s3
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

  def package_url_prefix
    "pool/#{@codename}/#{@component}"
  end

  def hash
    [self.class, @codename, @component, @architecture].hash
  end

  def eql?(other)
    self.class == other.class &&
    codename == other.codename &&
    component == other.component &&
    architecture == other.architecture
  end
  alias_method :==, :eql?

  def to_s
    "#{@codename}_#{@component}_#{@architecture}"
  end
end
