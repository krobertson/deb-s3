require "erb"
require "tmpdir"

module Deb::S3::Utils
  module_function
  def bucket; @bucket end
  def bucket= v; @bucket = v end
  def access_policy; @access_policy end
  def access_policy= v; @access_policy = v end
  def signing_key; @signing_key end
  def signing_key= v; @signing_key = v end

  def safesystem(*args)
    success = system(*args)
    if !success
      raise "'system(#{args.inspect})' failed with error code: #{$?.exitstatus}"
    end
    return success
  end

  def debianize_op(op)
    # Operators in debian packaging are <<, <=, =, >= and >>
    # So any operator like < or > must be replaced
    {:< => "<<", :> => ">>"}[op.to_sym] or op
  end

  def template(path)
    template_file = File.join(File.dirname(__FILE__), "templates", path)
    template_code = File.read(template_file)
    ERB.new(template_code, nil, "-")
  end

  # from fog, Fog::AWS.escape
  def s3_escape(string)
    string.gsub(/([^a-zA-Z0-9_.\-~]+)/) {
      "%" + $1.unpack("H2" * $1.bytesize).join("%").upcase
    }
  end

  def s3_exists?(path)
    AWS::S3::S3Object.exists?(path, Deb::S3::Utils.bucket)
  end

  def s3_read(path)
    return nil unless s3_exists?(path)
    s = ""
    AWS::S3::S3Object.stream(path, Deb::S3::Utils.bucket) do |chunk|
      s += chunk
    end
    s
  end

  def s3_store(path, filename=nil)
    filename = File.basename(path) unless filename
    File.open(path) do |file|
      AWS::S3::S3Object.store(filename, file,
        Deb::S3::Utils.bucket, :access => Deb::S3::Utils.access_policy)
    end
  end

  def s3_remove(path)
    AWS::S3::S3Object.delete(path, Deb::S3::Utils.bucket) if s3_exists?(path)
  end
end
