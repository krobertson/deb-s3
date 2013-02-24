require "erb"
require "tmpdir"

module Deb::S3::Utils
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

  def store(path, policy, filename=nil)
    filename = File.basename(path) unless filename
    File.open(path) do |file|
      AWS::S3::S3Object.store(filename, file, 'paasio-landing', :access => policy)
    end
  end
end
