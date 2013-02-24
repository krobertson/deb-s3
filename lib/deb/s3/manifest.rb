require "tempfile"
require "zlib"

class Deb::S3::Manifest
  include Deb::S3::Utils

  class << self
    def parse_packages(str)
      m = self.new
      str.split("\n\n").each do |s|
        m.add Deb::S3::Package.parse_string(s)
      end
      m
    end

    def open(bucket, codename, component, architecture)
      filename = "dists/#{codename}/#{component}/binary-#{architecture}/Packages"
      m = if AWS::S3::S3Object.exists?(filename, bucket)
        s = ""
        AWS::S3::S3Object.stream(filename, bucket) do |chunk|
          s += chunk
        end
        self.parse_packages(s)
      else
        self.new
      end

      m.codename = codename
      m.components << component
      m.architecture = architecture
      m
    end
  end

  attr_accessor :codename
  attr_accessor :components
  attr_accessor :architecture

  attr_accessor :policy
  attr_accessor :bucket

  def initialize
    @packages = []
    @components = []
    @policy = :public_read
  end

  def packages
    @packages
  end

  def add(pkg)
    @packages.delete_if { |p| p.name == pkg.name }
    @packages << pkg
    pkg
  end

  def generate
    @packages.collect { |pkg| pkg.generate }.join("\n")
  end

  def write_to_s3
    manifest = self.generate
    @files = {}

    # store any packages that need to be stored
    @packages.each do |pkg|
      if pkg.needs_uploading?
        yield pkg.url_filename if block_given?
        store(pkg.filename, @policy, pkg.url_filename)
      end
    end

    # generate the Packages file
    pkgs_temp = Tempfile.new("Packages")
    pkgs_temp.puts manifest
    pkgs_temp.close
    f = "dists/#{@codename}/#{@components.first}/binary-#{@architecture}/Packages"
    yield f if block_given?
    store(pkgs_temp.path, @policy, f)
    @files["Packages"] = hashfile(pkgs_temp.path)

    # generate the Packages.gz file
    gztemp = Tempfile.new("Packages.gz")
    gztemp.close
    Zlib::GzipWriter.open(gztemp.path) { |gz| gz.write manifest }
    f = "dists/#{@codename}/#{@components.first}/binary-#{@architecture}/Packages.gz"
    yield f if block_given?
    store(gztemp.path, @policy, f)
    @files["Packages.gz"] = hashfile(gztemp.path)

    # generate the Release file
    release = Deb::S3::Release.new
    release.codename = @codename
    release.files = @files
    release.policy = @policy
    yield release.filename if block_given?
    release.upload

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
