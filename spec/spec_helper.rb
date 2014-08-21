# -*- encoding : utf-8 -*-
require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require 'deb/s3'

def fixture(name)
  File.expand_path("../fixtures/#{name}", __FILE__)
end

def create_package(attributes = {})
  package = Deb::S3::Package.new
  attributes.each do |k,v|
    package.send("#{k}=".to_sym, v)
  end
  package
end
