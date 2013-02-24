require "tempfile"

class Deb::S3::Release
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :architectures
  attr_accessor :components

  attr_accessor :files
  attr_accessor :policy

  def initialize
    @codename = nil
    @architectures = []
    @components = []
    @files = {}
    @policy = :public_read
  end

  class << self
    def retrieve(codename)
      if s = Deb::S3::Utils.s3_read("dists/#{codename}/Release")
        self.parse_release(s)
      else
        rel = self.new
        rel.codename = codename
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
    self.codename = parse.call("Codename")
    self.architectures = (parse.call("Architectures") || "").split(/\s+/)
    self.components = (parse.call("Components") || "").split(/\s+/)

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
    # validate some other files are present
    if block_given?
      self.validate_others { |f| yield f }
    else
      self.validate_others
    end

    # generate the Release file
    release_tmp = Tempfile.new("Release")
    release_tmp.puts self.generate
    release_tmp.close
    yield self.filename if block_given?
    s3_store(release_tmp.path, self.filename)
    release_tmp.unlink
  end

  def update_manifest(manifest)
    self.components << manifest.component unless self.components.include?(manifest.component)
    self.architectures << manifest.architecture unless self.architectures.include?(manifest.architecture)
    self.files.merge!(manifest.files)
  end

  def validate_others
    to_apply = []
    self.components.each do |comp|
      %w(amd64 i386).each do |arch|
        next if self.files.has_key?("#{comp}/binary-#{arch}/Packages")

        m = Deb::S3::Manifest.new
        m.codename = self.codename
        m.component = comp
        m.architecture = arch
        if block_given?
          m.write_to_s3 { |f| yield f }
        else
          m.write_to_s3
        end
        to_apply << m
      end
    end

    to_apply.each { |m| self.update_manifest(m) }
  end
end
