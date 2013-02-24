class Deb::S3::Release
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :files
  attr_accessor :policy

  def initialize
    @codename = nil
    @policy = :public_read
    @files = []
  end

  def filename
    "dists/#{@codename}/Release"
  end

  def upload
    # generate the Release file
    release = template("release.erb").result(binding)
    release_tmp = Tempfile.new("Release")
    release_tmp.puts release
    release_tmp.close
    store(release_tmp.path, @policy, filename)
  end
end
