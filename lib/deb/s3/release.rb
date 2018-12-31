require 'tempfile'

class Deb::S3::Release
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :origin
  attr_accessor :suite
  attr_accessor :architectures
  attr_accessor :components
  attr_accessor :cache_control

  attr_accessor :files
  attr_accessor :policy

  def initialize
    @origin = nil
    @suite = nil
    @codename = nil
    @architectures = []
    @components = []
    @cache_control = ''
    @files = {}
    @policy = :public_read
  end

  class << self
    def retrieve(codename, origin = nil, suite = nil, cache_control = nil)
      rel = if s = Deb::S3::Utils.s3_read("dists/#{codename}/Release")
              parse_release(s)
            else
              new
            end
      rel.codename = codename
      rel.origin = origin unless origin.nil?
      rel.suite = suite unless suite.nil?
      rel.cache_control = cache_control
      rel
    end

    def parse_release(str)
      rel = new
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
        return value.split(': ', 2).last
      end
    end

    # grab basic fields
    self.codename = parse.call('Codename')
    self.origin = parse.call('Origin') || nil
    self.suite = parse.call('Suite') || nil
    self.architectures = (parse.call('Architectures') || '').split(/\s+/)
    self.components = (parse.call('Components') || '').split(/\s+/)

    # find all the hashes
    str.scan(/^\s+([^\s]+)\s+(\d+)\s+(.+)$/).each do |(hash, size, name)|
      files[name] ||= { size: size.to_i }
      case hash.length
      when 32
        files[name][:md5] = hash
      when 40
        files[name][:sha1] = hash
      when 64
        files[name][:sha256] = hash
      end
    end
  end

  def generate
    template('release.erb').result(binding)
  end

  def write_to_s3
    # validate some other files are present
    if block_given?
      validate_others { |f| yield f }
    else
      validate_others
    end

    # generate the Release file
    release_tmp = Tempfile.new('Release')
    release_tmp.puts generate
    release_tmp.close
    yield filename if block_given?
    s3_store(release_tmp.path, filename, 'text/plain; charset=utf-8', cache_control)

    # sign the file, if necessary
    if Deb::S3::Utils.signing_key
      key_param = Deb::S3::Utils.signing_key != '' ? "--default-key=#{Deb::S3::Utils.signing_key}" : ''
      if system("gpg -a #{key_param} --digest-algo SHA256 #{Deb::S3::Utils.gpg_options} -s --clearsign #{release_tmp.path}")
        local_file = release_tmp.path + '.asc'
        remote_file = "dists/#{@codename}/InRelease"
        yield remote_file if block_given?
        raise 'Unable to locate InRelease file' unless File.exist?(local_file)

        s3_store(local_file, remote_file, 'application/pgp-signature; charset=us-ascii', cache_control)
        File.unlink(local_file)
      else
        raise 'Signing the InRelease file failed.'
      end
      if system("gpg -a #{key_param} --digest-algo SHA256 #{Deb::S3::Utils.gpg_options} -b #{release_tmp.path}")
        local_file = release_tmp.path + '.asc'
        remote_file = filename + '.gpg'
        yield remote_file if block_given?
        raise 'Unable to locate Release signature file' unless File.exist?(local_file)

        s3_store(local_file, remote_file, 'application/pgp-signature; charset=us-ascii', cache_control)
        File.unlink(local_file)
      else
        raise 'Signing the Release file failed.'
      end
    else
      # remove an existing Release.gpg, if it was there
      s3_remove(filename + '.gpg')
    end

    release_tmp.unlink
  end

  def update_manifest(manifest)
    components << manifest.component unless components.include?(manifest.component)
    architectures << manifest.architecture unless architectures.include?(manifest.architecture)
    files.merge!(manifest.files)
  end

  def validate_others
    to_apply = []
    components.each do |comp|
      %w[amd64 i386 armhf].each do |arch|
        next if files.key?("#{comp}/binary-#{arch}/Packages")

        m = Deb::S3::Manifest.new
        m.codename = codename
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

    to_apply.each { |m| update_manifest(m) }
  end
end
