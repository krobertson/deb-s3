$:.unshift File.expand_path("../lib", __FILE__)
require "deb/s3"

Gem::Specification.new do |gem|
  gem.name        = "deb-s3"
  gem.version     = Deb::S3::VERSION

  gem.author      = "Ken Robertson"
  gem.email       = "ken@invalidlogic.com"
  gem.homepage    = "http://invalidlogic.com/"
  gem.summary     = "Easily create and manage an APT repository on S3."
  gem.description = gem.summary
  gem.license     = "MIT"
  gem.executables = "deb-s3"

  gem.files = Dir["**/*"].select { |d| d =~ %r{^(README|bin/|ext/|lib/)} }

  gem.required_ruby_version = '>= 1.9.3'

  gem.add_dependency "thor",    "~> 0.19.0"
  gem.add_dependency "aws-sdk", "~> 1.66"
  gem.add_development_dependency "minitest", "~> 5"
  gem.add_development_dependency "rake", "~> 11"
end
