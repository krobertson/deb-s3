require "tempfile"
require "zlib"

class Deb::S3::Manifest
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :component
  attr_accessor :architecture

  attr_accessor :files

  def initialize
    @packages = []
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

  def packages
    @packages
  end

  def add(pkg, preserve_versions)
    if preserve_versions
      @packages.delete_if { |p| p.name == pkg.name && p.version == pkg.version }
    else
      @packages.delete_if { |p| p.name == pkg.name }
    end
    @packages << pkg
    pkg
  end

  def delete_package(pkg, versions=nil)
    deleted = []
    new_packages = @packages.select { |p|
        # Include packages we didn't name
        if p.name != pkg
           p
        # Also include the packages not matching a specified version
        elsif (!versions.nil? and p.name == pkg and !versions.include? p.version)
            p
        end
    }
    deleted = @packages - new_packages
    @packages = new_packages
    deleted
  end

  def generate
    @packages.collect { |pkg| pkg.generate }.join("\n")
  end

  def write_to_s3
    manifest = self.generate

    # store any packages that need to be stored
    @packages.each do |pkg|
      if pkg.needs_uploading?
        yield pkg.url_filename if block_given?
        s3_store(pkg.filename, pkg.url_filename)
      end
    end

    # generate the Packages file
    pkgs_temp = Tempfile.new("Packages")
    pkgs_temp.write manifest
    pkgs_temp.close
    f = "dists/#{@codename}/#{@component}/binary-#{@architecture}/Packages"
    yield f if block_given?
    s3_store(pkgs_temp.path, f)
    @files["#{@component}/binary-#{@architecture}/Packages"] = hashfile(pkgs_temp.path)
    pkgs_temp.unlink

    # generate the Packages.gz file
    gztemp = Tempfile.new("Packages.gz")
    gztemp.close
    Zlib::GzipWriter.open(gztemp.path) { |gz| gz.write manifest }
    f = "dists/#{@codename}/#{@component}/binary-#{@architecture}/Packages.gz"
    yield f if block_given?
    s3_store(gztemp.path, f)
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
